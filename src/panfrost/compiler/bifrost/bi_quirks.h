/*
 * Copyright (C) 2019-2020 Collabora, Ltd.
 * SPDX-License-Identifier: MIT
 */

#ifndef __BI_QUIRKS_H
#define __BI_QUIRKS_H

#include "panfrost/model/pan_model.h"
#include "panfrost/compiler/pan_compiler.h"

/* Model-specific quirks requiring compiler workarounds/etc. Quirks
 * may be errata requiring a workaround, or features. We're trying to be
 * quirk-positive here; quirky is the best! */

/* Whether this GPU lacks support for fp32 transcendentals, requiring backend
 * lowering to low-precision lookup tables and polynomial approximation */

#define BIFROST_NO_FP32_TRANSCENDENTALS (1 << 0)

/* Whether this GPU lacks support for the full form of the CLPER instruction.
 * These GPUs use a simple encoding of CLPER that does not support
 * inactive_result, subgroup_size, or lane_op. Using those features requires
 * lowering to additional ALU instructions. The encoding forces inactive_result
 * = zero, subgroup_size = subgroup4, and lane_op = none. */

#define BIFROST_LIMITED_CLPER (1 << 1)

static inline unsigned
bifrost_get_quirks(unsigned arch, const struct pan_model *model)
{
   /* If we don't know the model, be conservative and use arch_minor = 0.
    *
    * All Bifrost quirks are really just features added in subarchitecture
    * versions.
    */
   unsigned arch_minor = 0;
   if (model)
      arch_minor = (model->gpu_prod_id >> 8) & 0xff;

   /* Applies to archs before 6.2 */
   unsigned quirks = 0;
   if (arch < 7 && arch_minor < 2)
      quirks |= BIFROST_NO_FP32_TRANSCENDENTALS;

   /* Applies to archs before 7.2 */
   if (arch < 7 || (arch == 7 && arch_minor < 2))
      quirks |= BIFROST_LIMITED_CLPER;

   return quirks;
}

/* The subgroup size of a Bifrost GPU: its warp width. The GPUs before 7.2
 * (Mali-G31 and G51 at 7.0) run 4-wide warps, not pan_subgroup_size's 8:
 * on a G31 the lane ID counts 0..3 in every group of 4 invocations. They
 * are the BIFROST_LIMITED_CLPER GPUs, whose CLPER is fixed at subgroup4. */
static inline unsigned
bifrost_subgroup_size(unsigned arch, const struct pan_model *model)
{
   if (arch < 9 && (bifrost_get_quirks(arch, model) & BIFROST_LIMITED_CLPER))
      return 4;
   return pan_subgroup_size(arch);
}

#endif
