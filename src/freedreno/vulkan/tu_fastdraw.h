/*
 * Copyright © 2026 ARMSX2
 * SPDX-License-Identifier: MIT
 */

#ifndef TU_FASTDRAW_H
#define TU_FASTDRAW_H

#include "tu_common.h"
#include "tu_cs.h"
#include "tu_pipeline.h"
#include "tu_suballoc.h"

/* ARMSX2 pack change, not upstream.
 *
 * The direct path: one call that records a whole indexed draw from objects
 * the application already holds, in place of vkCmdBindPipeline,
 * vkCmdBindDescriptorSets, vkCmdPushDescriptorSet, vkCmdSetScissor,
 * vkCmdSetBlendConstants and vkCmdDrawIndexed. It is not exported: the
 * application reaches it through vkCmdDrawRunARMSX2 (below), which takes
 * each group of a run through it or, where it declines, through the
 * expansion.
 *
 * Contract:
 *  - The pipeline layout has two sets: set 0 holds only dynamic uniform
 *    buffers and is bound through `ubo_set` with `dynamic_offsets`; set 1 is
 *    a push descriptor set of sampled images and combined image samplers,
 *    given as `views`/`samplers` indexed by binding number. `tex_mask` names
 *    the bindings of set 1 the pipeline's shaders can read; the others are
 *    not written and must not be read.
 *  - Line width is 1. Viewport, vertex buffers and the index buffer are the
 *    ones last set with the ordinary calls.
 *  - The call returns VK_FALSE without recording anything when it cannot
 *    take the draw (first draw of a render pass, state it does not know,
 *    a pipeline outside its subset). The application then records the draw
 *    with the ordinary calls.
 *  - After a call that returned VK_TRUE the ordinary state is what the
 *    equivalent ordinary calls would have left (this pipeline bound, this
 *    scissor and these blend constants set, line width 1, set 0 bound with
 *    these offsets), except the push descriptor set: the application pushes
 *    every binding of set 1 again before its next ordinary draw.
 */
#define TU_FASTDRAW_MAX_TEX 8

struct tu_fastdraw_record {
   uint32_t size; /* sizeof(struct tu_fastdraw_record) */
   uint32_t tex_mask;
   VkPipeline pipeline;
   VkPipelineLayout layout;
   VkDescriptorSet ubo_set;
   uint32_t dynamic_offsets[2];
   VkImageView views[TU_FASTDRAW_MAX_TEX];
   VkSampler samplers[TU_FASTDRAW_MAX_TEX];
   VkRect2D scissor;
   float blend_constants[4];
   uint32_t index_count;
   uint32_t first_index;
   int32_t vertex_offset;
   uint32_t reserved;
};

enum tu_fastdraw_decline {
   TU_FASTDRAW_OK = 0,
   TU_FASTDRAW_NOT_GRAPHICS,
   TU_FASTDRAW_STAGES,
   TU_FASTDRAW_PIPELINE_FACTS,
   TU_FASTDRAW_FS_FEATURES,
   TU_FASTDRAW_DRIVER_PARAMS,
   TU_FASTDRAW_UNBAKED_GROUP,
   TU_FASTDRAW_LAYOUT,
   TU_FASTDRAW_ALLOC,
   /* per call */
   TU_FASTDRAW_RECORD,
   TU_FASTDRAW_CMD_DIRTY,
   TU_FASTDRAW_DYN_DIRTY,
   TU_FASTDRAW_PASS,
   TU_FASTDRAW_ENV,
   TU_FASTDRAW_ATTACHMENTS,
   /* groups recorded through the expansion because the run is malformed */
   TU_FASTDRAW_RUN_ABI,
   TU_FASTDRAW_DECLINE_COUNT,
};

#define TU_FASTDRAW_OWN_GROUPS                                                \
   ((1u << TU_DYNAMIC_STATE_SCISSOR) | (1u << TU_DYNAMIC_STATE_RAST) |        \
    (1u << TU_DYNAMIC_STATE_BLEND_CONSTANTS))

/* tu_fastdraw_dirty_slots(): beside the dynamic slots, the inputs of the
 * pipeline facts (bandwidth, LRZ blend status, disable_fs).
 */
#define TU_FASTDRAW_SLOT_FACTS 31

#define TU_FASTDRAW_MAX_GROUPS (12 + TU_DYNAMIC_STATE_COUNT)

/* vkCmdDrawRunARMSX2: a run of indexed draws in one call.
 *
 *    void vkCmdDrawRunARMSX2(VkCommandBuffer, const struct tu_run *run);
 *
 * Found with vkGetDeviceProcAddr(device, "vkCmdDrawRunARMSX2"). Defined as
 * exactly the effect of this sequence of ordinary calls, for each group g in
 * order (the "expansion"):
 *
 *    vkCmdBindPipeline(states[g.state].pipeline)
 *    vkCmdSetScissor(0, 1, &g.scissor)
 *    vkCmdSetBlendConstants({g.blend_constant x 4})
 *    vkCmdBindDescriptorSets(set 0 = run.set0, offsets g.dyn_offset[0..1])
 *    vkCmdPushDescriptorSet(set 1, the bindings in states[g.state].tex_mask,
 *                           from textures[g.tex_first...] in binding order)
 *    vkCmdDrawIndexed(g.index_count, 1, g.first_index, g.vertex_offset, 0)
 *
 * with the same layout for every group, line width 1, and the viewport,
 * vertex buffers and index buffer as last set with the ordinary calls. A
 * group whose pipeline or command-buffer state the entry cannot take is
 * recorded through the expansion itself, so nothing is refused at draw time.
 * After the call the ordinary state is the expansion's, except that set 1 is
 * not known: the application pushes the bindings it needs again before its
 * next ordinary draw.
 */
struct tu_run_state {
   VkPipeline pipeline;
   uint32_t tex_mask; /* the set-1 bindings the pipeline's shaders read */
   uint32_t reserved;
};

struct tu_run_texture {
   VkImageView view;
   VkSampler sampler; /* only read for a combined image sampler binding */
};

struct tu_run_group {
   uint32_t state;
   uint32_t tex_first;
   uint32_t first_index;
   uint32_t index_count;
   int32_t vertex_offset;
   uint32_t dyn_offset[2];
   float blend_constant;
   VkRect2D scissor;
};

#define TU_RUN_ABI 1

struct tu_run {
   uint32_t size; /* sizeof(struct tu_run) */
   uint32_t abi;  /* TU_RUN_ABI */
   uint32_t group_count;
   uint32_t reserved;
   VkPipelineLayout layout;
   VkDescriptorSet set0;
   const struct tu_run_state *states;
   const struct tu_run_group *groups;
   const struct tu_run_texture *textures;
};

/* What the entry needs to know about a pipeline, built at its first use
 * there (tu_fastdraw_bake_pipeline) and freed with the pipeline.
 */
struct tu_fastdraw_bake {
   uint8_t decline; /* enum tu_fastdraw_decline; 0 = usable */

   /* Every group the pipeline alone decides: its own (program, PRIM_MODE_GMEM,
    * the dynamic groups in set_state_mask) and the ones the generic path
    * rebuilds at each draw from pipeline state only (RAST at line width 1,
    * PRIM_MODE_SYSMEM). All carry a content id.
    */
   uint8_t n_groups;
   uint8_t gid[TU_FASTDRAW_MAX_GROUPS];
   struct tu_draw_state gstate[TU_FASTDRAW_MAX_GROUPS];

   /* Interned id of everything in the pipeline that feeds a group the entry
    * leaves to the generic path (viewport and the like): two pipelines with
    * the same id can follow each other without those groups being rebuilt.
    */
   uint32_t env_id;
   /* Interned id of the inputs of the LRZ and depth-plane group. */
   uint32_t lrz_id;
   /* The pipeline left disable_fs to draw time (its fragment shader can
    * discard, which only matters under an occlusion query): it was computed
    * for the render pass of the first use, whose relevant attachments are
    * rp_key (tu_fastdraw_rp_key), with no occlusion query running.
    */
   bool disable_fs_from_rp;
   uint32_t rp_key;
   /* The pipeline sets the attachment feedback-loop value statically
    * (fbl_value): binding it puts that value in the runtime, which the
    * direct path does in its place.
    */
   bool fbl_static;
   VkImageAspectFlags fbl_value;

   struct vk_depth_stencil_state ds;
   bool alpha_to_coverage;
   uint8_t lrz_blend_status;
   bool disable_fs;
   bool fb_flush;
   bool rp_update;
   bool single_prim;
   bool msaa_disable;
   bool scissor_dyn;
   bool blend_constants_dyn;
   bool needs_depth_att;
   bool needs_stencil_att;
   bool raster_order;
   bool disable_gmem;
   bool has_tess;
   VkImageAspectFlags feedback_loops;

   uint32_t bw_sum;
   uint32_t draw_initiator; /* without the index size */
   uint32_t pc_cntl;
   uint32_t consts_dwords;

   const struct tu_pipeline_layout *layout;
   uint32_t tex_mask;
   uint32_t tex_units;  /* descriptor-sized units to allocate for set 1 */
   uint32_t dyn_units;  /* the same for the dynamic descriptors */
   uint8_t n_tex;
   struct {
      uint8_t binding;
      bool combined;
      uint16_t offset_dw;
   } tex[TU_FASTDRAW_MAX_TEX];
   uint16_t dyn_offset_dw[2]; /* where each dynamic UBO descriptor goes */
   struct tu_draw_state load_state;

   struct tu_suballoc_bo bo;
   bool has_bo;
};

template <chip CHIP>
struct tu_fastdraw_bake *
tu_fastdraw_bake_pipeline(struct tu_device *dev, struct tu_pipeline *pipeline,
                          struct tu_pipeline_layout *layout,
                          uint32_t tex_mask,
                          const struct vk_render_pass_state *rp);

uint32_t
tu_fastdraw_rp_key(const struct tu_pipeline *pipeline,
                   const struct vk_render_pass_state *rp);

uint32_t
tu_fastdraw_env_id(struct tu_device *dev, struct tu_pipeline *pipeline);

void
tu_fastdraw_dirty_slots(struct vk_dynamic_graphics_state *d, uint32_t slot_mask);

void
tu_fastdraw_bake_free(struct tu_device *dev, struct tu_pipeline *pipeline);

PFN_vkVoidFunction
tu_fastdraw_entry(struct tu_device *dev);

#endif /* TU_FASTDRAW_H */
