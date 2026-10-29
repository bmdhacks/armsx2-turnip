// SPDX-License-Identifier: MIT

use rustc_hash::FxHashMap;

use crate::ir::*;
use crate::legalize::fau_srcs_legal;
use crate::ops::*;

/// A comparison that produces a mask: -1 where it holds, 0 where it does not.
fn as_mask_compare(op: &Op) -> Option<&OpCmp> {
    let Op::Cmp(cmp) = op else {
        return None;
    };
    if cmp.res_type == CmpResultType::M1
        && cmp.accum_op == CmpAccumOp::None
        && cmp.accum.is_zero()
        && matches!(cmp.src_type, DataType::F32 | DataType::S32 | DataType::U32)
        && matches!(
            cmp.cmp_op,
            CmpOp::Eq | CmpOp::Ne | CmpOp::Ge | CmpOp::Lt
        )
    {
        Some(cmp)
    } else {
        None
    }
}

/// Builds the CSEL that does what `csel`, a CSEL of the mask `cmp` produces
/// against zero, does, with the comparison done by the CSEL itself.
fn fuse(model: &dyn Model, cmp: &OpCmp, csel: &OpCSel) -> Option<Op> {
    let fused: Op = OpCSel {
        dst: csel.dst.clone(),
        cmp_type: cmp.src_type,
        cmp_op: cmp.cmp_op,
        cmp_srcs: cmp.srcs.clone(),
        sel_srcs: csel.sel_srcs.clone(),
    }
    .into();

    // The sources of the comparison were chosen for the comparison. Each has
    // to be one the CSEL takes as it is, or the legalizer adds the MOV that
    // the fusion saves.
    for src in fused.srcs() {
        if let SrcRef::Imm32(imm) = &src.src_ref {
            if !model.op_src_supports_imm32(&fused, src, imm.get()) {
                return None;
            }
        }
        if !src.swizzle.is_none()
            && !model.op_src_supports_swizzle(&fused, src, src.swizzle)
        {
            return None;
        }
        if !src.src_mod.is_none()
            && !model.op_src_supports_mod(&fused, src, src.src_mod)
        {
            return None;
        }
    }
    if !fau_srcs_legal(model, &fused) {
        return None;
    }
    Some(fused)
}

impl Shader<'_> {
    /// Replaces a CSEL of the mask of a comparison against zero with a CSEL
    /// that makes the comparison itself, when the fused instruction reads
    /// its constants and uniforms without a MOV. The comparison stays for any
    /// other use of its mask and is dead code otherwise.
    ///
    /// This is a pass of its own, after the constants have been promoted,
    /// because whether the four sources of the CSEL fit in the 64 bits of
    /// FAU an instruction reads depends on where the constants and uniforms
    /// ended up.
    pub fn opt_fuse_csel(&mut self) {
        let model = self.model;
        for block in self.blocks.iter_mut() {
            let mut masks: FxHashMap<SSAValue, OpCmp> = FxHashMap::default();
            for instr in block.instrs.iter_mut() {
                if let Op::CSel(csel) = &instr.op {
                    if csel.cmp_op == CmpOp::Ne
                        && matches!(
                            csel.cmp_type,
                            DataType::S32 | DataType::U32
                        )
                        && csel.cmp_srcs[1].is_zero()
                        && csel.cmp_srcs[0].src_mod.is_none()
                        && csel.cmp_srcs[0].swizzle.is_none()
                    {
                        let cmp = csel.cmp_srcs[0]
                            .src_ref
                            .as_ssa()
                            .filter(|vec| vec.comps() == 1)
                            .and_then(|vec| masks.get(&vec[0]));
                        if let Some(cmp) = cmp {
                            if let Some(fused) = fuse(model, cmp, csel) {
                                instr.op = fused;
                            }
                        }
                    }
                } else if let Some(cmp) = as_mask_compare(&instr.op) {
                    if let Some(vec) = cmp.dst.dst_ref.as_ssa() {
                        if vec.comps() == 1 {
                            masks.insert(vec[0], cmp.clone());
                        }
                    }
                }
            }
        }
    }
}
