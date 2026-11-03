/* SPDX-License-Identifier: MIT */
/*
 * Native Metal stack, shaders. SPIR-V -> NIR -> ir3, with the steps of Mesa's Turnip (src/freedreno/vulkan/tu_shader.cc, src/vulkan/runtime/vk_nir.c; Copyright Red Hat, Valve, Igalia and others, MIT), and with
 * the descriptors of the native stack in place of a VkPipelineLayout. What differs from Turnip here:
 *  - No VkDevice, no pipeline cache, no shared constants: push constants go per stage (IR3_PUSH_CONSTS_PER_STAGE).
 *  - Input attachments are plain bindless textures read at the fragment's coordinate: the stack draws in sysmem only. reads_framebuffer says if one survives optimization: the PM4 layer turns on the flush mode only then.
 */
#include "nmn_shader.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "nir.h"
#include "glsl_types.h"
#include "nir_builder.h"
#include "spirv/nir_spirv.h"
#include "spirv/spirv_info.h"
#include "ir3_compiler.h"
#include "ir3_nir.h"
#include "ir3_shader.h"
#include "freedreno_dev_info.h"
#include "util/blob.h"
#include "util/ralloc.h"
#include "util/u_math.h"

struct nmn_compiler {
	struct fd_dev_id id;
	struct fd_dev_info info;
	struct ir3_compiler *ir3;
	char name[32];
};

struct nmn_compiled {
	struct ir3_shader *shader;
	struct ir3_shader_variant *variant;
	struct nmn_stage_info info;
	uint32_t push_lo_dwords, push_dwords, push_first_vec4;
};

struct nmn_program {
	struct nmn_compiled stage[2];
	unsigned count;
};

struct nmn_compiler *nmn_compiler_new(uint32_t chip_id, char *why, size_t why_size)
{
	struct nmn_compiler *c = calloc(1, sizeof(*c));
	if (c == NULL) {
		snprintf(why, why_size, "no memory");
		return NULL;
	}
	glsl_type_singleton_init_or_ref();
	c->id.gpu_id = 0;
	c->id.chip_id = chip_id;
	if (fd_dev_info_raw(&c->id) == NULL) {
		snprintf(why, why_size, "Mesa has no device row for chip %#x", chip_id);
		glsl_type_singleton_decref();
		free(c);
		return NULL;
	}
	c->info = fd_dev_info(&c->id);
	const struct ir3_compiler_options options = {
		.push_ubo_with_preamble = true,
		.disable_cache = true,
		.bindless_fb_read_descriptor = -1,
		.bindless_fb_read_slot = -1,
		.storage_16bit = c->info.a6xx.storage_16bit,
		.storage_8bit = c->info.a7xx.storage_8bit,
		.shared_push_consts = false,
	};
	c->ir3 = ir3_compiler_create(NULL, &c->id, &c->info, &options);
	if (c->ir3 == NULL) {
		snprintf(why, why_size, "ir3_compiler_create failed");
		glsl_type_singleton_decref();
		free(c);
		return NULL;
	}
	snprintf(c->name, sizeof(c->name), "FD%u", (chip_id >> 24) * 100 + ((chip_id >> 16) & 0xff) * 10 + ((chip_id >> 8) & 0xff));
	return c;
}

void nmn_compiler_free(struct nmn_compiler *c)
{
	if (c == NULL)
		return;
	ir3_compiler_destroy(c->ir3);
	glsl_type_singleton_decref();
	free(c);
}

const char *nmn_compiler_gpu_name(const struct nmn_compiler *c) { return c->name; }

static const struct nmn_binding *find_binding(const struct nmn_layout *l, uint32_t set, uint32_t binding)
{
	for (uint32_t i = 0; i < l->binding_count; i++)
		if (l->bindings[i].set == set && l->bindings[i].binding == binding)
			return &l->bindings[i];
	return NULL;
}

struct lower_state {
	const struct nmn_layout *layout;
	struct nmn_compiled *out;
	struct ir3_compiler *ir3;
	uint32_t push_first_dword;
	bool bad;
	char *why;
	size_t why_size;
};

/* tu_shader.cc lower_vulkan_resource_index: (set, slot, shift) */
static void lower_resource_index(nir_builder *b, nir_intrinsic_instr *instr, struct lower_state *st)
{
	unsigned set = nir_intrinsic_desc_set(instr);
	unsigned binding = nir_intrinsic_binding(instr);
	const struct nmn_binding *bl = find_binding(st->layout, set, binding);
	if (bl == NULL) {
		st->bad = true;
		snprintf(st->why, st->why_size, "no layout for set %u binding %u", set, binding);
		return;
	}
	nir_def *shift = nir_imm_int(b, util_logbase2(bl->stride ? bl->stride : 1));
	nir_def *def = nir_vec3(b, nir_imm_int(b, set), nir_iadd(b, nir_imm_int(b, bl->offset), nir_ishl(b, instr->src[0].ssa, shift)), shift);
	nir_def_replace(&instr->def, def);
}

static void lower_resource_reindex(nir_builder *b, nir_intrinsic_instr *instr)
{
	nir_def *old_index = instr->src[0].ssa, *delta = instr->src[1].ssa, *shift = nir_channel(b, old_index, 2);
	nir_def *new_index = nir_vec3(b, nir_channel(b, old_index, 0), nir_iadd(b, nir_channel(b, old_index, 1), nir_ishl(b, delta, shift)), shift);
	nir_def_replace(&instr->def, new_index);
}

static void lower_load_descriptor(nir_builder *b, nir_intrinsic_instr *instr)
{
	nir_def *old_index = instr->src[0].ssa;
	nir_def_replace(&instr->def, nir_vec3(b, nir_channel(b, old_index, 0), nir_channel(b, old_index, 1), nir_imm_int(b, 0)));
}

/* tu_shader.cc lower_ssbo_ubo_intrinsic. The set of our descriptors is always a constant: a non-constant one is refused, not branched on. */
static bool lower_buffer_access(nir_builder *b, nir_intrinsic_instr *intrin, struct lower_state *st)
{
	unsigned buffer_src = intrin->intrinsic == nir_intrinsic_store_ssbo ? 1 : 0;
	if (intrin->src[buffer_src].ssa->num_components == 1)
		return false;   /* a driver's own UBO */
	nir_scalar set = nir_scalar_resolved(intrin->src[buffer_src].ssa, 0);
	nir_def *descriptor = nir_channel(b, intrin->src[buffer_src].ssa, 1);
	if (!nir_scalar_is_const(set)) {
		st->bad = true;
		snprintf(st->why, st->why_size, "a buffer access whose descriptor set is not a constant");
		return false;
	}
	nir_src_rewrite(&intrin->src[buffer_src], nir_bindless_resource_ir3(b, 32, descriptor, .desc_set = nir_scalar_as_uint(set)));
	return true;
}

/* tu_shader.cc build_bindless, with one slot kind table in place of VkDescriptorSetLayout */
static nir_def *build_bindless(nir_builder *b, nir_deref_instr *deref, bool is_sampler, struct lower_state *st)
{
	nir_variable *var = nir_deref_instr_get_variable(deref);
	const struct nmn_binding *bl = find_binding(st->layout, var->data.descriptor_set, var->data.binding);
	if (bl == NULL) {
		st->bad = true;
		snprintf(st->why, st->why_size, "no layout for set %u binding %u", var->data.descriptor_set, var->data.binding);
		return nir_imm_int(b, 0);
	}
	unsigned offset = is_sampler && bl->kind == NMN_DESC_COMBINED ? 1 : 0;
	nir_def *slot = nir_imm_int(b, bl->offset + offset);
	if (deref->deref_type != nir_deref_type_var)
		slot = nir_iadd(b, slot, nir_imul_imm(b, deref->arr.index.ssa, bl->stride));
	return nir_bindless_resource_ir3(b, 32, slot, .desc_set = var->data.descriptor_set);
}

static bool lower_tex(nir_builder *b, nir_tex_instr *tex, struct lower_state *st)
{
	int sampler_src = nir_tex_instr_src_index(tex, nir_tex_src_sampler_deref);
	if (sampler_src >= 0) {
		nir_def *h = build_bindless(b, nir_src_as_deref(tex->src[sampler_src].src), true, st);
		nir_src_rewrite(&tex->src[sampler_src].src, h);
		tex->src[sampler_src].src_type = nir_tex_src_sampler_handle;
	}
	int tex_src = nir_tex_instr_src_index(tex, nir_tex_src_texture_deref);
	if (tex_src >= 0) {
		nir_def *h = build_bindless(b, nir_src_as_deref(tex->src[tex_src].src), false, st);
		nir_src_rewrite(&tex->src[tex_src].src, h);
		tex->src[tex_src].src_type = nir_tex_src_texture_handle;
	}
	return true;
}

static bool lower_instr(nir_builder *b, nir_instr *instr, void *data)
{
	struct lower_state *st = data;
	b->cursor = nir_before_instr(instr);
	if (instr->type == nir_instr_type_tex)
		return lower_tex(b, nir_instr_as_tex(instr), st);
	if (instr->type != nir_instr_type_intrinsic)
		return false;
	nir_intrinsic_instr *intr = nir_instr_as_intrinsic(instr);
	switch (intr->intrinsic) {
	case nir_intrinsic_load_push_constant: {
		/* base: bytes (0 after nir_lower_explicit_io with a 32-bit offset); src[0]: the byte offset. The stage's range begins at lo_dwords. */
		uint32_t dword = nir_intrinsic_base(intr) / 4;
		nir_def *load = nir_load_const_ir3(b, intr->num_components, intr->def.bit_size, nir_ushr_imm(b, intr->src[0].ssa, 2),
						   .base = st->push_first_dword + dword - st->out->push_lo_dwords);
		nir_def_replace(&intr->def, load);
		return true;
	}
	case nir_intrinsic_load_vulkan_descriptor:
		lower_load_descriptor(b, intr);
		return true;
	case nir_intrinsic_vulkan_resource_index:
		lower_resource_index(b, intr, st);
		return true;
	case nir_intrinsic_vulkan_resource_reindex:
		lower_resource_reindex(b, intr);
		return true;
	case nir_intrinsic_load_ubo:
	case nir_intrinsic_load_ssbo:
	case nir_intrinsic_load_uav_ir3:
	case nir_intrinsic_store_ssbo:
	case nir_intrinsic_ssbo_atomic:
	case nir_intrinsic_ssbo_atomic_swap:
	case nir_intrinsic_get_ssbo_size:
		return lower_buffer_access(b, intr, st);
	case nir_intrinsic_image_deref_load:
	case nir_intrinsic_image_deref_store:
	case nir_intrinsic_image_deref_atomic:
	case nir_intrinsic_image_deref_atomic_swap:
	case nir_intrinsic_image_deref_size:
	case nir_intrinsic_image_deref_samples: {
		nir_def *h = build_bindless(b, nir_src_as_deref(intr->src[0]), false, st);
		nir_rewrite_image_intrinsic(intr, h, true);
		return true;
	}
	default:
		return false;
	}
}

/* tu_shader.cc gather_push_constants: the range this stage really reads, with OFFSET's 16-dword alignment */
static void gather_push(nir_shader *shader, struct nmn_compiled *out)
{
	uint32_t min = UINT32_MAX, max = 0;
	nir_foreach_function_impl(impl, shader) {
		nir_foreach_block(block, impl) {
			nir_foreach_instr(instr, block) {
				if (instr->type != nir_instr_type_intrinsic)
					continue;
				nir_intrinsic_instr *intrin = nir_instr_as_intrinsic(instr);
				if (intrin->intrinsic != nir_intrinsic_load_push_constant)
					continue;
				uint32_t base = nir_intrinsic_base(intrin), range = nir_intrinsic_range(intrin);
				min = MIN2(min, base);
				max = MAX2(max, base + range);
			}
		}
	}
	if (min >= max) {
		out->push_lo_dwords = out->push_dwords = 0;
		return;
	}
	out->push_lo_dwords = (min / 4) / 4 * 4;
	out->push_dwords = align(max, 16) / 4 - out->push_lo_dwords;
}

static void spirv_debug(void *data, enum nir_spirv_debug_level level, size_t offset, const char *message)
{
	char **slot = data;
	if (level == NIR_SPIRV_DEBUG_LEVEL_ERROR && *slot == NULL)
		*slot = strdup(message);
}

/* vk_spirv_to_nir + tu_spirv_to_nir */
static nir_shader *to_nir(struct nmn_compiler *c, void *mem_ctx, gl_shader_stage stage, const struct nmn_stage_input *in, char *why, size_t why_size)
{
	struct spirv_capabilities caps;
	memset(&caps, 1, sizeof(caps));  /* a table of bools: what the module may ask is the crate's device profile. spirv_to_nir has its own limits and fails on those. */
	char *message = NULL;
	struct spirv_to_nir_options options = {
		.capabilities = &caps,
		.view_index_is_input = stage == MESA_SHADER_FRAGMENT,
		.mediump_16bit_alu = true,
		.ubo_addr_format = nir_address_format_vec2_index_32bit_offset,
		.ssbo_addr_format = nir_address_format_vec2_index_32bit_offset,
		.phys_ssbo_addr_format = nir_address_format_64bit_global,
		.push_const_addr_format = nir_address_format_logical,
		.shared_addr_format = nir_address_format_32bit_offset,
		.global_addr_format = nir_address_format_64bit_global,
		.debug = {.func = spirv_debug, .private_data = &message},
		.subgroup_size = SUBGROUP_SIZE_VARYING,
	};
	struct nir_spirv_specialization *spec = NULL;
	if (in->spec_count) {
		spec = calloc(in->spec_count, sizeof(*spec));
		for (uint32_t i = 0; i < in->spec_count; i++) {
			spec[i].id = in->spec[i].id;
			spec[i].value.u32 = in->spec[i].value;
		}
	}
	nir_shader *nir = spirv_to_nir(in->spirv, in->words, spec, in->spec_count, stage, in->entry, &options, ir3_get_compiler_options(c->ir3));
	free(spec);
	if (nir == NULL) {
		snprintf(why, why_size, "spirv_to_nir: %s", message ? message : "failed");
		free(message);
		return NULL;
	}
	free(message);
	ralloc_steal(mem_ctx, nir);

	NIR_PASS_V(nir, nir_lower_variable_initializers, nir_var_function_temp);
	NIR_PASS_V(nir, nir_lower_returns);
	NIR_PASS_V(nir, nir_inline_functions);
	NIR_PASS_V(nir, nir_copy_prop);
	NIR_PASS_V(nir, nir_opt_deref);
	nir_remove_non_entrypoints(nir);
	NIR_PASS_V(nir, nir_lower_variable_initializers, ~0);
	NIR_PASS_V(nir, nir_split_var_copies);
	NIR_PASS_V(nir, nir_split_per_member_structs);
	NIR_PASS_V(nir, nir_remove_dead_variables, nir_var_shader_in | nir_var_shader_out | nir_var_system_value, NULL);
	NIR_PASS_V(nir, nir_lower_clip_cull_distance_arrays);
	NIR_PASS_V(nir, nir_propagate_invariant, false);

	nir->info.num_ubos = 0;
	nir->info.num_ssbos = 0;
	const struct nir_lower_sysvals_to_varyings_options sysvals = {.point_coord = true};
	NIR_PASS_V(nir, nir_lower_sysvals_to_varyings, &sysvals);
	NIR_PASS_V(nir, nir_lower_global_vars_to_local);
	NIR_PASS_V(nir, nir_opt_find_array_copies);
	NIR_PASS_V(nir, nir_opt_copy_prop_vars);
	NIR_PASS_V(nir, nir_opt_dce);
	nir_shader_gather_info(nir, nir_shader_get_entrypoint(nir));
	NIR_PASS_V(nir, nir_split_var_copies);
	NIR_PASS_V(nir, nir_lower_var_copies);
	NIR_PASS_V(nir, nir_lower_mediump_vars, nir_var_function_temp | nir_var_shader_temp | nir_var_mem_shared);
	NIR_PASS_V(nir, nir_opt_copy_prop_vars);
	NIR_PASS_V(nir, nir_opt_combine_stores, nir_var_all);
	NIR_PASS_V(nir, nir_lower_system_values);
	NIR_PASS_V(nir, nir_lower_is_helper_invocation);
	const struct ir3_shader_nir_options opt = {0};
	ir3_optimize_loop(c->ir3, &opt, nir);
	NIR_PASS_V(nir, nir_opt_conditional_discard);
	return nir;
}

static void link_pair(nir_shader *producer, nir_shader *consumer)
{
	if (nir_link_opt_varyings(producer, consumer)) {
		NIR_PASS_V(consumer, nir_opt_constant_folding);
		NIR_PASS_V(consumer, nir_opt_algebraic);
		NIR_PASS_V(consumer, nir_opt_dce);
	}
	NIR_PASS_V(producer, nir_remove_dead_variables, nir_var_shader_out, NULL);
	NIR_PASS_V(consumer, nir_remove_dead_variables, nir_var_shader_in, NULL);
	bool progress = nir_remove_unused_varyings(producer, consumer);
	nir_compact_varyings(producer, consumer, true);
	if (progress) {
		if (nir_lower_global_vars_to_local(producer)) {
			NIR_PASS_V(producer, nir_remove_dead_variables, nir_var_shader_temp, NULL);
			NIR_PASS_V(producer, nir_opt_dce);
		}
		nir_lower_global_vars_to_local(consumer);
	}
}

static void shared_type_info(const struct glsl_type *type, unsigned *size, unsigned *align_out)
{
	unsigned length = glsl_type_is_vector(type) ? glsl_get_vector_elements(type) : 1;
	unsigned comp_size = glsl_type_is_boolean(type) ? 4 : glsl_get_bit_size(type) / 8;
	*size = comp_size * length;
	*align_out = comp_size * (length == 3 ? 4 : length);
}

/* the part of tu_shader_create between the NIR and the variant */
static bool finish_stage(struct nmn_compiler *c, const struct nmn_layout *layout, nir_shader *nir, struct nmn_compiled *out, const struct ir3_shader_key *key, char *why, size_t why_size)
{
	const nir_opt_access_options access = {.is_vulkan = true};
	NIR_PASS_V(nir, nir_opt_access, &access);
	if (nir->info.stage == MESA_SHADER_FRAGMENT) {
		/* a framebuffer read in sysmem is a texture read at this fragment's coordinate. The pass makes progress only where a read survived the optimizations above. */
		const nir_input_attachment_options att = {.use_fragcoord_sysval = true, .use_layer_id_sysval = false};
		bool reads = false;
		NIR_PASS(reads, nir, nir_lower_input_attachments, &att);
		out->info.reads_framebuffer = reads;
	}
	ir3_nir_lower_io_to_temporaries(nir);
	NIR_PASS_V(nir, nir_lower_explicit_io, nir_var_mem_push_const, nir_address_format_32bit_offset);
	NIR_PASS_V(nir, nir_lower_explicit_io, nir_var_mem_ubo | nir_var_mem_ssbo, nir_address_format_vec2_index_32bit_offset);
	NIR_PASS_V(nir, nir_lower_explicit_io, nir_var_mem_global, nir_address_format_64bit_global);
	if (nir->info.stage == MESA_SHADER_COMPUTE) {
		if (!nir->info.shared_memory_explicit_layout)
			NIR_PASS_V(nir, nir_lower_vars_to_explicit_types, nir_var_mem_shared, shared_type_info);
		NIR_PASS_V(nir, nir_lower_explicit_io, nir_var_mem_shared, nir_address_format_32bit_offset);
		if (nir->info.zero_initialize_shared_memory && nir->info.shared_size > 0)
			NIR_PASS_V(nir, nir_zero_initialize_shared_memory, ALIGN(nir->info.shared_size, 16), 16);
		const struct nir_lower_compute_system_values_options sysv = {.has_base_workgroup_id = true};
		NIR_PASS_V(nir, nir_lower_compute_system_values, &sysv);
	}
	nir_assign_io_var_locations(nir, nir_var_shader_in, &nir->num_inputs, nir->info.stage);
	nir_assign_io_var_locations(nir, nir_var_shader_out, &nir->num_outputs, nir->info.stage);
	{
		nir_lower_mem_access_bit_sizes_options o = {.callback = ir3_mem_access_size_align, .modes = nir_var_mem_push_const};
		NIR_PASS_V(nir, nir_lower_mem_access_bit_sizes, &o);
	}
	struct ir3_const_allocations allocs = {0};
	if (nir->info.stage == MESA_SHADER_VERTEX) {
		uint32_t params = ir3_nir_scan_driver_consts(c->ir3, nir, NULL);
		ir3_alloc_driver_params(&allocs, &params, c->ir3, nir->info.stage);
	}
	gather_push(nir, out);
	unsigned vec4s = align(DIV_ROUND_UP(out->push_dwords, 4), c->ir3->const_upload_unit);
	ir3_const_alloc(&allocs, IR3_CONST_ALLOC_PUSH_CONSTS, vec4s, c->ir3->const_upload_unit);
	out->push_first_vec4 = allocs.consts[IR3_CONST_ALLOC_PUSH_CONSTS].offset_vec4;

	struct lower_state st = {.layout = layout, .out = out, .ir3 = c->ir3, .push_first_dword = out->push_first_vec4 * 4, .why = why, .why_size = why_size};
	bool progress = nir_shader_instructions_pass(nir, lower_instr, nir_metadata_none, &st);
	if (st.bad)
		return false;
	if (progress)
		nir_opt_dce(nir);
	nir_remove_dead_variables(nir, nir_var_uniform | nir_var_mem_ubo | nir_var_mem_ssbo | nir_var_image, NULL);
	nir_shader_gather_info(nir, nir_shader_get_entrypoint(nir));

	const struct ir3_shader_nir_options nir_options = {0};
	ir3_finalize_nir(c->ir3, &nir_options, nir);
	const struct ir3_shader_options options = {
		.push_consts_type = IR3_PUSH_CONSTS_PER_STAGE,
		.push_consts_base = out->push_lo_dwords,
		.push_consts_dwords = out->push_dwords,
		.const_allocs = allocs,
		.nir_options = nir_options,
	};
	struct ir3_stream_output_info so = {0};
	ralloc_steal(NULL, nir);        /* from here the ir3 shader owns it: ir3_shader_destroy frees it (tu_compile_shaders does the same) */
	out->shader = ir3_shader_from_nir(c->ir3, nir, &options, &so);
	if (out->shader == NULL) {
		snprintf(why, why_size, "ir3_shader_from_nir failed");
		return false;
	}
	out->variant = ir3_shader_create_variant(out->shader, key, false);
	if (out->variant == NULL) {
		snprintf(why, why_size, "ir3 refused stage %d", nir->info.stage);
		return false;
	}
	if (ir3_exceeds_safe_constlen(out->variant)) {
		struct ir3_shader_key safe = *key;
		safe.safe_constlen = true;
		struct ir3_shader_variant *v = ir3_shader_create_variant(out->shader, &safe, false);
		if (v != NULL) {
			ralloc_free(out->variant);
			out->variant = v;
		}
	}
	const struct ir3_shader_variant *v = out->variant;
	struct nmn_stage_info *i = &out->info;
	i->instructions = v->info.instrs_count;
	i->nops = v->info.nops_count;
	i->movs = v->info.mov_count;
	i->covs = v->info.cov_count;
	i->sizedwords = v->info.sizedwords;
	i->half_regs = v->info.max_half_reg + 1;
	i->full_regs = v->info.max_reg + 1;
	i->const_vec4 = v->constlen;
	i->tex_ops = v->info.instrs_per_cat[5];
	i->mem_ops = v->info.instrs_per_cat[6];
	i->sstall = v->info.sstall;
	i->systall = v->info.systall;
	i->loops = v->loops;
	i->instrlen = v->instrlen;
	i->has_kill = v->has_kill;
	i->early_tests = v->fs.early_fragment_tests;
	i->no_early_z = v->writes_pos || v->no_earlyz || v->writes_stencilref || v->writes_smask;  /* tu_shader.cc force_late_z */
	i->writes_z = v->writes_pos;
	i->needs_full_quad = v->need_full_quad;
	i->color_outputs = 0;
	if (nir->info.stage == MESA_SHADER_FRAGMENT) {
		for (unsigned r = 0; r < 8; r++) {
			int idx = ir3_find_output(v, (gl_varying_slot)(FRAG_RESULT_DATA0 + r));
			if (idx >= 0 && VALIDREG(ir3_get_output_regid(&v->outputs[idx])))
				i->color_outputs |= 1u << r;
		}
	}
	return true;
}

void nmn_program_free(struct nmn_program *p)
{
	if (p == NULL)
		return;
	for (unsigned i = 0; i < p->count; i++) {
		if (p->stage[i].variant != NULL)
			ralloc_free(p->stage[i].variant);
		if (p->stage[i].shader != NULL)
			ir3_shader_destroy(p->stage[i].shader);
	}
	free(p);
}

/* ---- the disk cache's form of a program ---- */
#define NMN_PROGRAM_MAGIC 0x314d4e4eu

void *nmn_program_store(const struct nmn_program *p, size_t *size)
{
	struct blob b;
	void *data = NULL;
	blob_init(&b);
	blob_write_uint32(&b, NMN_PROGRAM_MAGIC);
	blob_write_uint32(&b, p->count);
	for (unsigned i = 0; i < p->count; i++) {
		const struct nmn_compiled *s = &p->stage[i];
		blob_write_bytes(&b, &s->info, sizeof(s->info));
		blob_write_uint32(&b, s->push_lo_dwords);
		blob_write_uint32(&b, s->push_dwords);
		blob_write_uint32(&b, s->push_first_vec4);
		ir3_store_variant(&b, s->variant);
	}
	if (b.out_of_memory) {
		blob_finish(&b);
		return NULL;
	}
	blob_finish_get_buffer(&b, &data, size);
	return data;
}

struct nmn_program *nmn_program_load(struct nmn_compiler *c, const void *data, size_t size)
{
	struct blob_reader r;
	blob_reader_init(&r, data, size);
	if (blob_read_uint32(&r) != NMN_PROGRAM_MAGIC)
		return NULL;
	const uint32_t count = blob_read_uint32(&r);
	if (r.overrun || count == 0 || count > 2)
		return NULL;
	struct nmn_program *p = calloc(1, sizeof(*p));
	if (p == NULL)
		return NULL;
	p->count = count;
	for (unsigned i = 0; i < count; i++) {
		struct nmn_compiled *s = &p->stage[i];
		blob_copy_bytes(&r, &s->info, sizeof(s->info));
		s->push_lo_dwords = blob_read_uint32(&r);
		s->push_dwords = blob_read_uint32(&r);
		s->push_first_vec4 = blob_read_uint32(&r);
		if (r.overrun) {
			nmn_program_free(p);
			return NULL;
		}
		s->variant = ir3_retrieve_variant(&r, c->ir3, NULL);
		if (r.overrun || s->variant == NULL) {
			nmn_program_free(p);
			return NULL;
		}
	}
	return p;
}

/* A hash of what the compile path is made from (the build scripts: this file, compile.rs, the translator's and Mesa's versions). A change in the stream code keeps the cache; a change here starts a new one. */
#ifndef NMN_CACHE_ID
#error NMN_CACHE_ID: scripts/laurel/native/cache-id.sh
#endif
const char *nmn_cache_id(void)
{
	return NMN_CACHE_ID;
}

struct nmn_program *nmn_program_render(struct nmn_compiler *c, const struct nmn_layout *layout, const struct nmn_stage_input *vertex, const struct nmn_stage_input *fragment, char *why, size_t why_size)
{
	void *mem_ctx = ralloc_context(NULL);
	struct nmn_program *p = calloc(1, sizeof(*p));
	nir_shader *vs = to_nir(c, mem_ctx, MESA_SHADER_VERTEX, vertex, why, why_size);
	nir_shader *fs = fragment ? to_nir(c, mem_ctx, MESA_SHADER_FRAGMENT, fragment, why, why_size) : NULL;
	if (p == NULL || vs == NULL || (fragment != NULL && fs == NULL))
		goto bad;
	if (fs != NULL)
		link_pair(vs, fs);
	nir_shader_gather_info(vs, nir_shader_get_entrypoint(vs));
	if (fs != NULL)
		nir_shader_gather_info(fs, nir_shader_get_entrypoint(fs));
	struct ir3_shader_key key = {0};
	p->count = 1;
	if (!finish_stage(c, layout, vs, &p->stage[0], &key, why, why_size))
		goto bad;
	if (fs != NULL) {
		p->count = 2;
		if (!finish_stage(c, layout, fs, &p->stage[1], &key, why, why_size))
			goto bad;
	}
	ralloc_free(mem_ctx);
	return p;
bad:
	nmn_program_free(p);
	ralloc_free(mem_ctx);
	return NULL;
}

struct nmn_program *nmn_program_compute(struct nmn_compiler *c, const struct nmn_layout *layout, const struct nmn_stage_input *kernel, uint32_t x, uint32_t y, uint32_t z, char *why, size_t why_size)
{
	void *mem_ctx = ralloc_context(NULL);
	struct nmn_program *p = calloc(1, sizeof(*p));
	nir_shader *cs = to_nir(c, mem_ctx, MESA_SHADER_COMPUTE, kernel, why, why_size);
	if (p == NULL || cs == NULL)
		goto bad;
	if (cs->info.workgroup_size_variable || x != 0) {
		cs->info.workgroup_size[0] = x ? x : 1;
		cs->info.workgroup_size[1] = y ? y : 1;
		cs->info.workgroup_size[2] = z ? z : 1;
	}
	struct ir3_shader_key key = {0};
	p->count = 1;
	if (!finish_stage(c, layout, cs, &p->stage[0], &key, why, why_size))
		goto bad;
	ralloc_free(mem_ctx);
	return p;
bad:
	nmn_program_free(p);
	ralloc_free(mem_ctx);
	return NULL;
}

bool nmn_program_info(const struct nmn_program *p, unsigned stage, struct nmn_stage_info *out)
{
	if (stage >= p->count)
		return false;
	*out = p->stage[stage].info;
	return true;
}

const void *nmn_program_variant(const struct nmn_program *p, unsigned stage)
{
	return stage < p->count ? p->stage[stage].variant : NULL;
}

const void *nmn_program_code(const struct nmn_program *p, unsigned stage, uint32_t *bytes)
{
	if (stage >= p->count)
		return NULL;
	*bytes = p->stage[stage].variant->info.size;
	return p->stage[stage].variant->bin;
}

void nmn_program_local_size(const struct nmn_program *p, uint32_t out[3])
{
	const struct ir3_shader_variant *v = p->stage[0].variant;
	out[0] = v->local_size[0] ? v->local_size[0] : 1;
	out[1] = v->local_size[1] ? v->local_size[1] : 1;
	out[2] = v->local_size[2] ? v->local_size[2] : 1;
}

bool nmn_program_push_range(const struct nmn_program *p, unsigned stage, uint32_t *first_vec4, uint32_t *vec4s, uint32_t *lo_dwords)
{
	if (stage >= p->count)
		return false;
	*first_vec4 = p->stage[stage].push_first_vec4;
	*vec4s = DIV_ROUND_UP(p->stage[stage].push_dwords, 4);
	*lo_dwords = p->stage[stage].push_lo_dwords;
	return true;
}
