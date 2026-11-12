/*
 * Copyright © 2015 Red Hat
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice (including the next
 * paragraph) shall be included in all copies or substantial portions of the
 * Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL
 * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
 * IN THE SOFTWARE.
 *
 * Authors:
 *    Rob Clark <robclark@freedesktop.org>
 */

#include "nir.h"
#include "nir_builder.h"

/* 32-bit unsigned division from the fp32 reciprocal and low multiplies
 * (nir_lower_idiv_options::udiv_fp32_rcp). q0 = n * rcp(d) in fp32 is
 * within ~2^-22 * q + 2^8 / d of n / d, so the remainder n - q0 * d fits a
 * signed 32-bit value while d < 2^30; one more fp32 step leaves q off by at
 * most one, which the last compare fixes. A divisor >= 2^30 gives a
 * quotient of 0..3, found by subtracting it up to three times.
 */
static nir_def *
emit_udiv_fp32_rcp(nir_builder *b, nir_def *n, nir_def *d, bool modulo, bool small_n)
{
   nir_def *rcp = nir_frcp(b, nir_u2f32(b, d));
   /* Clamp below 2^32 so the conversion stays in range. */
   nir_def *q = nir_f2u32(b, nir_fmin(b, nir_fmul(b, nir_u2f32(b, n), rcp),
                                      nir_imm_float(b, 4294967040.0f)));
   nir_def *r = nir_isub(b, n, nir_imul(b, q, d));
   q = nir_iadd(b, q, nir_f2i32(b, nir_fmul(b, nir_i2f32(b, r), rcp)));
   r = nir_isub(b, n, nir_imul(b, q, d));
   nir_def *neg = nir_ilt_imm(b, r, 0);
   q = nir_bcsel(b, neg, nir_iadd_imm(b, q, -1), q);
   r = nir_bcsel(b, neg, nir_iadd(b, r, d), r);
   nir_def *ge = nir_uge(b, r, d);
   q = nir_bcsel(b, ge, nir_iadd_imm(b, q, 1), q);
   r = nir_bcsel(b, ge, nir_isub(b, r, d), r);
   /* n < 2^24: r stayed in range for every d. */
   if (small_n)
      return modulo ? r : q;

   nir_def *m = n, *qs = nir_imm_int(b, 0);
   for (unsigned k = 0; k < 3; k++) {
      nir_def *g = nir_uge(b, m, d);
      m = nir_bcsel(b, g, nir_isub(b, m, d), m);
      qs = nir_iadd(b, qs, nir_b2i32(b, g));
   }
   nir_def *big = nir_uge_imm(b, d, 0x40000000u);
   return modulo ? nir_bcsel(b, big, m, r) : nir_bcsel(b, big, qs, q);
}

/* ported from LLVM's AMDGPUTargetLowering::LowerUDIVREM */
static nir_def *
emit_udiv_precise(nir_builder *bld, nir_def *numer, nir_def *denom, bool modulo)
{
   nir_def *rcp = nir_frcp(bld, nir_u2f32(bld, denom));
   rcp = nir_f2u32(bld, nir_fmul_imm(bld, rcp, 4294966784.0));

   nir_def *neg_rcp_times_denom =
      nir_imul(bld, rcp, nir_ineg(bld, denom));
   rcp = nir_iadd(bld, rcp, nir_umul_high(bld, rcp, neg_rcp_times_denom));

   /* Get initial estimate for quotient/remainder, then refine the estimate
    * in two iterations after */
   nir_def *quotient = nir_umul_high(bld, numer, rcp);
   nir_def *num_s_remainder = nir_imul(bld, quotient, denom);
   nir_def *remainder = nir_isub(bld, numer, num_s_remainder);

   /* First refinement step */
   nir_def *remainder_ge_den = nir_uge(bld, remainder, denom);
   if (!modulo) {
      quotient = nir_bcsel(bld, remainder_ge_den,
                           nir_iadd_imm(bld, quotient, 1), quotient);
   }
   remainder = nir_bcsel(bld, remainder_ge_den,
                         nir_isub(bld, remainder, denom), remainder);

   /* Second refinement step */
   remainder_ge_den = nir_uge(bld, remainder, denom);
   if (modulo) {
      return nir_bcsel(bld, remainder_ge_den, nir_isub(bld, remainder, denom),
                       remainder);
   } else {
      return nir_bcsel(bld, remainder_ge_den, nir_iadd_imm(bld, quotient, 1),
                       quotient);
   }
}

static nir_def *
emit_udiv(nir_builder *bld, nir_def *numer, nir_def *denom, bool modulo,
          const nir_lower_idiv_options *options, bool small_n)
{
   if (options && options->udiv_fp32_rcp)
      return emit_udiv_fp32_rcp(bld, numer, denom, modulo, small_n);
   return emit_udiv_precise(bld, numer, denom, modulo);
}

/* ported from LLVM's AMDGPUTargetLowering::LowerSDIVREM */
static nir_def *
emit_idiv(nir_builder *bld, nir_def *numer, nir_def *denom, nir_op op,
          const nir_lower_idiv_options *options, bool small_n)
{
   nir_def *lhs = nir_iabs(bld, numer);
   nir_def *rhs = nir_iabs(bld, denom);

   if (op == nir_op_idiv) {
      /* We want (numer < 0) ^ (denom < 0). This is the XOR of the sign bits,
       * and since XOR is bitwise, that's the sign bit of the XOR.
       */
      nir_def *d_sign = nir_ilt_imm(bld, nir_ixor(bld, numer, denom), 0);
      nir_def *res = emit_udiv(bld, lhs, rhs, false, options, small_n);
      return nir_bcsel(bld, d_sign, nir_ineg(bld, res), res);
   } else {
      nir_def *lh_sign = nir_ilt_imm(bld, numer, 0);
      nir_def *rh_sign = nir_ilt_imm(bld, denom, 0);

      nir_def *res = emit_udiv(bld, lhs, rhs, true, options, small_n);
      res = nir_bcsel(bld, lh_sign, nir_ineg(bld, res), res);
      if (op == nir_op_imod) {
         nir_def *cond = nir_ieq_imm(bld, res, 0);
         cond = nir_ior(bld, nir_ieq(bld, lh_sign, rh_sign), cond);
         res = nir_bcsel(bld, cond, res, nir_iadd(bld, res, denom));
      }
      return res;
   }
}

static nir_def *
convert_instr_small(nir_builder *b, nir_op op,
                    nir_def *numer, nir_def *denom,
                    const nir_lower_idiv_options *options)
{
   unsigned sz = numer->bit_size;
   nir_alu_type int_type = nir_op_infos[op].output_type | sz;
   nir_alu_type float_type = nir_type_float | (options->allow_fp16 ? sz * 2 : 32);

   nir_def *p = nir_type_convert(b, numer, int_type, float_type, nir_rounding_mode_undef);
   nir_def *q = nir_type_convert(b, denom, int_type, float_type, nir_rounding_mode_undef);

   /* Take 1/q but offset mantissa by 1 to correct for rounding. This is
    * needed for correct results and has been checked exhaustively for
    * all pairs of 16-bit integers */
   nir_def *rcp = nir_iadd_imm(b, nir_frcp(b, q), 1);

   /* Divide by multiplying by adjusted reciprocal */
   nir_def *res = nir_fmul(b, p, rcp);

   /* Convert back to integer space with rounding inferred by type */
   res = nir_type_convert(b, res, float_type, int_type, nir_rounding_mode_undef);

   /* Get remainder given the quotient */
   if (op == nir_op_umod || op == nir_op_imod || op == nir_op_irem)
      res = nir_isub(b, numer, nir_imul(b, denom, res));

   /* Adjust for sign, see constant folding definition */
   if (op == nir_op_imod) {
      nir_def *zero = nir_imm_zero(b, 1, sz);
      nir_def *diff_sign =
         nir_ine(b, nir_ige(b, numer, zero), nir_ige(b, denom, zero));

      nir_def *adjust = nir_iand(b, diff_sign, nir_ine(b, res, zero));
      res = nir_iadd(b, res, nir_bcsel(b, adjust, denom, zero));
   }

   return res;
}

struct lower_idiv_state {
   const nir_lower_idiv_options *options;
   struct hash_table *range_ht;
};

/* Is every component of the numerator provably below 2^24 (and so also
 * non-negative)? Only asked for udiv_fp32_rcp. */
static bool
numer_below_2_24(nir_builder *b, nir_alu_instr *alu, struct lower_idiv_state *st)
{
   if (!st->options || !st->options->udiv_fp32_rcp || alu->def.bit_size != 32)
      return false;
   if (!st->range_ht)
      st->range_ht = _mesa_pointer_hash_table_create(NULL);
   for (unsigned c = 0; c < alu->def.num_components; c++) {
      nir_scalar s = nir_get_scalar(alu->src[0].src.ssa, alu->src[0].swizzle[c]);
      if (nir_unsigned_upper_bound(b->shader, st->range_ht, s) >= (1u << 24))
         return false;
   }
   return true;
}

static nir_def *
lower_idiv(nir_builder *b, nir_instr *instr, void *_data)
{
   struct lower_idiv_state *st = _data;
   const nir_lower_idiv_options *options = st->options;
   nir_alu_instr *alu = nir_instr_as_alu(instr);
   const bool small_n = numer_below_2_24(b, alu, st);

   nir_def *numer = nir_ssa_for_alu_src(b, alu, 0);
   nir_def *denom = nir_ssa_for_alu_src(b, alu, 1);

   b->fp_math_ctrl |= nir_fp_exact;

   if (numer->bit_size < 32)
      return convert_instr_small(b, alu->op, numer, denom, options);
   else if (alu->op == nir_op_udiv || alu->op == nir_op_umod)
      return emit_udiv(b, numer, denom, alu->op == nir_op_umod, options, small_n);
   else
      return emit_idiv(b, numer, denom, alu->op, options, small_n);
}

static bool
inst_is_idiv(const nir_instr *instr, UNUSED const void *_state)
{
   if (instr->type != nir_instr_type_alu)
      return false;

   nir_alu_instr *alu = nir_instr_as_alu(instr);

   if (alu->def.bit_size > 32)
      return false;

   switch (alu->op) {
   case nir_op_idiv:
   case nir_op_udiv:
   case nir_op_imod:
   case nir_op_umod:
   case nir_op_irem:
      return true;
   default:
      return false;
   }
}

bool
nir_lower_idiv(nir_shader *shader, const nir_lower_idiv_options *options)
{
   struct lower_idiv_state st = {.options = options};
   bool progress = nir_shader_lower_instructions(shader,
                                                 inst_is_idiv,
                                                 lower_idiv,
                                                 &st);
   if (st.range_ht)
      _mesa_hash_table_destroy(st.range_ht, NULL);
   return progress;
}
