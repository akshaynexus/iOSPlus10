/* SPDX-License-Identifier: MIT */
/* Native Metal stack, shaders: SPIR-V words (from the metal2vulkan crate, in memory) -> NIR -> our bindless lowering -> ir3 code for the A6xx, with no Vulkan object. See nmn_shader.c. */
#ifndef NMN_SHADER_H
#define NMN_SHADER_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

/* The kernel's facts; 0 keeps the table's value. */
struct nmn_compiler *nmn_compiler_new(uint32_t chip_id, char *why, size_t why_size);
void nmn_compiler_free(struct nmn_compiler *);
const char *nmn_compiler_gpu_name(const struct nmn_compiler *);

/* How a descriptor is laid out in a set: slots of A6XX_TEX_CONST_DWORDS (16 dwords). */
enum nmn_descriptor_kind {
	NMN_DESC_SAMPLER,
	NMN_DESC_COMBINED,      /* two slots: the image, then the sampler (Turnip's order) */
	NMN_DESC_IMAGE,         /* sampled or storage image, texel buffer, input attachment */
	NMN_DESC_UBO,
	NMN_DESC_SSBO,
};
struct nmn_binding {
	uint32_t set, binding, kind, offset, stride, count;
};
struct nmn_layout {
	const struct nmn_binding *bindings;
	uint32_t binding_count;
	uint32_t push_bytes;    /* the largest push range of any stage */
};
struct nmn_spec {
	uint32_t id;
	uint32_t value;
};
struct nmn_stage_input {
	uint32_t stage;         /* 0 vertex, 1 fragment, 2 compute: Mesa's gl_shader_stage is mapped inside */
	const uint32_t *spirv;
	size_t words;
	const char *entry;
	const struct nmn_spec *spec;
	uint32_t spec_count;
};

/* What one compiled stage says about itself, for the statistics and for the PM4 layer. */
struct nmn_stage_info {
	uint32_t instructions, nops, movs, covs, sizedwords, half_regs, full_regs, const_vec4, tex_ops, mem_ops, sstall, systall, loops;
	uint32_t instrlen;      /* units of 16 instructions */
	bool reads_framebuffer; /* an input attachment survives into this stage's code */
	bool has_kill, writes_z, needs_full_quad;
};

struct nmn_program;     /* one vertex + one fragment, or one compute */
struct nmn_program *nmn_program_render(struct nmn_compiler *, const struct nmn_layout *, const struct nmn_stage_input *vertex, const struct nmn_stage_input *fragment /* may be NULL */, char *why, size_t why_size);
struct nmn_program *nmn_program_compute(struct nmn_compiler *, const struct nmn_layout *, const struct nmn_stage_input *kernel, uint32_t local_size_x, uint32_t local_size_y, uint32_t local_size_z, char *why, size_t why_size);
void nmn_program_free(struct nmn_program *);
bool nmn_program_info(const struct nmn_program *, unsigned stage, struct nmn_stage_info *);
/* The opaque ir3_shader_variant of a stage, for nmn_pm4. NULL: no such stage. */
const void *nmn_program_variant(const struct nmn_program *, unsigned stage);
/* The stage's code and its constant data, with a stage's push range in the const file. */
const void *nmn_program_code(const struct nmn_program *, unsigned stage, uint32_t *bytes);
bool nmn_program_push_range(const struct nmn_program *, unsigned stage, uint32_t *first_vec4, uint32_t *vec4s, uint32_t *lo_dwords);

#ifdef __cplusplus
}
#endif
#endif
