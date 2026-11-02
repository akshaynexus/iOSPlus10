/* SPDX-License-Identifier: MIT */
/* See nmn_pm4.h. Register values and their order: Mesa Turnip tu_cmd_buffer.cc, tu_pipeline.cc, tu_shader.cc, tu_clear_blit.cc (Copyright Google, Valve, Red Hat, Igalia and others; MIT). */
#include "nmn_pm4.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "util/format/u_format.h"
#include "util/format_srgb.h"
#include "util/half_float.h"
#include "util/u_math.h"
#include "util/u_dynarray.h"
#include "fd6_format_table.h"
#include "freedreno_dev_info.h"
#include "freedreno_guardband.h"
#include "freedreno_layout.h"
#include "ir3_shader.h"
#include "ir3_compiler.h"
#include "drm-uapi/msm_drm.h"
#include "adreno_common.xml.h"
#include "adreno_pm4.xml.h"
#include "a6xx.xml.h"

struct fd_reg_pair {
   uint32_t reg;
   uint64_t value;
   struct nw_bo *bo;
   bool is_address;
   bool bo_write;
   uint32_t bo_offset;
   uint32_t bo_shift;
   uint32_t bo_low;
};
#define __bo_type struct nw_bo *
#include "a6xx-pack.xml.h"
#include "adreno-pm4-pack.xml.h"

#undef COND
#define COND(b, v) ((b) ? (v) : 0)
#undef CONDREG
#define CONDREG(r, v) COND(VALIDREG(r), v)

static const enum chip CHIP = A6XX;
static inline enum a6xx_tile_mode tile_of(const struct fdl_layout *l, int level) { return (enum a6xx_tile_mode)fdl_tile_mode(l, level); }

struct nmn_gpu {
	struct nw_device *dev;
	struct fd_dev_id id;
	struct fd_dev_info info;
	struct nw_slice border;         /* builtin border colors */
	struct nw_slice pvt;            /* one private memory area for all programs, grown once */
	uint32_t pvt_fiber, pvt_sp;
	uint32_t ccu_color_bypass, ccu_depth_bypass;
};

struct nmn_image {
	struct nmn_gpu *gpu;
	struct fdl_layout layout;
	uint32_t format;
	enum nmn_image_type type;
	uint32_t layers;
	uint64_t iova;
};

struct nmn_baked {
	struct nw_slice code;
	struct nw_slice state;
	uint32_t dwords;
	bool reads_framebuffer;
	const struct ir3_shader_variant *vs, *fs, *cs;
};

/* ---- packets ---- */
static inline void emit_reg(struct nw_cs *cs, uint32_t reg, uint32_t v)
{
	nw_cs_reserve(cs, 2);
	nw_cs_emit(cs, nw_pkt4(reg, 1));
	nw_cs_emit(cs, v);
}
static inline void pkt7(struct nw_cs *cs, uint32_t op, uint32_t n)
{
	nw_cs_reserve(cs, n + 1);
	nw_cs_emit(cs, nw_pkt7(op, n));
}
static inline void pkt4(struct nw_cs *cs, uint32_t reg, uint32_t n)
{
	nw_cs_reserve(cs, n + 1);
	nw_cs_emit(cs, nw_pkt4(reg, n));
}
static void emit_reg_list(struct nw_cs *cs, const struct fd_reg_pair *r, size_t n)
{
	uint32_t dwords = 0;
	for (size_t i = 0; i < n; i++)
		if (r[i].reg > 0)
			dwords += r[i].is_address ? 2 : 1;
	pkt4(cs, r[0].reg, dwords);
	for (size_t i = 0; i < n; i++) {
		if (r[i].reg == 0)
			continue;
		nw_cs_emit(cs, (uint32_t)r[i].value);
		if (r[i].is_address)
			nw_cs_emit(cs, (uint32_t)(r[i].value >> 32));
	}
}
#define REGS(cs, ...) do { const struct fd_reg_pair r__[] = {__VA_ARGS__}; emit_reg_list(cs, r__, ARRAY_SIZE(r__)); } while (0)

static void event(struct nw_cs *cs, enum vgt_event_type e)
{
	pkt7(cs, CP_EVENT_WRITE, 1);
	nw_cs_emit(cs, CP_EVENT_WRITE_0_EVENT(e));
}
static void wfi(struct nw_cs *cs) { pkt7(cs, CP_WAIT_FOR_IDLE, 0); }

/* ---- device ---- */
/* tu_device.cc: the border color table holds builtin colors at fixed slots */
#define NMN_BORDER_STRIDE 128

struct nmn_gpu *nmn_gpu_new(struct nw_device *dev, char *why, size_t why_size)
{
	const struct nw_info *ni = nw_device_info(dev);
	struct nmn_gpu *g = (struct nmn_gpu *)calloc(1, sizeof(*g));
	if (g == NULL) {
		snprintf(why, why_size, "no memory");
		return NULL;
	}
	g->dev = dev;
	g->id.chip_id = ni->chip_id;
	if (fd_dev_info_raw(&g->id) == NULL) {
		snprintf(why, why_size, "Mesa has no device row for chip %#x", ni->chip_id);
		free(g);
		return NULL;
	}
	g->info = fd_dev_info(&g->id);
	if (g->info.chip != 6) {
		snprintf(why, why_size, "this stack writes a6xx command streams; chip %#x is a%ux", ni->chip_id, g->info.chip);
		free(g);
		return NULL;
	}
	/* tu_device.cc: the CCU's place in GMEM, in bypass mode */
	uint32_t color = g->info.num_ccu * g->info.a6xx.sysmem_per_ccu_color_cache_size;
	uint32_t depth = g->info.num_ccu * g->info.a6xx.sysmem_per_ccu_depth_cache_size;
	g->ccu_depth_bypass = 0;
	g->ccu_color_bypass = g->ccu_depth_bypass + depth;
	(void)color;
	if (!nw_slice_new(dev, NMN_BORDER_STRIDE * 16, 128, &g->border)) {
		snprintf(why, why_size, "no GPU memory for the border colors");
		free(g);
		return NULL;
	}
	memset(g->border.map, 0, g->border.size);
	return g;
}

void nmn_gpu_free(struct nmn_gpu *g)
{
	if (g == NULL)
		return;
	nw_slice_free(g->dev, &g->border);
	nw_slice_free(g->dev, &g->pvt);
	free(g);
}

struct nw_device *nmn_gpu_device(struct nmn_gpu *g) { return g->dev; }

uint32_t nmn_format_from_metal(uint64_t f)
{
	switch (f) {
	case 1: return PIPE_FORMAT_A8_UNORM;
	case 10: return PIPE_FORMAT_R8_UNORM;
	case 11: return PIPE_FORMAT_R8_SRGB;
	case 12: return PIPE_FORMAT_R8_SNORM;
	case 13: return PIPE_FORMAT_R8_UINT;
	case 14: return PIPE_FORMAT_R8_SINT;
	case 20: return PIPE_FORMAT_R16_UNORM;
	case 22: return PIPE_FORMAT_R16_SNORM;
	case 23: return PIPE_FORMAT_R16_UINT;
	case 24: return PIPE_FORMAT_R16_SINT;
	case 25: return PIPE_FORMAT_R16_FLOAT;
	case 30: return PIPE_FORMAT_R8G8_UNORM;
	case 31: return PIPE_FORMAT_R8G8_SRGB;
	case 32: return PIPE_FORMAT_R8G8_SNORM;
	case 33: return PIPE_FORMAT_R8G8_UINT;
	case 34: return PIPE_FORMAT_R8G8_SINT;
	case 40: return PIPE_FORMAT_B5G6R5_UNORM;
	case 41: return PIPE_FORMAT_A1B5G5R5_UNORM;
	case 42: return PIPE_FORMAT_B4G4R4A4_UNORM;
	case 43: return PIPE_FORMAT_A1R5G5B5_UNORM;
	case 53: return PIPE_FORMAT_R32_UINT;
	case 54: return PIPE_FORMAT_R32_SINT;
	case 55: return PIPE_FORMAT_R32_FLOAT;
	case 60: return PIPE_FORMAT_R16G16_UNORM;
	case 62: return PIPE_FORMAT_R16G16_SNORM;
	case 63: return PIPE_FORMAT_R16G16_UINT;
	case 64: return PIPE_FORMAT_R16G16_SINT;
	case 65: return PIPE_FORMAT_R16G16_FLOAT;
	case 70: return PIPE_FORMAT_R8G8B8A8_UNORM;
	case 71: return PIPE_FORMAT_R8G8B8A8_SRGB;
	case 72: return PIPE_FORMAT_R8G8B8A8_SNORM;
	case 73: return PIPE_FORMAT_R8G8B8A8_UINT;
	case 74: return PIPE_FORMAT_R8G8B8A8_SINT;
	case 80: return PIPE_FORMAT_B8G8R8A8_UNORM;
	case 81: return PIPE_FORMAT_B8G8R8A8_SRGB;
	case 90: return PIPE_FORMAT_R10G10B10A2_UNORM;
	case 91: return PIPE_FORMAT_R10G10B10A2_UINT;
	case 92: return PIPE_FORMAT_R11G11B10_FLOAT;
	case 93: return PIPE_FORMAT_R9G9B9E5_FLOAT;
	case 94: return PIPE_FORMAT_B10G10R10A2_UNORM;
	case 103: return PIPE_FORMAT_R32G32_UINT;
	case 104: return PIPE_FORMAT_R32G32_SINT;
	case 105: return PIPE_FORMAT_R32G32_FLOAT;
	case 110: return PIPE_FORMAT_R16G16B16A16_UNORM;
	case 112: return PIPE_FORMAT_R16G16B16A16_SNORM;
	case 113: return PIPE_FORMAT_R16G16B16A16_UINT;
	case 114: return PIPE_FORMAT_R16G16B16A16_SINT;
	case 115: return PIPE_FORMAT_R16G16B16A16_FLOAT;
	case 123: return PIPE_FORMAT_R32G32B32A32_UINT;
	case 124: return PIPE_FORMAT_R32G32B32A32_SINT;
	case 125: return PIPE_FORMAT_R32G32B32A32_FLOAT;
	case 250: return PIPE_FORMAT_Z16_UNORM;
	case 252: return PIPE_FORMAT_Z32_FLOAT;
	case 253: return PIPE_FORMAT_S8_UINT;
	case 255: return PIPE_FORMAT_Z24_UNORM_S8_UINT;
	case 260: return PIPE_FORMAT_Z32_FLOAT_S8X24_UINT;
	default: return PIPE_FORMAT_NONE;
	}
}
uint32_t nmn_format_blocksize(uint32_t f) { return util_format_get_blocksize((enum pipe_format)f); }
bool nmn_format_is_depth_or_stencil(uint32_t f) { return util_format_is_depth_or_stencil((enum pipe_format)f); }

/* ---- images ---- */
struct nmn_image *nmn_image_new(struct nmn_gpu *g, uint32_t format, enum nmn_image_type type, uint32_t width, uint32_t height, uint32_t depth, uint32_t levels, uint32_t layers, uint32_t samples, bool tiled, uint32_t stride)
{
	struct nmn_image *im = (struct nmn_image *)calloc(1, sizeof(*im));
	if (im == NULL)
		return NULL;
	im->gpu = g;
	im->format = format;
	im->type = type;
	im->layers = layers;
	struct fdl_explicit_layout plane = {};
	struct fdl_explicit_layout *pl = NULL;
	im->layout.tile_mode = tiled ? TILE6_3 : TILE6_LINEAR;
	if (stride != 0) {
		plane.offset = 0;
		plane.pitch = stride;
		pl = &plane;
	}
	im->layout.ubwc = false;        /* the first version has no UBWC: fewer flushes to get right, and an erratum to read first (doc section 5) */
	if (!fdl6_layout(&im->layout, &g->info, (enum pipe_format)format, samples, width, height, depth, levels, layers, type == NMN_IMAGE_3D, false, false, pl)) {
		free(im);
		return NULL;
	}
	return im;
}
void nmn_image_free(struct nmn_image *im) { free(im); }
uint64_t nmn_image_size(const struct nmn_image *im) { return im->layout.size; }
uint32_t nmn_image_pitch(const struct nmn_image *im, uint32_t level) { return fdl_pitch(&im->layout, level); }
uint64_t nmn_image_layer_offset(const struct nmn_image *im, uint32_t level, uint32_t layer) { return fdl_surface_offset(&im->layout, level, layer); }
uint32_t nmn_image_format(const struct nmn_image *im) { return im->format; }
void nmn_image_bind(struct nmn_image *im, uint64_t iova) { im->iova = iova; }
uint64_t nmn_image_iova(const struct nmn_image *im) { return im->iova; }

/* ---- descriptors ---- */
void nmn_descriptor_image(const struct nmn_image *im, uint32_t format, enum nmn_image_type view_type, uint32_t base_level, uint32_t levels, uint32_t base_layer, uint32_t layers, const uint8_t swizzle[4], bool storage, uint32_t out[16])
{
	const struct fdl_layout *l = &im->layout;
	struct fdl_view_args args = {};
	args.chip = 6;
	args.iova = im->iova;
	args.base_miplevel = base_level;
	args.level_count = levels;
	args.base_array_layer = base_layer;
	args.layer_count = layers;
	args.format = (enum pipe_format)format;
	args.type = view_type == NMN_IMAGE_3D ? FDL_VIEW_TYPE_3D : view_type == NMN_IMAGE_CUBE ? FDL_VIEW_TYPE_CUBE : view_type == NMN_IMAGE_1D ? FDL_VIEW_TYPE_1D : FDL_VIEW_TYPE_2D;
	memcpy(args.swiz, swizzle, 4);
	struct fdl6_view v;
	fdl6_view_init(&v, &l, &args, im->gpu->info.a6xx.has_z24uint_s8uint);
	memcpy(out, storage ? v.storage_descriptor : v.descriptor, 64);
}

void nmn_descriptor_buffer_texels(uint32_t format, uint64_t iova, uint32_t bytes, uint32_t out[16])
{
	static const uint8_t identity[4] = {PIPE_SWIZZLE_X, PIPE_SWIZZLE_Y, PIPE_SWIZZLE_Z, PIPE_SWIZZLE_W};
	fdl6_buffer_view_init(out, (enum pipe_format)format, identity, iova, bytes);
}

void nmn_descriptor_ubo(uint64_t iova, uint64_t bytes, uint32_t out[16])
{
	memset(out, 0, 64);
	uint32_t range = iova ? (uint32_t)DIV_ROUND_UP(bytes, 16) : 0;
	out[0] = A6XX_UBO_0_BASE_LO((uint32_t)iova);
	out[1] = A6XX_UBO_1_BASE_HI((uint32_t)(iova >> 32)) | A6XX_UBO_1_SIZE(range);
}

/* tu_descriptor_set.cc write_buffer_descriptor_addr: the FD610 has no 16-bit storage, so one 32-bit descriptor */
void nmn_descriptor_ssbo(uint64_t iova, uint64_t bytes, uint32_t out[16])
{
	memset(out, 0, 64);
	if (iova == 0)
		return;
	uint64_t base = iova & ~0x3full;
	uint32_t offset = (uint32_t)(iova & 0x3f);
	uint32_t range = (uint32_t)bytes;
	out[0] = A6XX_TEX_CONST_0_TILE_MODE(TILE6_LINEAR) | A6XX_TEX_CONST_0_FMT(FMT6_32_UINT);
	out[1] = DIV_ROUND_UP(range, 4);
	out[2] = A6XX_TEX_CONST_2_STRUCTSIZETEXELS(1) | A6XX_TEX_CONST_2_STARTOFFSETTEXELS(offset / 4) | A6XX_TEX_CONST_2_TYPE(A6XX_TEX_BUFFER);
	out[4] = A6XX_TEX_CONST_4_BASE_LO((uint32_t)base);
	out[5] = A6XX_TEX_CONST_5_BASE_HI((uint32_t)(base >> 32));
}

static enum a6xx_tex_filter tex_filter(uint32_t metal, bool aniso)
{
	return metal == 0 ? A6XX_TEX_NEAREST : aniso ? A6XX_TEX_ANISO : A6XX_TEX_LINEAR;
}
static enum a6xx_tex_clamp tex_clamp(uint32_t a)
{
	/* MTLSamplerAddressMode: 0 clamp to edge, 1 mirror clamp to edge, 2 repeat, 3 mirror repeat, 4 clamp to zero, 5 clamp to border */
	switch (a) {
	case 1: return A6XX_TEX_MIRROR_CLAMP;
	case 2: return A6XX_TEX_REPEAT;
	case 3: return A6XX_TEX_MIRROR_REPEAT;
	case 4: case 5: return A6XX_TEX_CLAMP_TO_BORDER;
	default: return A6XX_TEX_CLAMP_TO_EDGE;
	}
}

void nmn_descriptor_sampler(const struct nmn_sampler_state *s, uint64_t border_iova, uint32_t out[16])
{
	memset(out, 0, 64);
	unsigned aniso = s->max_anisotropy > 1 ? util_last_bit(MIN2(s->max_anisotropy >> 1, 8)) : 0;
	bool miplinear = s->mip_filter == 2; /* MTLSamplerMipFilter: 0 not mipmapped, 1 nearest, 2 linear */
	float lod_max = s->mip_filter == 0 ? s->lod_min : s->lod_max;
	out[0] = COND(miplinear, A6XX_TEX_SAMP_0_MIPFILTER_LINEAR_NEAR) |
		A6XX_TEX_SAMP_0_XY_MAG(tex_filter(s->mag_filter, aniso != 0)) |
		A6XX_TEX_SAMP_0_XY_MIN(tex_filter(s->min_filter, aniso != 0)) |
		A6XX_TEX_SAMP_0_ANISO((enum a6xx_tex_aniso)aniso) |
		A6XX_TEX_SAMP_0_WRAP_S(tex_clamp(s->s_address)) |
		A6XX_TEX_SAMP_0_WRAP_T(tex_clamp(s->t_address)) |
		A6XX_TEX_SAMP_0_WRAP_R(tex_clamp(s->r_address)) |
		A6XX_TEX_SAMP_0_LOD_BIAS(0.0f);
	/* MTLCompareFunction == Metal's order == a3xx compare func */
	out[1] = A6XX_TEX_SAMP_1_MIN_LOD(s->lod_min) | A6XX_TEX_SAMP_1_MAX_LOD(MIN2(lod_max, 4095.0f / 256.0f)) | COND(s->compare != 0, A6XX_TEX_SAMP_1_COMPARE_FUNC((enum adreno_compare_func)s->compare));
	out[2] = A6XX_TEX_SAMP_2_BCOLOR(0);     /* builtin slot 0: transparent black */
	(void)border_iova;
	out[3] = 0;
	if (!s->normalized)
		out[1] |= A6XX_TEX_SAMP_1_UNNORM_COORDS;
}

/* ---- per submission ---- */
static void emit_ccu_bypass(struct nw_cs *cs, const struct nmn_gpu *g)
{
	REGS(cs, RB_CCU_CNTL(CHIP,
		.gmem_fast_clear_disable = !g->info.a6xx.has_gmem_fast_clear,
		.concurrent_resolve = g->info.a6xx.concurrent_resolve,
		.depth_offset_hi = 0,
		.color_offset_hi = g->ccu_color_bypass >> 21,
		.depth_cache_size = CCU_CACHE_SIZE_FULL,
		.depth_offset = 0,
		.color_cache_size = CCU_CACHE_SIZE_FULL,
		.color_offset = g->ccu_color_bypass & 0x1fffff));
}

void nmn_cmd_init(struct nw_cs *cs, struct nmn_gpu *g)
{
	const struct fd_dev_info *i = &g->info;
	event(cs, CACHE_INVALIDATE);
	REGS(cs, HLSQ_INVALIDATE_CMD(CHIP, .vs_state = true, .hs_state = true, .ds_state = true, .gs_state = true, .fs_state = true, .cs_state = true, .cs_ibo = true, .gfx_ibo = true, .cs_shared_const = true, .gfx_shared_const = true, .cs_bindless = 0x1f, .gfx_bindless = 0x1f));
	wfi(cs);
	for (size_t n = 0; n < ARRAY_SIZE(i->a6xx.magic_raw) && i->a6xx.magic_raw[n].reg; n++)
		emit_reg(cs, i->a6xx.magic_raw[n].reg, i->a6xx.magic_raw[n].value);
	emit_reg(cs, REG_A6XX_RB_DBG_ECO_CNTL, i->a6xx.magic.RB_DBG_ECO_CNTL);
	emit_reg(cs, REG_A6XX_SP_FLOAT_CNTL, 0);
	emit_reg(cs, REG_A6XX_SP_DBG_ECO_CNTL, i->a6xx.magic.SP_DBG_ECO_CNTL);
	emit_reg(cs, REG_A6XX_SP_PERFCTR_ENABLE, 0x3f);
	emit_reg(cs, REG_A6XX_TPL1_UNKNOWN_B605, 0x44);
	emit_reg(cs, REG_A6XX_TPL1_DBG_ECO_CNTL, i->a6xx.magic.TPL1_DBG_ECO_CNTL);
	emit_reg(cs, REG_A6XX_HLSQ_UNKNOWN_BE00, 0x80);
	emit_reg(cs, REG_A6XX_HLSQ_UNKNOWN_BE01, 0);
	emit_reg(cs, REG_A6XX_VPC_DBG_ECO_CNTL, i->a6xx.magic.VPC_DBG_ECO_CNTL);
	emit_reg(cs, REG_A6XX_GRAS_DBG_ECO_CNTL, i->a6xx.magic.GRAS_DBG_ECO_CNTL);
	emit_reg(cs, REG_A6XX_HLSQ_DBG_ECO_CNTL, i->a6xx.magic.HLSQ_DBG_ECO_CNTL);
	emit_reg(cs, REG_A6XX_SP_CHICKEN_BITS, i->a6xx.magic.SP_CHICKEN_BITS);
	emit_reg(cs, REG_A6XX_SP_IBO_COUNT, 0);
	emit_reg(cs, REG_A6XX_SP_UNKNOWN_B182, 0);
	REGS(cs, A6XX_HLSQ_SHARED_CONSTS(.enable = false));
	emit_reg(cs, REG_A6XX_UCHE_UNKNOWN_0E12, i->a6xx.magic.UCHE_UNKNOWN_0E12);
	emit_reg(cs, REG_A6XX_UCHE_CLIENT_PF, i->a6xx.magic.UCHE_CLIENT_PF);
	emit_reg(cs, REG_A6XX_RB_UNKNOWN_8E01, i->a6xx.magic.RB_UNKNOWN_8E01);
	emit_reg(cs, REG_A6XX_SP_UNKNOWN_A9A8, 0);
	REGS(cs, A6XX_SP_MODE_CONTROL(.constant_demotion_enable = true, .isammode = ISAMMODE_GL, .shared_consts_enable = false));
	emit_reg(cs, REG_A6XX_VFD_ADD_OFFSET, A6XX_VFD_ADD_OFFSET_VERTEX);
	emit_reg(cs, REG_A6XX_RB_UNKNOWN_8811, 0x00000010);
	emit_reg(cs, REG_A6XX_PC_MODE_CNTL, i->a6xx.magic.PC_MODE_CNTL);
	emit_reg(cs, REG_A6XX_GRAS_UNKNOWN_8110, 0);
	emit_reg(cs, REG_A6XX_RB_UNKNOWN_8818, 0);
	emit_reg(cs, REG_A6XX_RB_UNKNOWN_8819, 0);
	emit_reg(cs, REG_A6XX_RB_UNKNOWN_881A, 0);
	emit_reg(cs, REG_A6XX_RB_UNKNOWN_881B, 0);
	emit_reg(cs, REG_A6XX_RB_UNKNOWN_881C, 0);
	emit_reg(cs, REG_A6XX_RB_UNKNOWN_881D, 0);
	emit_reg(cs, REG_A6XX_RB_UNKNOWN_881E, 0);
	emit_reg(cs, REG_A6XX_RB_UNKNOWN_88F0, 0);
	REGS(cs, A6XX_VPC_POINT_COORD_INVERT(false));
	emit_reg(cs, REG_A6XX_VPC_UNKNOWN_9300, 0);
	REGS(cs, A6XX_VPC_SO_DISABLE(true));
	emit_reg(cs, REG_A6XX_SP_UNKNOWN_B183, 0);
	emit_reg(cs, REG_A6XX_GRAS_UNKNOWN_80AF, 0);
	emit_reg(cs, REG_A6XX_GRAS_SU_CONSERVATIVE_RAS_CNTL, 0);
	REGS(cs, A6XX_PC_DGEN_SU_CONSERVATIVE_RAS_CNTL());
	emit_reg(cs, REG_A6XX_VPC_UNKNOWN_9210, 0);
	emit_reg(cs, REG_A6XX_VPC_UNKNOWN_9211, 0);
	emit_reg(cs, REG_A6XX_VPC_UNKNOWN_9602, 0);
	emit_reg(cs, REG_A6XX_PC_UNKNOWN_9E72, 0);
	emit_reg(cs, REG_A6XX_SP_TP_MODE_CNTL, 0x000000a0 | A6XX_SP_TP_MODE_CNTL_ISAMMODE(ISAMMODE_GL));
	REGS(cs, HLSQ_CONTROL_5_REG(CHIP, .dword = 0xfc));
	emit_reg(cs, REG_A6XX_VFD_MODE_CNTL, 0);
	emit_reg(cs, REG_A6XX_PC_MODE_CNTL, i->a6xx.magic.PC_MODE_CNTL);
	REGS(cs, A6XX_RB_ALPHA_CONTROL());
	REGS(cs, A6XX_SP_TP_BORDER_COLOR_BASE_ADDR(.qword = g->border.iova));
	REGS(cs, A6XX_SP_PS_TP_BORDER_COLOR_BASE_ADDR(.qword = g->border.iova));
	pkt4(cs, REG_A6XX_HLSQ_VS_CNTL, 1);
	nw_cs_emit(cs, A6XX_HLSQ_VS_CNTL_CONSTLEN(8) | A6XX_HLSQ_VS_CNTL_ENABLED);
	emit_ccu_bypass(cs, g);
	pkt7(cs, CP_SET_DRAW_STATE, 3);
	nw_cs_emit(cs, CP_SET_DRAW_STATE__0_COUNT(0) | CP_SET_DRAW_STATE__0_DISABLE_ALL_GROUPS | CP_SET_DRAW_STATE__0_GROUP_ID(0));
	nw_cs_emit(cs, 0);
	nw_cs_emit(cs, 0);
}

/* ---- render pass, sysmem only ---- */
static void r2d_common(struct nw_cs *cs, enum pipe_format dst, enum a6xx_format fmt, enum a6xx_2d_ifmt ifmt, bool clear)
{
	pkt4(cs, REG_A6XX_RB_2D_UNKNOWN_8C01, 1);
	nw_cs_emit(cs, 0);
	uint32_t blit_cntl = A6XX_RB_2D_BLIT_CNTL(.rotate = ROTATE_0, .solid_color = clear, .color_format = fmt, .scissor = false, .d24s8 = false, .mask = 0xf, .ifmt = util_format_is_srgb(dst) ? R2D_UNORM8_SRGB : ifmt).value;
	pkt4(cs, REG_A6XX_RB_2D_BLIT_CNTL, 1);
	nw_cs_emit(cs, blit_cntl);
	pkt4(cs, REG_A6XX_GRAS_2D_BLIT_CNTL, 1);
	nw_cs_emit(cs, blit_cntl);
	REGS(cs, SP_2D_DST_FORMAT(CHIP, .sint = util_format_is_pure_sint(dst), .uint = util_format_is_pure_uint(dst), .color_format = fmt, .srgb = util_format_is_srgb(dst), .mask = 0xf));
}

static enum a6xx_2d_ifmt format_ifmt(enum pipe_format f)
{
	if (util_format_is_depth_or_stencil(f)) {
		if (f == PIPE_FORMAT_Z32_FLOAT || f == PIPE_FORMAT_Z32_FLOAT_S8X24_UINT)
			return R2D_FLOAT32;
		if (f == PIPE_FORMAT_S8_UINT)
			return R2D_INT8;
		return R2D_UNORM8;
	}
	const struct util_format_description *d = util_format_description(f);
	int c = util_format_get_first_non_void_channel(f);
	if (c < 0)
		return R2D_UNORM8;
	const struct util_format_channel_description *ch = &d->channel[c];
	if (f == PIPE_FORMAT_R10G10B10A2_UNORM || f == PIPE_FORMAT_B10G10R10A2_UNORM)
		return R2D_FLOAT16;
	if (f == PIPE_FORMAT_R11G11B10_FLOAT)
		return R2D_FLOAT16;
	if (ch->pure_integer)
		return ch->size == 8 ? R2D_INT8 : ch->size == 16 ? R2D_INT16 : R2D_INT32;
	if (ch->type == UTIL_FORMAT_TYPE_FLOAT)
		return ch->size == 32 ? R2D_FLOAT32 : R2D_FLOAT16;
	if (ch->size > 8)
		return R2D_FLOAT16;
	return R2D_UNORM8;
}

static void clear_values(enum pipe_format f, enum a6xx_2d_ifmt ifmt, const double *c, uint32_t out[4])
{
	const struct util_format_description *d = util_format_description(f);
	memset(out, 0, 16);
	for (unsigned i = 0; i < 4; i++) {
		if (d->swizzle[i] > PIPE_SWIZZLE_W)
			continue;
		float v = (float)c[i];
		if (ifmt == R2D_UNORM8) {
			if (d->colorspace == UTIL_FORMAT_COLORSPACE_SRGB && i < 3)
				v = util_format_linear_to_srgb_float(v);
			out[i] = (uint32_t)(CLAMP(v, 0.0f, 1.0f) * 255.0f + 0.5f);
		} else if (ifmt == R2D_FLOAT16) {
			out[i] = _mesa_float_to_half(v);
		} else if (ifmt == R2D_FLOAT32) {
			out[i] = fui(v);
		} else {
			out[i] = (uint32_t)(int64_t)c[i];
		}
	}
}

static void r2d_dst_image(struct nw_cs *cs, const struct nmn_image *im, uint32_t level, uint32_t layer, enum pipe_format f, enum a6xx_format fmt)
{
	REGS(cs, A6XX_RB_2D_DST_INFO(.color_format = fmt, .tile_mode = tile_of(&im->layout, level), .color_swap = fd6_color_swap(f, tile_of(&im->layout, level), false), .srgb = util_format_is_srgb(f), .samples = (enum a3xx_msaa_samples)util_logbase2(im->layout.nr_samples)),
	     A6XX_RB_2D_DST(.qword = im->iova + fdl_surface_offset(&im->layout, level, layer)),
	     A6XX_RB_2D_DST_PITCH(fdl_pitch(&im->layout, level)));
	pkt4(cs, REG_A6XX_RB_2D_DST_FLAGS, 3);
	nw_cs_emit(cs, 0);
	nw_cs_emit(cs, 0);
	nw_cs_emit(cs, 0);
}

static void flush_color(struct nw_cs *cs)
{
	event(cs, PC_CCU_FLUSH_COLOR_TS);
	event(cs, PC_CCU_INVALIDATE_COLOR);
	wfi(cs);
}

/* tu_clear_sysmem_attachment over r2d */
static void clear_image(struct nw_cs *cs, const struct nmn_image *im, enum pipe_format f, uint32_t level, uint32_t layer, uint32_t w, uint32_t h, const uint32_t solid[4], enum a6xx_2d_ifmt ifmt)
{
	enum a6xx_tile_mode tile = tile_of(&im->layout, level);
	enum a6xx_format fmt = fd6_color_format(f, tile);
	r2d_common(cs, f, fmt, ifmt, true);
	REGS(cs, A6XX_GRAS_2D_DST_TL(.x = 0, .y = 0), A6XX_GRAS_2D_DST_BR(.x = w - 1, .y = h - 1));
	REGS(cs, A6XX_GRAS_2D_SRC_TL_X(0), A6XX_GRAS_2D_SRC_BR_X(w - 1), A6XX_GRAS_2D_SRC_TL_Y(0), A6XX_GRAS_2D_SRC_BR_Y(h - 1));
	pkt4(cs, REG_A6XX_RB_2D_SRC_SOLID_C0, 4);
	for (int i = 0; i < 4; i++)
		nw_cs_emit(cs, solid[i]);
	r2d_dst_image(cs, im, level, layer, f, fmt);
	pkt7(cs, CP_BLIT, 1);
	nw_cs_emit(cs, CP_BLIT_0_OP(BLIT_OP_SCALE));
}

void nmn_cmd_pass_begin(struct nw_cs *cs, struct nmn_gpu *g, const struct nmn_pass *p)
{
	const uint32_t w = p->width, h = p->height;
	REGS(cs, A6XX_GRAS_LRZ_CNTL(.dword = 0));
	REGS(cs, A6XX_GRAS_LRZ_BUFFER_BASE(0), A6XX_GRAS_LRZ_BUFFER_PITCH(.dword = 0), A6XX_GRAS_LRZ_FAST_CLEAR_BUFFER_BASE(0));
	REGS(cs, A6XX_GRAS_SC_WINDOW_SCISSOR_TL(.x = 0, .y = 0), A6XX_GRAS_SC_WINDOW_SCISSOR_BR(.x = w - 1, .y = h - 1));
	REGS(cs, A6XX_GRAS_2D_RESOLVE_CNTL_1(.x = 0, .y = 0), A6XX_GRAS_2D_RESOLVE_CNTL_2(.x = w - 1, .y = h - 1));
	REGS(cs, A6XX_RB_WINDOW_OFFSET(.x = 0, .y = 0));
	REGS(cs, A6XX_RB_WINDOW_OFFSET2(.x = 0, .y = 0));
	REGS(cs, SP_WINDOW_OFFSET(CHIP, .x = 0, .y = 0));
	REGS(cs, A6XX_SP_TP_WINDOW_OFFSET(.x = 0, .y = 0));
	REGS(cs, A7XX_SP_PS_2D_WINDOW_OFFSET(.x = 0, .y = 0));
	REGS(cs, A6XX_GRAS_BIN_CONTROL(.binw = 0, .binh = 0, .render_mode = RENDERING_PASS, .force_lrz_write_dis = !g->info.a6xx.has_lrz_feedback, .buffers_location = BUFFERS_IN_SYSMEM, .lrz_feedback_zmode_mask = LRZ_FEEDBACK_NONE));
	REGS(cs, RB_BIN_CONTROL(CHIP, .binw = 0, .binh = 0, .render_mode = RENDERING_PASS, .force_lrz_write_dis = !g->info.a6xx.has_lrz_feedback, .buffers_location = BUFFERS_IN_SYSMEM, .lrz_feedback_zmode_mask = LRZ_FEEDBACK_NONE));
	REGS(cs, A6XX_RB_BIN_CONTROL2(.binw = 0, .binh = 0));
	pkt7(cs, CP_SET_MARKER, 1);
	nw_cs_emit(cs, A6XX_CP_SET_MARKER_0_MODE(RM6_DIRECT_RENDER));
	pkt7(cs, CP_SKIP_IB2_ENABLE_GLOBAL, 1);
	nw_cs_emit(cs, 0);
	pkt7(cs, CP_SET_VISIBILITY_OVERRIDE, 1);
	nw_cs_emit(cs, 1);
	pkt7(cs, CP_SET_MODE, 1);
	nw_cs_emit(cs, 0);

	/* clears */
	bool any_clear = false;
	for (uint32_t i = 0; i < p->color_count; i++) {
		const struct nmn_color_target *c = &p->colors[i];
		if (c->image == NULL || !c->clear)
			continue;
		enum pipe_format f = (enum pipe_format)c->pipe_format;
		enum a6xx_2d_ifmt ifmt = format_ifmt(f);
		uint32_t solid[4];
		clear_values(f, ifmt, c->clear_value, solid);
		clear_image(cs, c->image, f, c->level, c->layer, w, h, solid, ifmt);
		any_clear = true;
	}
	if (p->depth != NULL && (p->clear_depth || p->clear_stencil)) {
		enum pipe_format f = (enum pipe_format)p->depth->format;
		uint32_t solid[4] = {fui((float)p->clear_z), p->clear_s, 0, 0};
		if (p->clear_depth)
			clear_image(cs, p->depth, PIPE_FORMAT_Z32_FLOAT, 0, 0, w, h, solid, R2D_FLOAT32);
		(void)f;
		any_clear = true;
	}
	if (any_clear)
		flush_color(cs);

	/* depth + stencil */
	if (p->depth == NULL) {
		REGS(cs, RB_DEPTH_BUFFER_INFO(CHIP, .depth_format = DEPTH6_NONE), A6XX_RB_DEPTH_BUFFER_PITCH(0), A6XX_RB_DEPTH_BUFFER_ARRAY_PITCH(0), A6XX_RB_DEPTH_BUFFER_BASE(0), A6XX_RB_DEPTH_BUFFER_BASE_GMEM(0));
		REGS(cs, A6XX_GRAS_SU_DEPTH_BUFFER_INFO(.depth_format = DEPTH6_NONE));
		REGS(cs, RB_STENCIL_INFO(CHIP, 0));
	} else {
		const struct nmn_image *d = p->depth;
		enum a6xx_depth_format fmt = d->format == PIPE_FORMAT_Z16_UNORM ? DEPTH6_16 : d->format == PIPE_FORMAT_Z24_UNORM_S8_UINT ? DEPTH6_24_8 : DEPTH6_32;
		pkt4(cs, REG_A6XX_RB_DEPTH_BUFFER_INFO, 6);
		nw_cs_emit(cs, RB_DEPTH_BUFFER_INFO(CHIP, .depth_format = fmt, .tilemode = TILE6_3).value);
		nw_cs_emit(cs, A6XX_RB_DEPTH_BUFFER_PITCH(fdl_pitch(&d->layout, 0)).value);
		nw_cs_emit(cs, A6XX_RB_DEPTH_BUFFER_ARRAY_PITCH(fdl_layer_stride(&d->layout, 0)).value);
		nw_cs_emit_qw(cs, d->iova);
		nw_cs_emit(cs, 0);
		REGS(cs, A6XX_GRAS_SU_DEPTH_BUFFER_INFO(.depth_format = fmt));
		REGS(cs, RB_STENCIL_INFO(CHIP, 0));
	}

	/* colors */
	enum a6xx_format mrt0 = FMT6_NONE;
	for (uint32_t i = 0; i < p->color_count; i++) {
		const struct nmn_color_target *c = &p->colors[i];
		if (c->image == NULL) {
			REGS(cs, RB_MRT_BUF_INFO(CHIP, i), A6XX_RB_MRT_PITCH(i), A6XX_RB_MRT_ARRAY_PITCH(i), A6XX_RB_MRT_BASE(i), A6XX_RB_MRT_BASE_GMEM(i));
			REGS(cs, A6XX_SP_FS_MRT_REG(i, .dword = 0));
			continue;
		}
		const struct fdl_layout *l = &c->image->layout;
		enum pipe_format f = (enum pipe_format)c->pipe_format;
		enum a6xx_tile_mode tile = tile_of(l, c->level);
		enum a6xx_format fmt = fd6_color_format(f, tile);
		enum a3xx_color_swap swap = fd6_color_swap(f, tile, false);
		REGS(cs, RB_MRT_BUF_INFO(CHIP, i, .color_tile_mode = tile, .color_format = fmt, .color_swap = swap),
		     A6XX_RB_MRT_PITCH(i, fdl_pitch(l, c->level)),
		     A6XX_RB_MRT_ARRAY_PITCH(i, fdl_layer_stride(l, c->level)),
		     A6XX_RB_MRT_BASE(i, .qword = c->image->iova + fdl_surface_offset(l, c->level, c->layer)),
		     A6XX_RB_MRT_BASE_GMEM(i, 0));
		REGS(cs, A6XX_SP_FS_MRT_REG(i, .color_format = fmt, .color_sint = util_format_is_pure_sint(f), .color_uint = util_format_is_pure_uint(f))); 
		pkt4(cs, REG_A6XX_RB_MRT_FLAG_BUFFER_ADDR(i), 3);
		nw_cs_emit(cs, 0);
		nw_cs_emit(cs, 0);
		nw_cs_emit(cs, 0);
		if (i == 0)
			mrt0 = fmt;
	}
	REGS(cs, A6XX_GRAS_LRZ_MRT_BUF_INFO_0(.color_format = mrt0));
	REGS(cs, A6XX_RB_DITHER_CNTL(.dword = 0));
	uint32_t srgb = 0;
	for (uint32_t i = 0; i < p->color_count; i++)
		if (p->colors[i].image && util_format_is_srgb((enum pipe_format)p->colors[i].pipe_format))
			srgb |= 1u << i;
	REGS(cs, A6XX_RB_SRGB_CNTL(.dword = srgb));
	REGS(cs, A6XX_SP_SRGB_CNTL(.dword = srgb));
	REGS(cs, A6XX_GRAS_MAX_LAYER_INDEX(0));
	/* tu6_emit_render_cntl: no flag buffers. FD610 has CP_REG_WRITE? then tracked */
	if (g->info.a6xx.has_cp_reg_write) {
		pkt7(cs, CP_REG_WRITE, 3);
		nw_cs_emit(cs, CP_REG_WRITE_0_TRACKER(TRACK_RENDER_CNTL));
		nw_cs_emit(cs, REG_A6XX_RB_RENDER_CNTL);
		nw_cs_emit(cs, A6XX_RB_RENDER_CNTL_CCUSINGLECACHELINESIZE(2));
	} else {
		emit_reg(cs, REG_A6XX_RB_RENDER_CNTL, A6XX_RB_RENDER_CNTL_CCUSINGLECACHELINESIZE(2));
	}
	/* state between draws that nothing else sets */
	emit_reg(cs, REG_A6XX_PC_RESTART_INDEX, 0xffffffff);
	event(cs, CACHE_INVALIDATE);
	wfi(cs);
	REGS(cs, A6XX_PC_PRIMITIVE_CNTL_0());
	REGS(cs, A6XX_PC_TESS_CNTL());
	enum a3xx_msaa_samples s = (enum a3xx_msaa_samples)util_logbase2(MAX2(p->samples, 1));
	bool off = p->samples <= 1;
	REGS(cs, A6XX_SP_TP_RAS_MSAA_CNTL(s), A6XX_SP_TP_DEST_MSAA_CNTL(.samples = s, .msaa_disable = off));
	REGS(cs, A6XX_GRAS_RAS_MSAA_CNTL(s), A6XX_GRAS_DEST_MSAA_CNTL(.samples = s, .msaa_disable = off));
	REGS(cs, A6XX_RB_RAS_MSAA_CNTL(s), A6XX_RB_DEST_MSAA_CNTL(.samples = s, .msaa_disable = off));
	REGS(cs, A6XX_GRAS_SAMPLE_CONFIG(), A6XX_GRAS_SAMPLE_LOCATION_0(0), A6XX_GRAS_SAMPLE_LOCATION_1(0));
	REGS(cs, A6XX_RB_SAMPLE_CONFIG(), A6XX_RB_SAMPLE_LOCATION_0(0), A6XX_RB_SAMPLE_LOCATION_1(0));
	REGS(cs, A6XX_SP_TP_SAMPLE_CONFIG(), A6XX_SP_TP_SAMPLE_LOCATION_0(0), A6XX_SP_TP_SAMPLE_LOCATION_1(0));
	REGS(cs, A6XX_RB_DEPTH_PLANE_CNTL(.z_mode = A6XX_LATE_Z));
	REGS(cs, A6XX_GRAS_SU_DEPTH_PLANE_CNTL(.z_mode = A6XX_LATE_Z));
}

/* The end of a pass: what the CCU holds goes to memory, so the next pass or the display can read it. */
void nmn_cmd_pass_end(struct nw_cs *cs, const struct nmn_pass *p)
{
	pkt7(cs, CP_SKIP_IB2_ENABLE_GLOBAL, 1);
	nw_cs_emit(cs, 0);
	event(cs, PC_CCU_FLUSH_COLOR_TS);
	if (p->depth != NULL)
		event(cs, PC_CCU_FLUSH_DEPTH_TS);
}

void nmn_cmd_barrier(struct nw_cs *cs)
{
	event(cs, PC_CCU_FLUSH_COLOR_TS);
	event(cs, PC_CCU_FLUSH_DEPTH_TS);
	event(cs, PC_CCU_INVALIDATE_COLOR);
	event(cs, PC_CCU_INVALIDATE_DEPTH);
	event(cs, CACHE_FLUSH_TS);
	event(cs, CACHE_INVALIDATE);
	pkt7(cs, CP_WAIT_MEM_WRITES, 0);
	wfi(cs);
	pkt7(cs, CP_WAIT_FOR_ME, 0);
}

/* ---- program state ---- */
struct xs_regs { uint16_t config, ctrl0_unused, instrlen, first_exec, stack_offset, hlsq_ctrl; };
static const struct xs_regs xs_regs[] = {
	[MESA_SHADER_VERTEX] = {REG_A6XX_SP_VS_CONFIG, 0, REG_A6XX_SP_VS_INSTRLEN, REG_A6XX_SP_VS_OBJ_FIRST_EXEC_OFFSET, REG_A6XX_SP_VS_PVT_MEM_HW_STACK_OFFSET, REG_A6XX_HLSQ_VS_CNTL},
	[MESA_SHADER_TESS_CTRL] = {REG_A6XX_SP_HS_CONFIG, 0, REG_A6XX_SP_HS_INSTRLEN, REG_A6XX_SP_HS_OBJ_FIRST_EXEC_OFFSET, REG_A6XX_SP_HS_PVT_MEM_HW_STACK_OFFSET, REG_A6XX_HLSQ_HS_CNTL},
	[MESA_SHADER_TESS_EVAL] = {REG_A6XX_SP_DS_CONFIG, 0, REG_A6XX_SP_DS_INSTRLEN, REG_A6XX_SP_DS_OBJ_FIRST_EXEC_OFFSET, REG_A6XX_SP_DS_PVT_MEM_HW_STACK_OFFSET, REG_A6XX_HLSQ_DS_CNTL},
	[MESA_SHADER_GEOMETRY] = {REG_A6XX_SP_GS_CONFIG, 0, REG_A6XX_SP_GS_INSTRLEN, REG_A6XX_SP_GS_OBJ_FIRST_EXEC_OFFSET, REG_A6XX_SP_GS_PVT_MEM_HW_STACK_OFFSET, REG_A6XX_HLSQ_GS_CNTL},
	[MESA_SHADER_FRAGMENT] = {REG_A6XX_SP_FS_CONFIG, 0, REG_A6XX_SP_FS_INSTRLEN, REG_A6XX_SP_FS_OBJ_FIRST_EXEC_OFFSET, REG_A6XX_SP_FS_PVT_MEM_HW_STACK_OFFSET, REG_A6XX_HLSQ_FS_CNTL},
	[MESA_SHADER_COMPUTE] = {REG_A6XX_SP_CS_CONFIG, 0, REG_A6XX_SP_CS_INSTRLEN, REG_A6XX_SP_CS_OBJ_FIRST_EXEC_OFFSET, REG_A6XX_SP_CS_PVT_MEM_HW_STACK_OFFSET, REG_A6XX_HLSQ_CS_CNTL},
};
static uint32_t stage_opcode(gl_shader_stage s) { return s == MESA_SHADER_FRAGMENT || s == MESA_SHADER_COMPUTE ? CP_LOAD_STATE6_FRAG : CP_LOAD_STATE6_GEOM; }
static enum a6xx_state_block stage_shader_block(gl_shader_stage s)
{
	switch (s) {
	case MESA_SHADER_VERTEX: return SB6_VS_SHADER;
	case MESA_SHADER_TESS_CTRL: return SB6_HS_SHADER;
	case MESA_SHADER_TESS_EVAL: return SB6_DS_SHADER;
	case MESA_SHADER_GEOMETRY: return SB6_GS_SHADER;
	case MESA_SHADER_FRAGMENT: return SB6_FS_SHADER;
	default: return SB6_CS_SHADER;
	}
}

static void emit_xs_config(struct nw_cs *cs, gl_shader_stage stage, const struct ir3_shader_variant *xs)
{
	const struct xs_regs *r = &xs_regs[stage];
	if (xs == NULL) {
		emit_reg(cs, r->config, 0);
		emit_reg(cs, r->hlsq_ctrl, 0);
		return;
	}
	emit_reg(cs, r->config, A6XX_SP_VS_CONFIG_ENABLED | COND(xs->bindless_tex, A6XX_SP_VS_CONFIG_BINDLESS_TEX) | COND(xs->bindless_samp, A6XX_SP_VS_CONFIG_BINDLESS_SAMP) | COND(xs->bindless_ibo, A6XX_SP_VS_CONFIG_BINDLESS_IBO) | COND(xs->bindless_ubo, A6XX_SP_VS_CONFIG_BINDLESS_UBO) | A6XX_SP_VS_CONFIG_NTEX(xs->num_samp) | A6XX_SP_VS_CONFIG_NSAMP(xs->num_samp));
	emit_reg(cs, r->hlsq_ctrl, A6XX_HLSQ_VS_CNTL_CONSTLEN(xs->constlen) | A6XX_HLSQ_VS_CNTL_ENABLED);
}

/* tu_setup_pvtmem: one area, grown when a program needs more. Programs baked before keep their own area in the slice they got (the old slice stays). */
static bool setup_pvtmem(struct nmn_gpu *g, uint32_t bytes, uint32_t *fiber, uint32_t *sp, uint64_t *iova)
{
	*fiber = *sp = 0;
	*iova = 0;
	if (bytes == 0)
		return true;
	if (g->pvt_fiber < bytes) {
		uint32_t f = util_next_power_of_two(ALIGN(bytes, 512));
		uint32_t s = ALIGN(f * g->info.fibers_per_sp, 1 << 12);
		struct nw_slice n;
		if (!nw_slice_new(g->dev, (uint64_t)g->info.num_sp_cores * s, 4096, &n))
			return false;
		g->pvt = n;     /* the old slice stays allocated: baked programs still name its address */
		g->pvt_fiber = f;
		g->pvt_sp = s;
	}
	*fiber = g->pvt_fiber;
	*sp = g->pvt_sp;
	*iova = g->pvt.iova;
	return true;
}

static void emit_xs(struct nw_cs *cs, struct nmn_gpu *g, gl_shader_stage stage, const struct ir3_shader_variant *xs, uint64_t binary_iova)
{
	enum a6xx_threadsize thrsz = xs->info.double_threadsize ? THREAD128 : THREAD64;
	switch (stage) {
	case MESA_SHADER_VERTEX:
		REGS(cs, A6XX_SP_VS_CTRL_REG0(.halfregfootprint = xs->info.max_half_reg + 1, .fullregfootprint = xs->info.max_reg + 1, .branchstack = ir3_shader_branchstack_hw(xs), .mergedregs = xs->mergedregs, .earlypreamble = xs->early_preamble));
		break;
	case MESA_SHADER_FRAGMENT:
		REGS(cs, A6XX_SP_FS_CTRL_REG0(.halfregfootprint = xs->info.max_half_reg + 1, .fullregfootprint = xs->info.max_reg + 1, .branchstack = ir3_shader_branchstack_hw(xs), .threadsize = thrsz, .varying = xs->total_in != 0, .lodpixmask = xs->need_full_quad, .unk24 = true, .pixlodenable = xs->need_pixlod, .earlypreamble = xs->early_preamble, .mergedregs = xs->mergedregs));
		break;
	default:
		thrsz = g->info.a6xx.supports_double_threadsize ? thrsz : THREAD128;
		REGS(cs, A6XX_SP_CS_CTRL_REG0(.halfregfootprint = xs->info.max_half_reg + 1, .fullregfootprint = xs->info.max_reg + 1, .branchstack = ir3_shader_branchstack_hw(xs), .threadsize = thrsz, .earlypreamble = xs->early_preamble, .mergedregs = xs->mergedregs));
		break;
	}
	const struct xs_regs *r = &xs_regs[stage];
	emit_reg(cs, r->instrlen, xs->instrlen);
	uint32_t fiber, sp;
	uint64_t pvt;
	setup_pvtmem(g, xs->pvtmem_size, &fiber, &sp, &pvt);
	pkt4(cs, r->first_exec, 7);
	nw_cs_emit(cs, 0);
	nw_cs_emit_qw(cs, binary_iova);
	nw_cs_emit(cs, A6XX_SP_VS_PVT_MEM_PARAM_MEMSIZEPERITEM(fiber));
	nw_cs_emit_qw(cs, pvt);
	nw_cs_emit(cs, A6XX_SP_VS_PVT_MEM_SIZE_TOTALPVTMEMSIZE(sp) | COND(xs->pvtmem_per_wave, A6XX_SP_VS_PVT_MEM_SIZE_PERWAVEMEMLAYOUT));
	pkt4(cs, r->stack_offset, 1);
	nw_cs_emit(cs, A6XX_SP_VS_PVT_MEM_HW_STACK_OFFSET_OFFSET(sp));
	uint32_t preload = MIN2(xs->instrlen, g->info.a6xx.instr_cache_size);
	pkt7(cs, stage_opcode(stage), 3);
	nw_cs_emit(cs, CP_LOAD_STATE6_0_DST_OFF(0) | CP_LOAD_STATE6_0_STATE_TYPE(ST6_SHADER) | CP_LOAD_STATE6_0_STATE_SRC(SS6_INDIRECT) | CP_LOAD_STATE6_0_STATE_BLOCK(stage_shader_block(stage)) | CP_LOAD_STATE6_0_NUM_UNIT(preload));
	nw_cs_emit_qw(cs, binary_iova);

	const struct ir3_const_state *cst = ir3_const_state(xs);
	uint32_t base = cst->allocs.max_const_offset_vec4;
	int32_t isize = DIV_ROUND_UP(cst->immediates_count, 4);
	isize = MIN2(isize + (int32_t)base, (int32_t)xs->constlen) - (int32_t)base;
	if (isize > 0) {
		pkt7(cs, stage_opcode(stage), 3 + isize * 4);
		nw_cs_emit(cs, CP_LOAD_STATE6_0_DST_OFF(base) | CP_LOAD_STATE6_0_STATE_TYPE(ST6_CONSTANTS) | CP_LOAD_STATE6_0_STATE_SRC(SS6_DIRECT) | CP_LOAD_STATE6_0_STATE_BLOCK(stage_shader_block(stage)) | CP_LOAD_STATE6_0_NUM_UNIT(isize));
		nw_cs_emit(cs, 0);
		nw_cs_emit(cs, 0);
		for (int i = 0; i < isize * 4; i++)
			nw_cs_emit(cs, cst->immediates[i]);
	}
	if (cst->consts_ubo.idx != -1) {
		uint64_t iova = binary_iova + xs->info.constant_data_offset;
		uint32_t offset = cst->consts_ubo.idx;
		pkt7(cs, stage_opcode(stage), 5);
		nw_cs_emit(cs, CP_LOAD_STATE6_0_DST_OFF(offset) | CP_LOAD_STATE6_0_STATE_TYPE(ST6_UBO) | CP_LOAD_STATE6_0_STATE_SRC(SS6_DIRECT) | CP_LOAD_STATE6_0_STATE_BLOCK(stage_shader_block(stage)) | CP_LOAD_STATE6_0_NUM_UNIT(1));
		nw_cs_emit(cs, 0);
		nw_cs_emit(cs, 0);
		nw_cs_emit_qw(cs, iova | ((uint64_t)A6XX_UBO_1_SIZE(DIV_ROUND_UP(xs->constant_data_size, 16)) << 32));
		const struct ir3_ubo_analysis_state *u = &cst->ubo_state;
		for (uint32_t i = 0; i < u->num_enabled; i++) {
			if (u->range[i].ubo.block != offset || u->range[i].ubo.bindless)
				continue;
			uint32_t start = u->range[i].start, end = u->range[i].end;
			uint32_t size = MIN2(end - start, 16 * xs->constlen - u->range[i].offset);
			pkt7(cs, stage_opcode(stage), 3);
			nw_cs_emit(cs, CP_LOAD_STATE6_0_DST_OFF(u->range[i].offset / 16) | CP_LOAD_STATE6_0_STATE_TYPE(ST6_CONSTANTS) | CP_LOAD_STATE6_0_STATE_SRC(SS6_INDIRECT) | CP_LOAD_STATE6_0_STATE_BLOCK(stage_shader_block(stage)) | CP_LOAD_STATE6_0_NUM_UNIT(size / 16));
			nw_cs_emit_qw(cs, iova + start);
		}
	}
	if (stage == MESA_SHADER_FRAGMENT && cst->num_driver_params > 0) {
		uint32_t b = cst->allocs.consts[IR3_CONST_ALLOC_DRIVER_PARAMS].offset_vec4;
		int32_t size = DIV_ROUND_UP(MAX2(cst->num_driver_params, 4), 4);
		size = MAX2(MIN2(size + (int32_t)b, (int32_t)xs->constlen) - (int32_t)b, 0);
		if (size > 0) {
			pkt7(cs, stage_opcode(stage), 3 + 4);
			nw_cs_emit(cs, CP_LOAD_STATE6_0_DST_OFF(b) | CP_LOAD_STATE6_0_STATE_TYPE(ST6_CONSTANTS) | CP_LOAD_STATE6_0_STATE_SRC(SS6_DIRECT) | CP_LOAD_STATE6_0_STATE_BLOCK(stage_shader_block(stage)) | CP_LOAD_STATE6_0_NUM_UNIT(size));
			nw_cs_emit(cs, 0);
			nw_cs_emit(cs, 0);
			nw_cs_emit(cs, xs->info.double_threadsize ? 128 : 64);
			nw_cs_emit(cs, 0);
			nw_cs_emit(cs, 0);
			nw_cs_emit(cs, 0);
		}
	}
}

static void emit_vs(struct nw_cs *cs, const struct nmn_gpu *g, const struct ir3_shader_variant *vs)
{
	if (g->info.a6xx.has_cp_reg_write) {
		pkt7(cs, CP_REG_WRITE, 3);
		nw_cs_emit(cs, CP_REG_WRITE_0_TRACKER(UNK_EVENT_WRITE));
		nw_cs_emit(cs, REG_A6XX_PC_MULTIVIEW_CNTL);
		nw_cs_emit(cs, 0);
	} else {
		emit_reg(cs, REG_A6XX_PC_MULTIVIEW_CNTL, 0);
	}
	emit_reg(cs, REG_A6XX_VFD_MULTIVIEW_CNTL, 0);
	int32_t input_for_attr[32];
	uint32_t attr_count = 0;
	for (unsigned i = 0; i < 32; i++)
		input_for_attr[i] = -1;
	for (unsigned i = 0; i < vs->inputs_count; i++) {
		if (vs->inputs[i].sysval || vs->inputs[i].regid == regid(63, 0))
			continue;
		unsigned loc = vs->inputs[i].slot - VERT_ATTRIB_GENERIC0;
		input_for_attr[loc] = (int32_t)i;
		attr_count = MAX2(attr_count, loc + 1);
	}
	REGS(cs, A6XX_VFD_CONTROL_0(.fetch_cnt = attr_count, .decode_cnt = attr_count));
	if (attr_count) {
		pkt4(cs, REG_A6XX_VFD_DEST_CNTL_INSTR(0), attr_count);
		for (unsigned i = 0; i < attr_count; i++) {
			if (input_for_attr[i] >= 0)
				nw_cs_emit(cs, A6XX_VFD_DEST_CNTL_INSTR(0, .writemask = vs->inputs[input_for_attr[i]].compmask, .regid = vs->inputs[input_for_attr[i]].regid).value);
			else
				nw_cs_emit(cs, A6XX_VFD_DEST_CNTL_INSTR(0, .writemask = 0, .regid = regid(63, 0)).value);
		}
	}
	pkt4(cs, REG_A6XX_VFD_CONTROL_1, 1);
	nw_cs_emit(cs, A6XX_VFD_CONTROL_1_REGID4VTX(ir3_find_sysval_regid(vs, SYSTEM_VALUE_VERTEX_ID)) | A6XX_VFD_CONTROL_1_REGID4INST(ir3_find_sysval_regid(vs, SYSTEM_VALUE_INSTANCE_ID)) | A6XX_VFD_CONTROL_1_REGID4PRIMID(ir3_find_sysval_regid(vs, SYSTEM_VALUE_PRIMITIVE_ID)) | A6XX_VFD_CONTROL_1_REGID4VIEWID(ir3_find_sysval_regid(vs, SYSTEM_VALUE_VIEW_INDEX)));
}

static void emit_fs_inputs(struct nw_cs *cs, const struct nmn_gpu *g, const struct ir3_shader_variant *fs)
{
	uint32_t ij[IJ_COUNT];
	bool sample_shading = fs->per_samp || fs->key.sample_shading;
	bool enable_varyings = fs->total_in > 0;
	uint32_t samp_id = ir3_find_sysval_regid(fs, SYSTEM_VALUE_SAMPLE_ID), smask_in = ir3_find_sysval_regid(fs, SYSTEM_VALUE_SAMPLE_MASK_IN), face = ir3_find_sysval_regid(fs, SYSTEM_VALUE_FRONT_FACE), coord = ir3_find_sysval_regid(fs, SYSTEM_VALUE_FRAG_COORD);
	uint32_t zw = VALIDREG(coord) ? coord + 2 : regid(63, 0), rate = ir3_find_sysval_regid(fs, SYSTEM_VALUE_FRAG_SHADING_RATE);
	for (unsigned i = 0; i < IJ_COUNT; i++)
		ij[i] = ir3_find_sysval_regid(fs, (gl_system_value)(SYSTEM_VALUE_BARYCENTRIC_PERSP_PIXEL + i));
	pkt4(cs, REG_A6XX_SP_FS_PREFETCH_CNTL, 1 + fs->num_sampler_prefetch);
	nw_cs_emit(cs, A6XX_SP_FS_PREFETCH_CNTL_COUNT(fs->num_sampler_prefetch) | COND(!VALIDREG(ij[IJ_PERSP_PIXEL]), A6XX_SP_FS_PREFETCH_CNTL_IJ_WRITE_DISABLE) | COND(fs->prefetch_end_of_quad, A6XX_SP_FS_PREFETCH_CNTL_ENDOFQUAD));
	for (unsigned i = 0; i < fs->num_sampler_prefetch; i++) {
		const struct ir3_sampler_prefetch *p = &fs->sampler_prefetch[i];
		enum a6xx_tex_prefetch_cmd c = p->tex_opc == OPC_SAM ? TEX_PREFETCH_SAM : p->tex_opc == OPC_SAMB ? TEX_PREFETCH_SAM : TEX_PREFETCH_SAM;
		nw_cs_emit(cs, SP_FS_PREFETCH_CMD(CHIP, i, .src = p->src, .samp_id = p->samp_id, .tex_id = p->tex_id, .dst = p->dst, .wrmask = p->wrmask, .half = p->half_precision, .bindless = p->bindless, .cmd = c).value);
	}
	REGS(cs, HLSQ_CONTROL_1_REG(CHIP, .primallocthreshold = g->info.a6xx.prim_alloc_threshold),
	     HLSQ_CONTROL_2_REG(CHIP, .faceregid = face, .sampleid = samp_id, .samplemask = smask_in, .centerrhw = ij[IJ_PERSP_CENTER_RHW]),
	     HLSQ_CONTROL_3_REG(CHIP, .ij_persp_pixel = ij[IJ_PERSP_PIXEL], .ij_linear_pixel = ij[IJ_LINEAR_PIXEL], .ij_persp_centroid = ij[IJ_PERSP_CENTROID], .ij_linear_centroid = ij[IJ_LINEAR_CENTROID]),
	     HLSQ_CONTROL_4_REG(CHIP, .ij_persp_sample = ij[IJ_PERSP_SAMPLE], .ij_linear_sample = ij[IJ_LINEAR_SAMPLE], .xycoordregid = coord, .zwcoordregid = zw),
	     HLSQ_CONTROL_5_REG(CHIP, .linelengthregid = 0xfc, .foveationqualityregid = rate));
	enum a6xx_threadsize thrsz = fs->info.double_threadsize ? THREAD128 : THREAD64;
	REGS(cs, HLSQ_FS_CNTL_0(CHIP, .threadsize = thrsz, .varyings = enable_varyings));
	bool need_size = fs->frag_face || fs->fragcoord_compmask != 0, need_size_persamp = false;
	if (VALIDREG(ij[IJ_PERSP_CENTER_RHW])) {
		if (sample_shading)
			need_size_persamp = true;
		else
			need_size = true;
	}
	pkt4(cs, REG_A6XX_GRAS_CNTL, 1);
	nw_cs_emit(cs, CONDREG(ij[IJ_PERSP_PIXEL], A6XX_GRAS_CNTL_IJ_PERSP_PIXEL) | CONDREG(ij[IJ_PERSP_CENTROID], A6XX_GRAS_CNTL_IJ_PERSP_CENTROID) | CONDREG(ij[IJ_PERSP_SAMPLE], A6XX_GRAS_CNTL_IJ_PERSP_SAMPLE) | CONDREG(ij[IJ_LINEAR_PIXEL], A6XX_GRAS_CNTL_IJ_LINEAR_PIXEL) | CONDREG(ij[IJ_LINEAR_CENTROID], A6XX_GRAS_CNTL_IJ_LINEAR_CENTROID) | CONDREG(ij[IJ_LINEAR_SAMPLE], A6XX_GRAS_CNTL_IJ_LINEAR_SAMPLE) | COND(need_size, A6XX_GRAS_CNTL_IJ_LINEAR_PIXEL) | COND(need_size_persamp, A6XX_GRAS_CNTL_IJ_LINEAR_SAMPLE) | COND(fs->fragcoord_compmask != 0, A6XX_GRAS_CNTL_COORD_MASK(fs->fragcoord_compmask)));
	pkt4(cs, REG_A6XX_RB_RENDER_CONTROL0, 2);
	nw_cs_emit(cs, CONDREG(ij[IJ_PERSP_PIXEL], A6XX_RB_RENDER_CONTROL0_IJ_PERSP_PIXEL) | CONDREG(ij[IJ_PERSP_CENTROID], A6XX_RB_RENDER_CONTROL0_IJ_PERSP_CENTROID) | CONDREG(ij[IJ_PERSP_SAMPLE], A6XX_RB_RENDER_CONTROL0_IJ_PERSP_SAMPLE) | CONDREG(ij[IJ_LINEAR_PIXEL], A6XX_RB_RENDER_CONTROL0_IJ_LINEAR_PIXEL) | CONDREG(ij[IJ_LINEAR_CENTROID], A6XX_RB_RENDER_CONTROL0_IJ_LINEAR_CENTROID) | CONDREG(ij[IJ_LINEAR_SAMPLE], A6XX_RB_RENDER_CONTROL0_IJ_LINEAR_SAMPLE) | COND(need_size, A6XX_RB_RENDER_CONTROL0_IJ_LINEAR_PIXEL) | COND(enable_varyings, A6XX_RB_RENDER_CONTROL0_UNK10) | COND(need_size_persamp, A6XX_RB_RENDER_CONTROL0_IJ_LINEAR_SAMPLE) | COND(fs->fragcoord_compmask != 0, A6XX_RB_RENDER_CONTROL0_COORD_MASK(fs->fragcoord_compmask)));
	nw_cs_emit(cs, A6XX_RB_RENDER_CONTROL1_FRAGCOORDSAMPLEMODE(sample_shading ? FRAGCOORD_SAMPLE : FRAGCOORD_CENTER) | CONDREG(smask_in, A6XX_RB_RENDER_CONTROL1_SAMPLEMASK) | CONDREG(samp_id, A6XX_RB_RENDER_CONTROL1_SAMPLEID) | CONDREG(ij[IJ_PERSP_CENTER_RHW], A6XX_RB_RENDER_CONTROL1_CENTERRHW) | COND(fs->post_depth_coverage, A6XX_RB_RENDER_CONTROL1_POSTDEPTHCOVERAGE) | COND(fs->frag_face, A6XX_RB_RENDER_CONTROL1_FACENESS) | CONDREG(rate, A6XX_RB_RENDER_CONTROL1_FOVEATION));
	emit_reg(cs, REG_A6XX_RB_SAMPLE_CNTL, COND(sample_shading, A6XX_RB_SAMPLE_CNTL_PER_SAMP_MODE));
	emit_reg(cs, REG_A6XX_GRAS_LRZ_PS_INPUT_CNTL, CONDREG(samp_id, A6XX_GRAS_LRZ_PS_INPUT_CNTL_SAMPLEID) | A6XX_GRAS_LRZ_PS_INPUT_CNTL_FRAGCOORDSAMPLEMODE(sample_shading ? FRAGCOORD_SAMPLE : FRAGCOORD_CENTER));
	emit_reg(cs, REG_A6XX_GRAS_SAMPLE_CNTL, COND(sample_shading, A6XX_GRAS_SAMPLE_CNTL_PER_SAMP_MODE));
	uint32_t varmask[4] = {0, 0, 0, 0};
	for (int i = ir3_next_varying(fs, -1); i < fs->inputs_count; i = ir3_next_varying(fs, i)) {
		if (fs->inputs[i].inloc >= fs->total_in)
			continue;
		unsigned loc = fs->inputs[i].inloc;
		for (int j = 0; j < util_last_bit(fs->inputs[i].compmask); j++) {
			uint8_t comploc = loc + j;
			varmask[comploc / 32] |= 1u << (comploc % 32);
		}
	}
	pkt4(cs, REG_A6XX_VPC_VAR_DISABLE(0), 4);
	for (int i = 0; i < 4; i++)
		nw_cs_emit(cs, ~varmask[i]);
	unsigned primid_loc = ir3_find_input_loc(fs, VARYING_SLOT_PRIMITIVE_ID), viewid_loc = ir3_find_input_loc(fs, VARYING_SLOT_VIEW_INDEX);
	pkt4(cs, REG_A6XX_VPC_CNTL_0, 1);
	nw_cs_emit(cs, A6XX_VPC_CNTL_0_NUMNONPOSVAR(fs->total_in) | COND(fs->total_in, A6XX_VPC_CNTL_0_VARYING) | A6XX_VPC_CNTL_0_PRIMIDLOC(primid_loc) | A6XX_VPC_CNTL_0_VIEWIDLOC(viewid_loc));
}

static void emit_fs_outputs(struct nw_cs *cs, const struct ir3_shader_variant *fs)
{
	uint32_t posz = ir3_find_output_regid(fs, FRAG_RESULT_DEPTH), smask = ir3_find_output_regid(fs, FRAG_RESULT_SAMPLE_MASK), sref = ir3_find_output_regid(fs, FRAG_RESULT_STENCIL);
	int count = 0;
	uint32_t data[8], comps = 0;
	for (uint32_t i = 0; i < 8; i++) {
		int idx = ir3_find_output(fs, (gl_varying_slot)(FRAG_RESULT_DATA0 + i));
		if (idx < 0) {
			data[i] = INVALID_REG;
			continue;
		}
		data[i] = ir3_get_output_regid(&fs->outputs[idx]);
		if (VALIDREG(data[i]))
			count = i + 1;
	}
	pkt4(cs, REG_A6XX_SP_FS_OUTPUT_CNTL0, 1);
	nw_cs_emit(cs, A6XX_SP_FS_OUTPUT_CNTL0_DEPTH_REGID(posz) | A6XX_SP_FS_OUTPUT_CNTL0_SAMPMASK_REGID(smask) | A6XX_SP_FS_OUTPUT_CNTL0_STENCILREF_REGID(sref) | COND(fs->dual_src_blend, A6XX_SP_FS_OUTPUT_CNTL0_DUAL_COLOR_IN_ENABLE));
	if (count) {
		pkt4(cs, REG_A6XX_SP_FS_OUTPUT_REG(0), count);
		for (int i = 0; i < count; i++) {
			nw_cs_emit(cs, A6XX_SP_FS_OUTPUT_REG_REGID(data[i]) | COND(data[i] & HALF_REG_ID, A6XX_SP_FS_OUTPUT_REG_HALF_PRECISION));
			if (VALIDREG(data[i]))
				comps |= 0xfu << (i * 4);
		}
	}
	REGS(cs, A6XX_SP_FS_RENDER_COMPONENTS(.dword = comps));
	pkt4(cs, REG_A6XX_RB_FS_OUTPUT_CNTL0, 1);
	nw_cs_emit(cs, COND(fs->writes_pos, A6XX_RB_FS_OUTPUT_CNTL0_FRAG_WRITES_Z) | COND(fs->writes_smask, A6XX_RB_FS_OUTPUT_CNTL0_FRAG_WRITES_SAMPMASK) | COND(fs->writes_stencilref, A6XX_RB_FS_OUTPUT_CNTL0_FRAG_WRITES_STENCILREF) | COND(fs->dual_src_blend, A6XX_RB_FS_OUTPUT_CNTL0_DUAL_COLOR_IN_ENABLE));
	REGS(cs, A6XX_RB_RENDER_COMPONENTS(.dword = comps));
}

static int varying_mode(const struct ir3_shader_variant *fs, const struct ir3_shader_variant *last, uint32_t index, uint8_t *interp, uint8_t *ps_repl)
{
	const uint32_t compmask = fs->inputs[index].compmask;
	int shift = 0;
	*interp = 0;
	*ps_repl = 0;
	if (fs->inputs[index].slot == VARYING_SLOT_PNTC) {
		if (compmask & 1) { *ps_repl |= PS_REPL_S << shift; shift += 2; }
		if (compmask & 2) { *ps_repl |= PS_REPL_T << shift; shift += 2; }
		if (compmask & 4) { *interp |= INTERP_ZERO << shift; shift += 2; }
		if (compmask & 8) { *interp |= INTERP_ONE << 6; shift += 2; }
	} else if (fs->inputs[index].slot == VARYING_SLOT_LAYER || fs->inputs[index].slot == VARYING_SLOT_VIEWPORT) {
		const gl_varying_slot slot = (gl_varying_slot)fs->inputs[index].slot;
		*interp |= ir3_find_output(last, slot) < 0 && (compmask & 1) ? INTERP_ZERO : INTERP_FLAT;
	} else if (fs->inputs[index].flat) {
		for (int i = 0; i < 4; i++)
			if (compmask & (1 << i)) { *interp |= INTERP_FLAT << shift; shift += 2; }
	}
	return util_bitcount(compmask) * 2;
}

static void emit_vpc(struct nw_cs *cs, const struct ir3_shader_variant *vs, const struct ir3_shader_variant *fs)
{
	struct ir3_shader_linkage linkage = {};
	linkage.primid_loc = 0xff;
	linkage.clip0_loc = 0xff;
	linkage.clip1_loc = 0xff;
	if (fs != NULL)
		ir3_link_shaders(&linkage, vs, fs, true);
	const uint32_t psize = ir3_find_output_regid(vs, VARYING_SLOT_PSIZ), layer = ir3_find_output_regid(vs, VARYING_SLOT_LAYER), view = ir3_find_output_regid(vs, VARYING_SLOT_VIEWPORT), clip0 = ir3_find_output_regid(vs, VARYING_SLOT_CLIP_DIST0), clip1 = ir3_find_output_regid(vs, VARYING_SLOT_CLIP_DIST1), rate = ir3_find_output_regid(vs, VARYING_SLOT_PRIMITIVE_SHADING_RATE);
	uint32_t psize_loc = 0xff, pos_loc = 0xff, layer_loc = 0xff, view_loc = 0xff, rate_loc = 0xff;
	if (layer != regid(63, 0)) { layer_loc = linkage.max_loc; ir3_link_add(&linkage, VARYING_SLOT_LAYER, layer, 0x1, linkage.max_loc); }
	if (view != regid(63, 0)) { view_loc = linkage.max_loc; ir3_link_add(&linkage, VARYING_SLOT_VIEWPORT, view, 0x1, linkage.max_loc); }
	if (rate != regid(63, 0)) { rate_loc = linkage.max_loc; ir3_link_add(&linkage, VARYING_SLOT_PRIMITIVE_SHADING_RATE, rate, 0x1, linkage.max_loc); }
	unsigned extra_pos = 0;
	for (unsigned i = 0; i < vs->outputs_count; i++) {
		if (vs->outputs[i].slot != VARYING_SLOT_POS)
			continue;
		if (pos_loc == 0xff)
			pos_loc = linkage.max_loc;
		ir3_link_add(&linkage, vs->outputs[i].slot, vs->outputs[i].regid, 0xf, pos_loc + 4 * vs->outputs[i].view);
		extra_pos = MAX2(extra_pos, vs->outputs[i].view);
	}
	if (psize != regid(63, 0)) { psize_loc = linkage.max_loc; ir3_link_add(&linkage, VARYING_SLOT_PSIZ, psize, 0x1, linkage.max_loc); }
	uint8_t clip_cull = vs->clip_mask | vs->cull_mask;
	uint32_t c0 = linkage.clip0_loc, c1 = linkage.clip1_loc;
	if (c0 == 0xff && clip0 != regid(63, 0)) { c0 = linkage.max_loc; ir3_link_add(&linkage, VARYING_SLOT_CLIP_DIST0, clip0, clip_cull & 0xf, linkage.max_loc); }
	if (c1 == 0xff && clip1 != regid(63, 0)) { c1 = linkage.max_loc; ir3_link_add(&linkage, VARYING_SLOT_CLIP_DIST1, clip1, clip_cull >> 4, linkage.max_loc); }
	/* tu6_setup_streamout, no stream output */
	REGS(cs, A6XX_VPC_SO_STREAM_CNTL());
	if (linkage.cnt == 0)
		ir3_link_add(&linkage, 0, 0, 0x1, linkage.max_loc);
	const uint32_t out_count = DIV_ROUND_UP(linkage.cnt, 2), dst_count = DIV_ROUND_UP(linkage.cnt, 4);
	uint32_t sp_out[16] = {0}, sp_dst[8] = {0};
	for (uint32_t i = 0; i < linkage.cnt; i++) {
		/* two entries per dword, four per dword: written by shifts (Turnip's casts need -fno-strict-aliasing; pm4-compare.sh found that at -O2) */
		sp_out[i / 2] |= (A6XX_SP_VS_OUT_REG_A_REGID(linkage.var[i].regid) | A6XX_SP_VS_OUT_REG_A_COMPMASK(linkage.var[i].compmask)) << (16 * (i % 2));
		sp_dst[i / 4] |= A6XX_SP_VS_VPC_DST_REG_OUTLOC0(linkage.var[i].loc) << (8 * (i % 4));
	}
	pkt4(cs, REG_A6XX_SP_VS_OUT_REG(0), out_count);
	for (uint32_t i = 0; i < out_count; i++)
		nw_cs_emit(cs, sp_out[i]);
	pkt4(cs, REG_A6XX_SP_VS_VPC_DST_REG(0), dst_count);
	for (uint32_t i = 0; i < dst_count; i++)
		nw_cs_emit(cs, sp_dst[i]);
	emit_reg(cs, REG_A6XX_VPC_VS_PACK, A6XX_VPC_VS_PACK_POSITIONLOC(pos_loc) | A6XX_VPC_VS_PACK_PSIZELOC(psize_loc) | A6XX_VPC_VS_PACK_STRIDE_IN_VPC(linkage.max_loc) | A6XX_VPC_VS_PACK_EXTRAPOS(extra_pos));
	uint32_t clip = A6XX_VPC_VS_CLIP_CNTL_CLIP_MASK(clip_cull) | A6XX_VPC_VS_CLIP_CNTL_CLIP_DIST_03_LOC(c0) | A6XX_VPC_VS_CLIP_CNTL_CLIP_DIST_47_LOC(c1);
	emit_reg(cs, REG_A6XX_VPC_VS_CLIP_CNTL, clip);
	emit_reg(cs, REG_A6XX_VPC_VS_CLIP_CNTL_V2, clip);
	emit_reg(cs, REG_A6XX_GRAS_VS_CL_CNTL, A6XX_GRAS_VS_CL_CNTL_CLIP_MASK(vs->clip_mask) | A6XX_GRAS_VS_CL_CNTL_CULL_MASK(vs->cull_mask));
	emit_reg(cs, REG_A6XX_PC_VS_OUT_CNTL, A6XX_PC_VS_OUT_CNTL_STRIDE_IN_VPC(linkage.max_loc) | CONDREG(psize, A6XX_PC_VS_OUT_CNTL_PSIZE) | CONDREG(layer, A6XX_PC_VS_OUT_CNTL_LAYER) | CONDREG(view, A6XX_PC_VS_OUT_CNTL_VIEW) | A6XX_PC_VS_OUT_CNTL_CLIP_MASK(clip_cull) | CONDREG(rate, A6XX_PC_VS_OUT_CNTL_SHADINGRATE));
	emit_reg(cs, REG_A6XX_SP_VS_PRIMITIVE_CNTL, A6XX_SP_VS_PRIMITIVE_CNTL_OUT(linkage.cnt));
	uint32_t l = A6XX_VPC_VS_LAYER_CNTL_LAYERLOC(layer_loc) | A6XX_VPC_VS_LAYER_CNTL_VIEWLOC(view_loc) | A6XX_VPC_VS_LAYER_CNTL_SHADINGRATELOC(rate_loc);
	emit_reg(cs, REG_A6XX_VPC_VS_LAYER_CNTL, l);
	emit_reg(cs, REG_A6XX_VPC_VS_LAYER_CNTL_V2, l);
	emit_reg(cs, REG_A6XX_GRAS_VS_LAYER_CNTL, CONDREG(layer, A6XX_GRAS_GS_LAYER_CNTL_WRITES_LAYER) | CONDREG(view, A6XX_GRAS_GS_LAYER_CNTL_WRITES_VIEW));
	if (fs != NULL) {
		uint32_t interp[8] = {0}, repl[8] = {0}, regs = 0;
		for (int i = -1; (i = ir3_next_varying(fs, i)) < (int)fs->inputs_count;) {
			uint8_t im, rm;
			const int bits = varying_mode(fs, vs, i, &im, &rm);
			const uint32_t inloc = fs->inputs[i].inloc * 2;
			uint32_t n = inloc / 32, shift = inloc % 32;
			interp[n] |= (uint32_t)im << shift;
			repl[n] |= (uint32_t)rm << shift;
			if (shift + bits > 32) {
				n++;
				shift = 32 - shift;
				interp[n] |= im >> shift;
				repl[n] |= rm >> shift;
			}
			regs = MAX2(regs, n + 1);
		}
		if (regs) {
			pkt4(cs, REG_A6XX_VPC_VARYING_INTERP_MODE(0), regs);
			for (uint32_t i = 0; i < regs; i++)
				nw_cs_emit(cs, interp[i]);
			pkt4(cs, REG_A6XX_VPC_VARYING_PS_REPL_MODE(0), regs);
			for (uint32_t i = 0; i < regs; i++)
				nw_cs_emit(cs, repl[i]);
		}
	}
}

static enum adreno_rb_blend_factor blend_factor(uint32_t m)
{
	/* MTLBlendFactor */
	switch (m) {
	case 0: return FACTOR_ZERO;
	case 1: return FACTOR_ONE;
	case 2: return FACTOR_SRC_COLOR;
	case 3: return FACTOR_ONE_MINUS_SRC_COLOR;
	case 4: return FACTOR_SRC_ALPHA;
	case 5: return FACTOR_ONE_MINUS_SRC_ALPHA;
	case 6: return FACTOR_DST_COLOR;
	case 7: return FACTOR_ONE_MINUS_DST_COLOR;
	case 8: return FACTOR_DST_ALPHA;
	case 9: return FACTOR_ONE_MINUS_DST_ALPHA;
	case 10: return FACTOR_SRC_ALPHA_SATURATE;
	case 11: return FACTOR_CONSTANT_COLOR;
	case 12: return FACTOR_ONE_MINUS_CONSTANT_COLOR;
	case 13: return FACTOR_CONSTANT_ALPHA;
	case 14: return FACTOR_ONE_MINUS_CONSTANT_ALPHA;
	case 15: return FACTOR_SRC1_COLOR;
	case 16: return FACTOR_ONE_MINUS_SRC1_COLOR;
	case 17: return FACTOR_SRC1_ALPHA;
	case 18: return FACTOR_ONE_MINUS_SRC1_ALPHA;
	default: return FACTOR_ZERO;
	}
}
static enum a3xx_rb_blend_opcode blend_op(uint32_t m)
{
	switch (m) {
	case 1: return BLEND_SRC_MINUS_DST;
	case 2: return BLEND_DST_MINUS_SRC;
	case 3: return BLEND_MIN_DST_SRC;
	case 4: return BLEND_MAX_DST_SRC;
	default: return BLEND_DST_PLUS_SRC;
	}
}

struct nmn_baked *nmn_bake_render(struct nmn_gpu *g, const void *vsv, const void *fsv, const struct nmn_fixed *fx, char *why, size_t why_size)
{
	const struct ir3_shader_variant *vs = (const struct ir3_shader_variant *)vsv, *fs = (const struct ir3_shader_variant *)fsv;
	struct nmn_baked *b = (struct nmn_baked *)calloc(1, sizeof(*b));
	if (b == NULL) {
		snprintf(why, why_size, "no memory");
		return NULL;
	}
	uint32_t vbytes = vs->info.size + vs->constant_data_size, fbytes = fs ? fs->info.size + fs->constant_data_size : 0;
	if (!nw_slice_new(g->dev, ALIGN(vbytes, 128) + ALIGN(fbytes, 128), 128, &b->code)) {
		snprintf(why, why_size, "no GPU memory for code");
		free(b);
		return NULL;
	}
	memcpy(b->code.map, vs->bin, vs->info.size);
	if (vs->constant_data_size)
		memcpy((char *)b->code.map + vs->info.constant_data_offset, vs->constant_data, vs->constant_data_size);
	uint64_t fiova = b->code.iova + ALIGN(vbytes, 128);
	if (fs != NULL) {
		char *f = (char *)b->code.map + ALIGN(vbytes, 128);
		memcpy(f, fs->bin, fs->info.size);
		if (fs->constant_data_size)
			memcpy(f + fs->info.constant_data_offset, fs->constant_data, fs->constant_data_size);
	}
	/* the state stream lives in its own chunk of a small stream, copied to a slice */
	struct nw_cs cs;
	nw_cs_init(&cs, g->dev);
	REGS(&cs, A6XX_HLSQ_SHARED_CONSTS(.enable = false));
	REGS(&cs, A6XX_SP_MODE_CONTROL(.constant_demotion_enable = true, .isammode = ISAMMODE_GL, .shared_consts_enable = false));
	REGS(&cs, HLSQ_INVALIDATE_CMD(CHIP, .vs_state = true, .hs_state = true, .ds_state = true, .gs_state = true, .fs_state = true, .gfx_ibo = true));
	emit_xs_config(&cs, MESA_SHADER_VERTEX, vs);
	emit_xs_config(&cs, MESA_SHADER_TESS_CTRL, NULL);
	emit_xs_config(&cs, MESA_SHADER_TESS_EVAL, NULL);
	emit_xs_config(&cs, MESA_SHADER_GEOMETRY, NULL);
	emit_xs_config(&cs, MESA_SHADER_FRAGMENT, fs);
	emit_xs(&cs, g, MESA_SHADER_VERTEX, vs, b->code.iova);
	emit_vs(&cs, g, vs);
	if (fs != NULL)
		emit_xs(&cs, g, MESA_SHADER_FRAGMENT, fs, fiova);
	pkt4(&cs, REG_A6XX_VFD_CONTROL_6, 1);
	nw_cs_emit(&cs, COND(fs && fs->reads_primid, A6XX_VFD_CONTROL_6_PRIMID4PSEN));
	REGS(&cs, A6XX_PC_PS_CNTL(.primitiveiden = fs && fs->reads_primid));
	struct ir3_shader_variant empty = {};
	emit_fs_inputs(&cs, g, fs ? fs : &empty);
	emit_fs_outputs(&cs, fs ? fs : &empty);
	emit_vpc(&cs, vs, fs);
	/* tu6_emit_vs state defaults that Turnip's other groups set */
	emit_reg(&cs, REG_A6XX_VFD_CONTROL_2, A6XX_VFD_CONTROL_2_REGID_HSRELPATCHID(regid(63, 0)) | A6XX_VFD_CONTROL_2_REGID_INVOCATIONID(regid(63, 0)));
	emit_reg(&cs, REG_A6XX_VFD_CONTROL_3, A6XX_VFD_CONTROL_3_REGID_DSPRIMID(regid(63, 0)) | A6XX_VFD_CONTROL_3_REGID_DSRELPATCHID(regid(63, 0)) | A6XX_VFD_CONTROL_3_REGID_TESSX(regid(63, 0)) | A6XX_VFD_CONTROL_3_REGID_TESSY(regid(63, 0)));
	emit_reg(&cs, REG_A6XX_VFD_CONTROL_4, A6XX_VFD_CONTROL_4_UNK0(regid(63, 0)));
	emit_reg(&cs, REG_A6XX_VFD_CONTROL_5, A6XX_VFD_CONTROL_5_REGID_GSHEADER(regid(63, 0)) | A6XX_VFD_CONTROL_5_UNK8(regid(63, 0)));
	/* vertex input */
	if (fx->attr_count) {
		pkt4(&cs, REG_A6XX_VFD_DECODE_INSTR(0), fx->attr_count * 2);
		for (uint32_t i = 0; i < fx->attr_count; i++) {
			const struct nmn_vertex_attr *a = &fx->attrs[i];
			if (a->pipe_format == 0) {
				nw_cs_emit(&cs, 0);
				nw_cs_emit(&cs, 0);
				continue;
			}
			enum pipe_format f = (enum pipe_format)a->pipe_format;
			nw_cs_emit(&cs, A6XX_VFD_DECODE_INSTR(0, .idx = a->binding, .offset = a->offset, .instanced = a->instanced, .format = fd6_vertex_format(f), .swap = fd6_vertex_swap(f), .unk30 = 1, ._float = a->is_float).value);
			nw_cs_emit(&cs, A6XX_VFD_DECODE_STEP_RATE(0, a->step_rate).value);
		}
	}
	/* blend */
	uint32_t enable = 0;
	for (uint32_t i = 0; i < fx->color_count; i++)
		if (fx->blend[i].enable)
			enable |= 1u << i;
	REGS(&cs, A6XX_SP_FS_OUTPUT_CNTL1(.mrt = fx->color_count));
	REGS(&cs, A6XX_RB_FS_OUTPUT_CNTL1(.mrt = fx->color_count));
	REGS(&cs, A6XX_SP_BLEND_CNTL(.enable_blend = enable, .unk8 = true));
	REGS(&cs, A6XX_RB_BLEND_CNTL(.enable_blend = enable, .independent_blend = true, .sample_mask = 0xffff));
	for (uint32_t i = 0; i < fx->color_count; i++) {
		const struct nmn_blend *a = &fx->blend[i];
		/* MTLColorWriteMask: red 8, green 4, blue 2, alpha 1 -> component enable bit 0 = red */
		bool fs_writes = false;
		if (fs != NULL) {
			int idx = ir3_find_output(fs, (gl_varying_slot)(FRAG_RESULT_DATA0 + i));
			fs_writes = idx >= 0 && VALIDREG(ir3_get_output_regid(&fs->outputs[idx]));
		}
		uint32_t mask = ((a->write_mask & 8) ? 1 : 0) | ((a->write_mask & 4) ? 2 : 0) | ((a->write_mask & 2) ? 4 : 0) | ((a->write_mask & 1) ? 8 : 0);
		REGS(&cs, A6XX_RB_MRT_CONTROL(i, .blend = a->enable, .blend2 = a->enable, .rop_enable = false, .rop_code = ROP_CLEAR, .component_enable = fs_writes ? mask : 0),
		     A6XX_RB_MRT_BLEND_CONTROL(i, .rgb_src_factor = blend_factor(a->src_rgb), .rgb_blend_opcode = blend_op(a->op_rgb), .rgb_dest_factor = blend_factor(a->dst_rgb), .alpha_src_factor = blend_factor(a->src_a), .alpha_blend_opcode = blend_op(a->op_a), .alpha_dest_factor = blend_factor(a->dst_a)));
	}
	REGS(&cs, PC_RASTER_CNTL(CHIP, .stream = 0, .discard = fx->rasterizer_discard));
	REGS(&cs, A6XX_VPC_UNKNOWN_9107(.raster_discard = fx->rasterizer_discard));
	REGS(&cs, A6XX_GRAS_SU_POINT_MINMAX(.min = 1.0f / 16.0f, .max = 4092.0f), A6XX_GRAS_SU_POINT_SIZE(1.0f));
	nw_cs_end_ib(&cs);
	uint32_t dwords = 0;
	for (uint32_t i = 0; i < cs.ib_count; i++)
		dwords += cs.ibs[i].dwords;
	if (cs.failed || !nw_slice_new(g->dev, dwords * 4ull, 64, &b->state)) {
		snprintf(why, why_size, "no GPU memory for program state");
		nw_cs_finish(&cs);
		nw_slice_free(g->dev, &b->code);
		free(b);
		return NULL;
	}
	uint32_t at = 0;
	for (uint32_t i = 0; i < cs.ib_count; i++) {
		memcpy((uint32_t *)b->state.map + at, (char *)cs.ibs[i].bo->map + cs.ibs[i].offset, cs.ibs[i].dwords * 4);
		at += cs.ibs[i].dwords;
	}
	nw_cs_finish(&cs);
	b->dwords = dwords;
	b->vs = vs;
	b->fs = fs;
	return b;
}

struct nmn_baked *nmn_bake_compute(struct nmn_gpu *g, const void *csv, char *why, size_t why_size)
{
	const struct ir3_shader_variant *v = (const struct ir3_shader_variant *)csv;
	struct nmn_baked *b = (struct nmn_baked *)calloc(1, sizeof(*b));
	if (b == NULL) {
		snprintf(why, why_size, "no memory");
		return NULL;
	}
	uint32_t bytes = v->info.size + v->constant_data_size;
	if (!nw_slice_new(g->dev, ALIGN(bytes, 128), 128, &b->code)) {
		snprintf(why, why_size, "no GPU memory for code");
		free(b);
		return NULL;
	}
	memcpy(b->code.map, v->bin, v->info.size);
	if (v->constant_data_size)
		memcpy((char *)b->code.map + v->info.constant_data_offset, v->constant_data, v->constant_data_size);
	struct nw_cs cs;
	nw_cs_init(&cs, g->dev);
	REGS(&cs, A6XX_HLSQ_SHARED_CONSTS(.enable = false));
	REGS(&cs, HLSQ_INVALIDATE_CMD(CHIP, .cs_state = true, .cs_ibo = true));
	emit_xs_config(&cs, MESA_SHADER_COMPUTE, v);
	emit_xs(&cs, g, MESA_SHADER_COMPUTE, v, b->code.iova);
	uint32_t shared = MAX2(((int)v->shared_size - 1) / 1024, 1);
	enum a6xx_const_ram_mode mode = v->constlen > 256 ? CONSTLEN_512 : v->constlen > 192 ? CONSTLEN_256 : v->constlen > 128 ? CONSTLEN_192 : CONSTLEN_128;
	pkt4(&cs, REG_A6XX_SP_CS_CTRL_REG1, 1);
	nw_cs_emit(&cs, A6XX_SP_CS_CTRL_REG1_SHARED_SIZE(shared) | A6XX_SP_CS_CTRL_REG1_CONSTANTRAMMODE(mode));
	uint32_t local = ir3_find_sysval_regid(v, SYSTEM_VALUE_LOCAL_INVOCATION_ID), group = ir3_find_sysval_regid(v, SYSTEM_VALUE_WORKGROUP_ID);
	enum a6xx_threadsize thrsz = v->info.double_threadsize ? THREAD128 : THREAD64;
	enum a6xx_threadsize thrsz_cs = g->info.a6xx.supports_double_threadsize ? thrsz : THREAD128;
	pkt4(&cs, REG_A6XX_HLSQ_CS_CNTL_0, 2);
	nw_cs_emit(&cs, A6XX_HLSQ_CS_CNTL_0_WGIDCONSTID(group) | A6XX_HLSQ_CS_CNTL_0_WGSIZECONSTID(regid(63, 0)) | A6XX_HLSQ_CS_CNTL_0_WGOFFSETCONSTID(regid(63, 0)) | A6XX_HLSQ_CS_CNTL_0_LOCALIDREGID(local));
	nw_cs_emit(&cs, A6XX_HLSQ_CS_CNTL_1_LINEARLOCALIDREGID(regid(63, 0)) | A6XX_HLSQ_CS_CNTL_1_THREADSIZE(thrsz_cs));
	if (!g->info.a6xx.supports_double_threadsize) {
		pkt4(&cs, REG_A6XX_HLSQ_FS_CNTL_0, 1);
		nw_cs_emit(&cs, A6XX_HLSQ_FS_CNTL_0_THREADSIZE(thrsz));
	}
	nw_cs_end_ib(&cs);
	uint32_t dwords = 0;
	for (uint32_t i = 0; i < cs.ib_count; i++)
		dwords += cs.ibs[i].dwords;
	if (cs.failed || !nw_slice_new(g->dev, dwords * 4ull, 64, &b->state)) {
		snprintf(why, why_size, "no GPU memory for program state");
		nw_cs_finish(&cs);
		nw_slice_free(g->dev, &b->code);
		free(b);
		return NULL;
	}
	uint32_t at = 0;
	for (uint32_t i = 0; i < cs.ib_count; i++) {
		memcpy((uint32_t *)b->state.map + at, (char *)cs.ibs[i].bo->map + cs.ibs[i].offset, cs.ibs[i].dwords * 4);
		at += cs.ibs[i].dwords;
	}
	nw_cs_finish(&cs);
	b->dwords = dwords;
	b->cs = v;
	return b;
}

void nmn_baked_free(struct nmn_gpu *g, struct nmn_baked *b)
{
	if (b == NULL)
		return;
	nw_slice_free(g->dev, &b->code);
	nw_slice_free(g->dev, &b->state);
	free(b);
}

void nmn_baked_info(const struct nmn_baked *b, uint32_t *dwords, bool *reads)
{
	*dwords = b->dwords;
	*reads = b->reads_framebuffer;
}

/* The program's stream is called, so a pipeline costs 4 dwords per bind and no copy. */
void nmn_cmd_program(struct nw_cs *cs, const struct nmn_baked *b)
{
	pkt7(cs, CP_INDIRECT_BUFFER, 3);
	nw_cs_emit_qw(cs, b->state.iova);
	nw_cs_emit(cs, b->dwords);
}

/* ---- dynamic state ---- */
void nmn_cmd_raster(struct nw_cs *cs, const struct nmn_raster *r)
{
	/* Metal's y goes up in clip space and down in the target; the translator's SPIR-V is Vulkan's, so the viewport flips, as the runtime's negative height does */
	float sx = (float)r->viewport[2] / 2.0f, sy = -(float)r->viewport[3] / 2.0f, sz = (float)(r->viewport[5] - r->viewport[4]);
	float ox = (float)r->viewport[0] + sx, oy = (float)r->viewport[1] - sy, oz = (float)r->viewport[4];
	pkt4(cs, REG_A6XX_GRAS_CL_VPORT_XOFFSET(0), 6);
	nw_cs_emit(cs, fui(ox)); nw_cs_emit(cs, fui(sx));
	nw_cs_emit(cs, fui(oy)); nw_cs_emit(cs, fui(sy));
	nw_cs_emit(cs, fui(oz)); nw_cs_emit(cs, fui(sz));
	uint32_t gx = MIN2(511u, fd_calc_guardband(ox, sx, false)), gy = MIN2(511u, fd_calc_guardband(oy, sy, false));
	/* the viewport's scissor: Metal's viewport rectangle, with y up to down as a Vulkan negative height gives */
	int32_t minx = MAX2((int32_t)r->viewport[0], 0), maxx = MAX2((int32_t)ceil(r->viewport[0] + r->viewport[2]), 1);
	double y0 = MIN2(r->viewport[1], r->viewport[1] + r->viewport[3]), y1 = MAX2(r->viewport[1], r->viewport[1] + r->viewport[3]);
	int32_t miny = MAX2((int32_t)y0, 0), maxy = MAX2((int32_t)ceil(y1), 1);
	pkt4(cs, REG_A6XX_GRAS_SC_VIEWPORT_SCISSOR_TL(0), 2);
	nw_cs_emit(cs, A6XX_GRAS_SC_VIEWPORT_SCISSOR_TL_X(minx) | A6XX_GRAS_SC_VIEWPORT_SCISSOR_TL_Y(miny));
	nw_cs_emit(cs, A6XX_GRAS_SC_VIEWPORT_SCISSOR_BR_X(maxx - 1) | A6XX_GRAS_SC_VIEWPORT_SCISSOR_BR_Y(maxy - 1));
	float zmin = (float)MIN2(r->viewport[4], r->viewport[5]), zmax = (float)MAX2(r->viewport[4], r->viewport[5]);
	pkt4(cs, REG_A6XX_GRAS_CL_Z_CLAMP(0), 2);
	nw_cs_emit(cs, fui(zmin));
	nw_cs_emit(cs, fui(zmax));
	pkt4(cs, REG_A6XX_GRAS_CL_GUARDBAND_CLIP_ADJ, 1);
	nw_cs_emit(cs, A6XX_GRAS_CL_GUARDBAND_CLIP_ADJ_HORZ(gx) | A6XX_GRAS_CL_GUARDBAND_CLIP_ADJ_VERT(gy));
	REGS(cs, A6XX_RB_Z_CLAMP_MIN(zmin), A6XX_RB_Z_CLAMP_MAX(zmax));
	/* scissor */
	uint32_t x = r->scissor[0], y = r->scissor[1], w = r->scissor[2], h = r->scissor[3];
	if (w == 0 || h == 0) {
		/* a4xx-style: an empty scissor is BR < TL */
		pkt4(cs, REG_A6XX_GRAS_SC_SCREEN_SCISSOR_TL(0), 2);
		nw_cs_emit(cs, A6XX_GRAS_SC_SCREEN_SCISSOR_TL_X(1) | A6XX_GRAS_SC_SCREEN_SCISSOR_TL_Y(1));
		nw_cs_emit(cs, A6XX_GRAS_SC_SCREEN_SCISSOR_BR_X(0) | A6XX_GRAS_SC_SCREEN_SCISSOR_BR_Y(0));
	} else {
		pkt4(cs, REG_A6XX_GRAS_SC_SCREEN_SCISSOR_TL(0), 2);
		nw_cs_emit(cs, A6XX_GRAS_SC_SCREEN_SCISSOR_TL_X(x) | A6XX_GRAS_SC_SCREEN_SCISSOR_TL_Y(y));
		nw_cs_emit(cs, A6XX_GRAS_SC_SCREEN_SCISSOR_BR_X(x + w - 1) | A6XX_GRAS_SC_SCREEN_SCISSOR_BR_Y(y + h - 1));
	}
	/* raster. MTLCullMode: 0 none, 1 front, 2 back. MTLWinding: 0 clockwise, 1 counter-clockwise. */
	REGS(cs, A6XX_GRAS_SU_CNTL(.cull_front = r->cull_mode == 1, .cull_back = r->cull_mode == 2, .front_cw = r->winding == 0, .linehalfwidth = r->line_width / 2.0f, .poly_offset = true, .line_mode = RECTANGULAR));
	REGS(cs, A6XX_GRAS_CL_CNTL(.znear_clip_disable = false, .zfar_clip_disable = false, .z_clamp_enable = false, .zero_gb_scale_z = 1, .vp_clip_code_ignore = 1));
	enum a6xx_polygon_mode pm = r->fill_mode == 1 ? POLYMODE6_LINES : POLYMODE6_TRIANGLES;
	REGS(cs, A6XX_VPC_POLYGON_MODE(pm));
	REGS(cs, PC_POLYGON_MODE(CHIP, pm));
	REGS(cs, A6XX_GRAS_SU_POLY_OFFSET_SCALE(r->slope_scale), A6XX_GRAS_SU_POLY_OFFSET_OFFSET(r->depth_bias), A6XX_GRAS_SU_POLY_OFFSET_OFFSET_CLAMP(r->bias_clamp));
	/* single prim mode: decided by what the fragment shader's code does, not by the pipeline's fetch state (doc section 3.3) */
	REGS(cs, A6XX_GRAS_SC_CNTL(.ccusinglecachelinesize = 2, .single_prim_mode = r->reads_framebuffer ? FLUSH_PER_OVERLAP_AND_OVERWRITE : NO_FLUSH));
	/* depth, stencil */
	REGS(cs, A6XX_RB_DEPTH_CNTL(.z_test_enable = r->depth_test, .z_write_enable = r->depth_write, .zfunc = r->depth_test ? (enum adreno_compare_func)r->depth_func : FUNC_NEVER, .z_clamp_enable = false, .z_read_enable = r->depth_test));
	REGS(cs, A6XX_GRAS_SU_DEPTH_CNTL(.z_test_enable = r->depth_test));
	REGS(cs, A6XX_RB_STENCIL_CONTROL(.func = FUNC_ALWAYS, .fail = STENCIL_KEEP, .zpass = STENCIL_KEEP, .zfail = STENCIL_KEEP, .func_bf = FUNC_ALWAYS, .fail_bf = STENCIL_KEEP, .zpass_bf = STENCIL_KEEP, .zfail_bf = STENCIL_KEEP));
	REGS(cs, A6XX_GRAS_SU_STENCIL_CNTL(.stencil_enable = false));
	REGS(cs, A6XX_RB_STENCILMASK(.mask = 0xff, .bfmask = 0xff), A6XX_RB_STENCILWRMASK(.wrmask = 0xff, .bfwrmask = 0xff), A6XX_RB_STENCILREF(.ref = r->stencil_front, .bfref = r->stencil_back));
	REGS(cs, A6XX_RB_Z_BOUNDS_MIN(0.0f), A6XX_RB_Z_BOUNDS_MAX(1.0f));
	REGS(cs, A6XX_RB_LRZ_CNTL());
	pkt4(cs, REG_A6XX_RB_BLEND_RED_F32, 4);
	nw_cs_emit(cs, fui(r->blend_color[0]));
	nw_cs_emit(cs, fui(r->blend_color[1]));
	nw_cs_emit(cs, fui(r->blend_color[2]));
	nw_cs_emit(cs, fui(r->blend_color[3]));
}

/* After nmn_cmd_program: the program's HLSQ_INVALIDATE_CMD must not undo this. */
void nmn_cmd_descriptor_sets(struct nw_cs *cs, const uint64_t *set, uint32_t count, bool graphics)
{
	uint32_t sp = graphics ? REG_A6XX_SP_BINDLESS_BASE(0) : REG_A6XX_SP_CS_BINDLESS_BASE(0);
	uint32_t hlsq = graphics ? REG_A6XX_HLSQ_BINDLESS_BASE(0) : REG_A6XX_HLSQ_CS_BINDLESS_BASE(0);
	pkt4(cs, sp, 2 * count);
	for (uint32_t i = 0; i < count; i++)
		nw_cs_emit_qw(cs, set[i] | 3); /* tu: the low bits are DESC_SIZE: BINDLESS_DESCRIPTOR_64B */
	pkt4(cs, hlsq, 2 * count);
	for (uint32_t i = 0; i < count; i++)
		nw_cs_emit_qw(cs, set[i] | 3);
	if (graphics)
		REGS(cs, HLSQ_INVALIDATE_CMD(CHIP, .gfx_bindless = 0x1f));
	else
		REGS(cs, HLSQ_INVALIDATE_CMD(CHIP, .cs_bindless = 0x1f));
}

void nmn_cmd_push(struct nw_cs *cs, unsigned stage, uint32_t first_vec4, const void *data, uint32_t vec4s)
{
	gl_shader_stage s = stage == 0 ? MESA_SHADER_VERTEX : stage == 1 ? MESA_SHADER_FRAGMENT : MESA_SHADER_COMPUTE;
	if (vec4s == 0)
		return;
	pkt7(cs, stage_opcode(s), 3 + vec4s * 4);
	nw_cs_emit(cs, CP_LOAD_STATE6_0_DST_OFF(first_vec4) | CP_LOAD_STATE6_0_STATE_TYPE(ST6_CONSTANTS) | CP_LOAD_STATE6_0_STATE_SRC(SS6_DIRECT) | CP_LOAD_STATE6_0_STATE_BLOCK(stage_shader_block(s)) | CP_LOAD_STATE6_0_NUM_UNIT(vec4s));
	nw_cs_emit(cs, 0);
	nw_cs_emit(cs, 0);
	memcpy(cs->cur, data, vec4s * 16);
	cs->cur += vec4s * 4;
}

void nmn_cmd_vertex_buffers(struct nw_cs *cs, const uint64_t *iova, const uint32_t *size, const uint32_t *stride, uint32_t count)
{
	if (count == 0)
		return;
	pkt4(cs, REG_A6XX_VFD_FETCH_BASE(0), count * 4);
	for (uint32_t i = 0; i < count; i++) {
		nw_cs_emit_qw(cs, iova[i]);
		nw_cs_emit(cs, size[i]);
		nw_cs_emit(cs, stride[i]);
	}
}

static enum pc_di_primtype primtype(uint32_t metal)
{
	/* MTLPrimitiveType: point, line, line strip, triangle, triangle strip */
	switch (metal) {
	case 0: return DI_PT_POINTLIST;
	case 1: return DI_PT_LINELIST;
	case 2: return DI_PT_LINESTRIP;
	case 4: return DI_PT_TRISTRIP;
	default: return DI_PT_TRILIST;
	}
}

void nmn_cmd_draw(struct nw_cs *cs, uint32_t primitive, uint32_t vertex_count, uint32_t instances, uint32_t first_vertex, uint32_t first_instance)
{
	REGS(cs, A6XX_VFD_INDEX_OFFSET(first_vertex), A6XX_VFD_INSTANCE_START_OFFSET(first_instance));
	REGS(cs, A6XX_PC_PRIMITIVE_CNTL_0(.primitive_restart = false));
	pkt7(cs, CP_DRAW_INDX_OFFSET, 3);
	nw_cs_emit(cs, CP_DRAW_INDX_OFFSET_0_PRIM_TYPE(primtype(primitive)) | CP_DRAW_INDX_OFFSET_0_SOURCE_SELECT(DI_SRC_SEL_AUTO_INDEX) | CP_DRAW_INDX_OFFSET_0_VIS_CULL(USE_VISIBILITY) | CP_DRAW_INDX_OFFSET_0_INDEX_SIZE(INDEX4_SIZE_32_BIT));
	nw_cs_emit(cs, instances);
	nw_cs_emit(cs, vertex_count);
}

void nmn_cmd_draw_indexed(struct nw_cs *cs, uint32_t primitive, uint32_t index_count, uint32_t instances, uint64_t index_iova, uint32_t index_max, bool wide, int32_t base_vertex, uint32_t first_instance)
{
	REGS(cs, A6XX_VFD_INDEX_OFFSET((uint32_t)base_vertex), A6XX_VFD_INSTANCE_START_OFFSET(first_instance));
	/* Metal has restart on for strips and it is always on the max index of the width */
	bool strip = primitive == 2 || primitive == 4;
	REGS(cs, A6XX_PC_PRIMITIVE_CNTL_0(.primitive_restart = strip));
	emit_reg(cs, REG_A6XX_PC_RESTART_INDEX, wide ? 0xffffffffu : 0xffffu);
	pkt7(cs, CP_DRAW_INDX_OFFSET, 7);
	nw_cs_emit(cs, CP_DRAW_INDX_OFFSET_0_PRIM_TYPE(primtype(primitive)) | CP_DRAW_INDX_OFFSET_0_SOURCE_SELECT(DI_SRC_SEL_DMA) | CP_DRAW_INDX_OFFSET_0_INDEX_SIZE(wide ? INDEX4_SIZE_32_BIT : INDEX4_SIZE_16_BIT) | CP_DRAW_INDX_OFFSET_0_VIS_CULL(USE_VISIBILITY));
	nw_cs_emit(cs, instances);
	nw_cs_emit(cs, index_count);
	nw_cs_emit(cs, 0);
	nw_cs_emit_qw(cs, index_iova);
	nw_cs_emit(cs, index_max);
}

void nmn_cmd_dispatch(struct nw_cs *cs, const struct nmn_baked *b, const uint32_t groups[3], const uint32_t local[3])
{
	nmn_cmd_program(cs, b);
	pkt4(cs, REG_A6XX_HLSQ_CS_NDRANGE_0, 7);
	nw_cs_emit(cs, A6XX_HLSQ_CS_NDRANGE_0_KERNELDIM(3) | A6XX_HLSQ_CS_NDRANGE_0_LOCALSIZEX(local[0] - 1) | A6XX_HLSQ_CS_NDRANGE_0_LOCALSIZEY(local[1] - 1) | A6XX_HLSQ_CS_NDRANGE_0_LOCALSIZEZ(local[2] - 1));
	nw_cs_emit(cs, local[0] * groups[0]);
	nw_cs_emit(cs, 0);
	nw_cs_emit(cs, local[1] * groups[1]);
	nw_cs_emit(cs, 0);
	nw_cs_emit(cs, local[2] * groups[2]);
	nw_cs_emit(cs, 0);
	REGS(cs, A6XX_HLSQ_CS_KERNEL_GROUP_X(1), A6XX_HLSQ_CS_KERNEL_GROUP_Y(1), A6XX_HLSQ_CS_KERNEL_GROUP_Z(1));
	pkt7(cs, CP_SET_MARKER, 1);
	nw_cs_emit(cs, A6XX_CP_SET_MARKER_0_MODE(RM6_COMPUTE));
	pkt7(cs, CP_EXEC_CS, 4);
	nw_cs_emit(cs, 0);
	nw_cs_emit(cs, CP_EXEC_CS_1_NGROUPS_X(groups[0]));
	nw_cs_emit(cs, CP_EXEC_CS_2_NGROUPS_Y(groups[1]));
	nw_cs_emit(cs, CP_EXEC_CS_3_NGROUPS_Z(groups[2]));
	wfi(cs);
}

/* ---- 2D copies: rows as Turnip's tu_CmdCopyBuffer (a 2D target of FMT6_8_UNORM, 64-byte aligned bases) ---- */
void nmn_cmd_copy_buffer(struct nw_cs *cs, uint64_t src, uint64_t dst, uint64_t bytes)
{
	r2d_common(cs, PIPE_FORMAT_R8_UNORM, FMT6_8_UNORM, R2D_UNORM8, false);
	while (bytes > 0) {
		uint32_t s = (uint32_t)(src & 0x3f), d = (uint32_t)(dst & 0x3f);
		uint32_t w = (uint32_t)MIN2(bytes, (uint64_t)(0x4000 - 0x40));
		REGS(cs, SP_PS_2D_SRC_INFO(CHIP, .color_format = FMT6_8_UNORM, .color_swap = WZYX, .unk20 = 1, .unk22 = 1), SP_PS_2D_SRC_SIZE(CHIP, .width = s + w, .height = 1), SP_PS_2D_SRC(CHIP, .qword = src - s), SP_PS_2D_SRC_PITCH(CHIP, .pitch = 0x40));
		REGS(cs, A6XX_RB_2D_DST_INFO(.color_format = FMT6_8_UNORM, .color_swap = WZYX), A6XX_RB_2D_DST(.qword = dst - d), A6XX_RB_2D_DST_PITCH(0x4000));
		REGS(cs, A6XX_GRAS_2D_DST_TL(.x = d, .y = 0), A6XX_GRAS_2D_DST_BR(.x = d + w - 1, .y = 0));
		REGS(cs, A6XX_GRAS_2D_SRC_TL_X(s), A6XX_GRAS_2D_SRC_BR_X(s + w - 1), A6XX_GRAS_2D_SRC_TL_Y(0), A6XX_GRAS_2D_SRC_BR_Y(0));
		pkt7(cs, CP_BLIT, 1);
		nw_cs_emit(cs, CP_BLIT_0_OP(BLIT_OP_SCALE));
		src += w;
		dst += w;
		bytes -= w;
	}
	flush_color(cs);
}

void nmn_cmd_fill_buffer(struct nw_cs *cs, uint64_t dst, uint64_t bytes, uint8_t value)
{
	r2d_common(cs, PIPE_FORMAT_R8_UNORM, FMT6_8_UNORM, R2D_UNORM8, true);
	pkt4(cs, REG_A6XX_RB_2D_SRC_SOLID_C0, 4);
	nw_cs_emit(cs, value);
	nw_cs_emit(cs, 0);
	nw_cs_emit(cs, 0);
	nw_cs_emit(cs, 0);
	while (bytes > 0) {
		uint32_t d = (uint32_t)(dst & 0x3f);
		uint32_t w = (uint32_t)MIN2(bytes, (uint64_t)(0x4000 - 0x40));
		REGS(cs, A6XX_RB_2D_DST_INFO(.color_format = FMT6_8_UNORM, .color_swap = WZYX), A6XX_RB_2D_DST(.qword = dst - d), A6XX_RB_2D_DST_PITCH(0x4000));
		REGS(cs, A6XX_GRAS_2D_DST_TL(.x = d, .y = 0), A6XX_GRAS_2D_DST_BR(.x = d + w - 1, .y = 0));
		pkt7(cs, CP_BLIT, 1);
		nw_cs_emit(cs, CP_BLIT_0_OP(BLIT_OP_SCALE));
		dst += w;
		bytes -= w;
	}
	flush_color(cs);
}

static void r2d_src_image(struct nw_cs *cs, const struct nmn_image *im, uint32_t level, uint32_t layer)
{
	enum pipe_format f = (enum pipe_format)im->format;
	enum a6xx_tile_mode tile = tile_of(&im->layout, level);
	REGS(cs, SP_PS_2D_SRC_INFO(CHIP, .color_format = fd6_color_format(f, tile), .tile_mode = tile, .color_swap = fd6_color_swap(f, tile, false), .srgb = util_format_is_srgb(f), .unk20 = 1, .unk22 = 1),
	     SP_PS_2D_SRC_SIZE(CHIP, .width = u_minify(im->layout.width0, level), .height = u_minify(im->layout.height0, level)),
	     SP_PS_2D_SRC(CHIP, .qword = im->iova + fdl_surface_offset(&im->layout, level, layer)),
	     SP_PS_2D_SRC_PITCH(CHIP, .pitch = fdl_pitch(&im->layout, level)));
}

void nmn_cmd_copy_image(struct nw_cs *cs, const struct nmn_image *src, uint32_t sl, uint32_t slayer, const uint32_t so[2], const struct nmn_image *dst, uint32_t dl, uint32_t dlayer, const uint32_t dor[2], const uint32_t size[2])
{
	enum pipe_format f = (enum pipe_format)dst->format;
	enum a6xx_tile_mode tile = tile_of(&dst->layout, dl);
	enum a6xx_format fmt = fd6_color_format(f, tile);
	r2d_common(cs, f, fmt, format_ifmt(f), false);
	r2d_src_image(cs, src, sl, slayer);
	r2d_dst_image(cs, dst, dl, dlayer, f, fmt);
	REGS(cs, A6XX_GRAS_2D_DST_TL(.x = dor[0], .y = dor[1]), A6XX_GRAS_2D_DST_BR(.x = dor[0] + size[0] - 1, .y = dor[1] + size[1] - 1));
	REGS(cs, A6XX_GRAS_2D_SRC_TL_X(so[0]), A6XX_GRAS_2D_SRC_BR_X(so[0] + size[0] - 1), A6XX_GRAS_2D_SRC_TL_Y(so[1]), A6XX_GRAS_2D_SRC_BR_Y(so[1] + size[1] - 1));
	pkt7(cs, CP_BLIT, 1);
	nw_cs_emit(cs, CP_BLIT_0_OP(BLIT_OP_SCALE));
	flush_color(cs);
}

void nmn_cmd_buffer_to_image(struct nw_cs *cs, uint64_t src, uint32_t pitch, const struct nmn_image *dst, uint32_t level, uint32_t layer, const uint32_t o[2], const uint32_t size[2])
{
	enum pipe_format f = (enum pipe_format)dst->format;
	enum a6xx_tile_mode tile = tile_of(&dst->layout, level);
	enum a6xx_format fmt = fd6_color_format(f, tile);
	uint32_t cpp = util_format_get_blocksize(f);
	uint64_t base = src & ~0x3full;
	uint32_t sx = (uint32_t)(src - base) / cpp;
	r2d_common(cs, f, fmt, format_ifmt(f), false);
	REGS(cs, SP_PS_2D_SRC_INFO(CHIP, .color_format = fd6_color_format(f, TILE6_LINEAR), .color_swap = fd6_color_swap(f, TILE6_LINEAR, false), .srgb = util_format_is_srgb(f), .unk20 = 1, .unk22 = 1), SP_PS_2D_SRC_SIZE(CHIP, .width = sx + size[0], .height = size[1]), SP_PS_2D_SRC(CHIP, .qword = base), SP_PS_2D_SRC_PITCH(CHIP, .pitch = pitch));
	r2d_dst_image(cs, dst, level, layer, f, fmt);
	REGS(cs, A6XX_GRAS_2D_DST_TL(.x = o[0], .y = o[1]), A6XX_GRAS_2D_DST_BR(.x = o[0] + size[0] - 1, .y = o[1] + size[1] - 1));
	REGS(cs, A6XX_GRAS_2D_SRC_TL_X(sx), A6XX_GRAS_2D_SRC_BR_X(sx + size[0] - 1), A6XX_GRAS_2D_SRC_TL_Y(0), A6XX_GRAS_2D_SRC_BR_Y(size[1] - 1));
	pkt7(cs, CP_BLIT, 1);
	nw_cs_emit(cs, CP_BLIT_0_OP(BLIT_OP_SCALE));
	flush_color(cs);
}

void nmn_cmd_image_to_buffer(struct nw_cs *cs, const struct nmn_image *src, uint32_t level, uint32_t layer, const uint32_t o[2], const uint32_t size[2], uint64_t dst, uint32_t pitch)
{
	enum pipe_format f = (enum pipe_format)src->format;
	enum a6xx_format fmt = fd6_color_format(f, TILE6_LINEAR);
	uint32_t cpp = util_format_get_blocksize(f);
	uint64_t base = dst & ~0x3full;
	uint32_t dx = (uint32_t)(dst - base) / cpp;
	r2d_common(cs, f, fmt, format_ifmt(f), false);
	r2d_src_image(cs, src, level, layer);
	REGS(cs, A6XX_RB_2D_DST_INFO(.color_format = fmt, .color_swap = fd6_color_swap(f, TILE6_LINEAR, false), .srgb = util_format_is_srgb(f)), A6XX_RB_2D_DST(.qword = base), A6XX_RB_2D_DST_PITCH(pitch));
	REGS(cs, A6XX_GRAS_2D_DST_TL(.x = dx, .y = 0), A6XX_GRAS_2D_DST_BR(.x = dx + size[0] - 1, .y = size[1] - 1));
	REGS(cs, A6XX_GRAS_2D_SRC_TL_X(o[0]), A6XX_GRAS_2D_SRC_BR_X(o[0] + size[0] - 1), A6XX_GRAS_2D_SRC_TL_Y(o[1]), A6XX_GRAS_2D_SRC_BR_Y(o[1] + size[1] - 1));
	pkt7(cs, CP_BLIT, 1);
	nw_cs_emit(cs, CP_BLIT_0_OP(BLIT_OP_SCALE));
	flush_color(cs);
}

/* A value the CPU can poll, when the GPU has reached this point. */
void nmn_cmd_end_marker(struct nw_cs *cs, uint64_t iova, uint32_t value)
{
	pkt7(cs, CP_EVENT_WRITE, 4);
	nw_cs_emit(cs, CP_EVENT_WRITE_0_EVENT(RB_DONE_TS) | CP_EVENT_WRITE_0_TIMESTAMP);
	nw_cs_emit_qw(cs, iova);
	nw_cs_emit(cs, value);
}
