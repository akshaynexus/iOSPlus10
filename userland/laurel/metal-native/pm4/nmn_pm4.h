/* SPDX-License-Identifier: MIT */
/*
 * Native Metal stack, command stream: a6xx registers and packets for one sysmem render pass, one draw, a 2D blit, a compute dispatch. Written from Mesa's Turnip (src/freedreno/vulkan; MIT) and checked against a Turnip capture of the same scene
 * (scripts/laurel/native/pm4-compare.sh). No Vulkan object anywhere. Bindless only: every texture, sampler and buffer is a slot in sets 0 and 1 (bridge/src/compile.rs).
 */
#ifndef NMN_PM4_H
#define NMN_PM4_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "nw.h"
#ifdef __cplusplus
extern "C" {
#endif

struct nmn_gpu;
struct nmn_gpu *nmn_gpu_new(struct nw_device *, char *why, size_t why_size);
void nmn_gpu_free(struct nmn_gpu *);
struct nw_device *nmn_gpu_device(struct nmn_gpu *);

/* Metal's MTLPixelFormat -> Mesa's pipe format; 0: this stack has no path for it. */
uint32_t nmn_format_from_metal(uint64_t metal_format);
uint32_t nmn_format_blocksize(uint32_t pipe_format);
bool nmn_format_is_depth_or_stencil(uint32_t pipe_format);

enum nmn_image_type { NMN_IMAGE_1D, NMN_IMAGE_2D, NMN_IMAGE_CUBE, NMN_IMAGE_3D, NMN_IMAGE_BUFFER };
struct nmn_image;
/* tiled: the GPU's own layout. stride != 0: linear, with this pitch. */
struct nmn_image *nmn_image_new(struct nmn_gpu *, uint32_t pipe_format, enum nmn_image_type, uint32_t width, uint32_t height, uint32_t depth, uint32_t levels, uint32_t layers, uint32_t samples, bool tiled, uint32_t stride);
void nmn_image_free(struct nmn_image *);
uint64_t nmn_image_size(const struct nmn_image *);
uint32_t nmn_image_pitch(const struct nmn_image *, uint32_t level);
uint64_t nmn_image_layer_offset(const struct nmn_image *, uint32_t level, uint32_t layer);
uint32_t nmn_image_format(const struct nmn_image *);
void nmn_image_bind(struct nmn_image *, uint64_t iova);
uint64_t nmn_image_iova(const struct nmn_image *);

/* 16 dwords each: what goes in a descriptor slot. */
void nmn_descriptor_image(const struct nmn_image *, uint32_t pipe_format, enum nmn_image_type view, uint32_t base_level, uint32_t levels, uint32_t base_layer, uint32_t layers, const uint8_t swizzle[4], bool storage, uint32_t out[16]);
void nmn_descriptor_buffer_texels(uint32_t pipe_format, uint64_t iova, uint32_t bytes, uint32_t out[16]);
void nmn_descriptor_ubo(uint64_t iova, uint64_t bytes, uint32_t out[16]);
void nmn_descriptor_ssbo(uint64_t iova, uint64_t bytes, uint32_t out[16]);
struct nmn_sampler_state {
	uint32_t min_filter, mag_filter, mip_filter; /* Metal's raw values */
	uint32_t s_address, t_address, r_address, border_color, normalized, max_anisotropy, compare;
	float lod_min, lod_max;
};
void nmn_descriptor_sampler(const struct nmn_sampler_state *, uint64_t border_iova, uint32_t out[16]);

/* One command stream: state for a whole submission. */
void nmn_cmd_init(struct nw_cs *, struct nmn_gpu *);

struct nmn_color_target {
	const struct nmn_image *image;
	uint32_t pipe_format, level, layer;
	bool clear;
	double clear_value[4];
};
struct nmn_pass {
	struct nmn_color_target colors[8];
	uint32_t color_count;
	const struct nmn_image *depth;
	bool clear_depth, clear_stencil;
	double clear_z;
	uint32_t clear_s;
	uint32_t width, height, samples;
};
void nmn_cmd_pass_begin(struct nw_cs *, struct nmn_gpu *, const struct nmn_pass *);
void nmn_cmd_pass_end(struct nw_cs *, const struct nmn_pass *);

/* Program state baked once, per pipeline. The stream is called, not copied. */
struct nmn_baked;
struct nmn_vertex_attr {
	uint32_t pipe_format, offset, binding;
	bool instanced;
	uint32_t step_rate;
	bool is_float;
};
struct nmn_blend {
	bool enable;
	uint32_t src_rgb, dst_rgb, op_rgb, src_a, dst_a, op_a, write_mask; /* Metal's raw values */
};
struct nmn_fixed {
	struct nmn_blend blend[8];
	uint32_t color_count, samples;
	struct nmn_vertex_attr attrs[32];
	uint32_t attr_count, strides[32], stride_count;
	bool rasterizer_discard;
};
struct nmn_baked *nmn_bake_render(struct nmn_gpu *, const void *vs_variant, const void *fs_variant, const struct nmn_fixed *, char *why, size_t why_size);
struct nmn_baked *nmn_bake_compute(struct nmn_gpu *, const void *cs_variant, char *why, size_t why_size);
void nmn_baked_free(struct nmn_gpu *, struct nmn_baked *);
void nmn_baked_info(const struct nmn_baked *, uint32_t *state_dwords, bool *reads_framebuffer);
void nmn_cmd_program(struct nw_cs *, const struct nmn_baked *);

struct nmn_raster {
	double viewport[6];     /* x, y, width, height, near, far */
	uint32_t scissor[4];    /* x, y, width, height */
	uint32_t cull_mode, winding, fill_mode;
	float depth_bias, slope_scale, bias_clamp, line_width, blend_color[4];
	uint32_t stencil_front, stencil_back;
	uint32_t depth_func;    /* 7: always */
	bool depth_write, depth_test, reads_framebuffer;
	uint32_t pass_width, pass_height;
	bool stencil_enable;
	uint32_t st_func[2], st_fail[2], st_zpass[2], st_zfail[2], st_read[2], st_write[2]; /* front, back; Metal's raw values */
};
void nmn_cmd_raster(struct nw_cs *, const struct nmn_raster *);
/* The bindless bases: set 0 and set 1. graphics false: compute. */
void nmn_cmd_descriptor_sets(struct nw_cs *, const uint64_t *set_iova, uint32_t count, bool graphics);
/* A stage's push range, as this stage's const file wants it (nmn_program_push_range). stage: 0 vertex, 1 fragment, 2 compute. */
void nmn_cmd_push(struct nw_cs *, unsigned stage, uint32_t first_vec4, const void *data, uint32_t vec4s);
void nmn_cmd_vertex_buffers(struct nw_cs *, const uint64_t *iova, const uint32_t *size, const uint32_t *stride, uint32_t count);
void nmn_cmd_draw(struct nw_cs *, uint32_t primitive /* Metal's raw value */, uint32_t vertex_count, uint32_t instances, uint32_t first_vertex, uint32_t first_instance);
void nmn_cmd_draw_indexed(struct nw_cs *, uint32_t primitive, uint32_t index_count, uint32_t instances, uint64_t index_iova, uint32_t index_bytes_max, bool wide, int32_t base_vertex, uint32_t first_instance);
void nmn_cmd_dispatch(struct nw_cs *, const struct nmn_baked *, const uint32_t groups[3], const uint32_t local[3]);

/* A barrier between passes in sysmem: what was written reaches memory, what was cached is dropped. */
void nmn_cmd_barrier(struct nw_cs *);
void nmn_cmd_copy_buffer(struct nw_cs *, uint64_t src, uint64_t dst, uint64_t bytes);
void nmn_cmd_fill_buffer(struct nw_cs *, uint64_t dst, uint64_t bytes, uint8_t value);
void nmn_cmd_copy_image(struct nw_cs *, const struct nmn_image *src, uint32_t src_level, uint32_t src_layer, const uint32_t src_origin[2], const struct nmn_image *dst, uint32_t dst_level, uint32_t dst_layer, const uint32_t dst_origin[2], const uint32_t size[2]);
void nmn_cmd_buffer_to_image(struct nw_cs *, uint64_t src, uint32_t pitch, const struct nmn_image *dst, uint32_t level, uint32_t layer, const uint32_t origin[2], const uint32_t size[2]);
void nmn_cmd_image_to_buffer(struct nw_cs *, const struct nmn_image *src, uint32_t level, uint32_t layer, const uint32_t origin[2], const uint32_t size[2], uint64_t dst, uint32_t pitch);
void nmn_cmd_end_marker(struct nw_cs *, uint64_t iova, uint32_t value);
/* generateMipmaps: one level from the level above, filtered */
void nmn_cmd_mip_down(struct nw_cs *, const struct nmn_image *, uint32_t level, uint32_t layer);

#ifdef __cplusplus
}
#endif
#endif
