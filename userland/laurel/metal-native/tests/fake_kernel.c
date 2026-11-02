/* SPDX-License-Identifier: MIT */
/* See fake_kernel.h. */
#include "fake_kernel.h"
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "drm-uapi/msm_drm.h"
#include "redump.h"

struct fake_bo {
	uint32_t handle;
	uint64_t iova, size;
	void *mem;
	int host;
	int live;
};

struct fake_surface {
	uint64_t size;
	void *mem;
	uint32_t width, height, row_bytes, fourcc;
};

struct fake_kernel {
	struct fake_bo *bos;
	uint32_t bo_count, bo_cap;
	struct fake_surface surfaces[64];
	uint32_t surface_count;
	uint64_t next_pool, pool_end, next_scattered;
	uint32_t fence;
	FILE *rd;
	struct fake_stats stats;
};

struct fake_kernel *fake_kernel_new(const char *rd_path, uint64_t pool_bytes)
{
	struct fake_kernel *k = calloc(1, sizeof(*k));
	k->next_pool = 0x80000000ull;
	k->pool_end = k->next_pool + pool_bytes;
	k->next_scattered = 0x10000000ull;
	if (rd_path != NULL)
		k->rd = fopen(rd_path, "wb");
	return k;
}

void fake_kernel_free(struct fake_kernel *k)
{
	if (k->rd != NULL)
		fclose(k->rd);
	for (uint32_t i = 0; i < k->bo_count; i++)
		if (k->bos[i].live && !k->bos[i].host)
			free(k->bos[i].mem);
	for (uint32_t i = 0; i < k->surface_count; i++)
		free(k->surfaces[i].mem);
	free(k->bos);
	free(k);
}

const struct fake_stats *fake_kernel_stats(const struct fake_kernel *k) { return &k->stats; }

uint32_t fake_kernel_add_surface(struct fake_kernel *k, uint64_t size, uint32_t width, uint32_t height, uint32_t row_bytes, uint32_t fourcc)
{
	struct fake_surface *s = &k->surfaces[k->surface_count++];
	s->size = size;
	s->mem = aligned_alloc(4096, (size + 4095) & ~4095ull);
	memset(s->mem, 0, size);
	s->width = width;
	s->height = height;
	s->row_bytes = row_bytes;
	s->fourcc = fourcc;
	return k->surface_count;        /* ids from 1 */
}

static struct fake_bo *bo_at(struct fake_kernel *k, uint32_t handle)
{
	return handle >= 1 && handle <= k->bo_count && k->bos[handle - 1].live ? &k->bos[handle - 1] : NULL;
}

static struct fake_bo *bo_of_iova(struct fake_kernel *k, uint64_t iova, uint64_t bytes)
{
	for (uint32_t i = 0; i < k->bo_count; i++) {
		struct fake_bo *b = &k->bos[i];
		if (b->live && iova >= b->iova && iova + bytes <= b->iova + b->size)
			return b;
	}
	return NULL;
}

static struct fake_bo *bo_add(struct fake_kernel *k, uint64_t size, void *mem, int host, int pool)
{
	if (k->bo_count == k->bo_cap) {
		k->bo_cap = k->bo_cap ? k->bo_cap * 2 : 64;
		k->bos = realloc(k->bos, k->bo_cap * sizeof(*k->bos));
	}
	struct fake_bo *b = &k->bos[k->bo_count++];
	memset(b, 0, sizeof(*b));
	b->handle = k->bo_count;
	b->size = size;
	b->mem = mem;
	b->host = host;
	b->live = 1;
	if (pool) {
		b->iova = k->next_pool;
		k->next_pool += (size + 0xfff) & ~0xfffull;
	} else {
		b->iova = k->next_scattered;
		k->next_scattered += (size + 0xfff) & ~0xfffull;
	}
	return b;
}

static void rd_section(FILE *f, uint32_t type, const void *data, uint32_t size)
{
	fwrite(&type, 4, 1, f);
	fwrite(&size, 4, 1, f);
	fwrite(data, 1, size, f);
}

/* Parity and length of every packet, as the CP reads them; IB2 and draw states must lie in a live buffer. The count of opcodes is what cffdump would show; this walk fails a test at once, with no decoder. */
static void walk(struct fake_kernel *k, const uint32_t *p, uint32_t dwords, int level)
{
	for (uint32_t i = 0; i < dwords;) {
		uint32_t h = p[i], n;
		if ((h >> 28) == 4) {
			n = h & 0x7f;
			uint32_t reg = (h >> 8) & 0x3ffff;
			if (((h >> 7) & 1) != nw_odd_parity(n) || ((h >> 27) & 1) != nw_odd_parity(reg))
				k->stats.bad_parity++;
		} else if ((h >> 28) == 7) {
			n = h & 0x3fff;
			uint32_t op = (h >> 16) & 0x7f;
			if (((h >> 15) & 1) != nw_odd_parity(n) || ((h >> 23) & 1) != nw_odd_parity(op))
				k->stats.bad_parity++;
			if (op == 0x3f /* CP_INDIRECT_BUFFER */ && n == 3 && i + 3 < dwords) {
				uint64_t iova = p[i + 1] | ((uint64_t)p[i + 2] << 32);
				uint32_t size = p[i + 3];
				struct fake_bo *b = bo_of_iova(k, iova, (uint64_t)size * 4);
				if (b == NULL) {
					k->stats.bad_ib++;
				} else if (level < 2) {
					walk(k, (uint32_t *)((char *)b->mem + (iova - b->iova)), size, level + 1);
				}
			}
		} else {
			k->stats.unknown_opcode++;
			return;
		}
		i += 1 + n;
		if (i > dwords)
			k->stats.bad_ib++;
	}
}

static int do_submit(struct fake_kernel *k, struct drm_msm_gem_submit *r)
{
	const struct drm_msm_gem_submit_bo *bos = (void *)(uintptr_t)r->bos;
	const struct drm_msm_gem_submit_cmd *cmds = (void *)(uintptr_t)r->cmds;
	if (r->nr_cmds == 0 || r->nr_cmds > 128 || r->nr_bos == 0 || r->nr_bos > 8192)
		return EINVAL;
	for (uint32_t i = 0; i < r->nr_cmds; i++) {
		if (cmds[i].type != MSM_SUBMIT_CMD_BUF)
			continue;
		if (cmds[i].submit_idx >= r->nr_bos)
			return EINVAL;
		struct fake_bo *b = bo_at(k, bos[cmds[i].submit_idx].handle);
		if (b == NULL || cmds[i].nr_relocs != 0 || (cmds[i].size & 3) || (cmds[i].submit_offset & 3) || (uint64_t)cmds[i].submit_offset + cmds[i].size > b->size)
			return EINVAL;
	}
	k->stats.submissions++;
	k->stats.ibs += r->nr_cmds;
	k->stats.names += r->nr_bos;
	for (uint32_t i = 0; i < r->nr_cmds; i++) {
		struct fake_bo *b = bo_at(k, bos[cmds[i].submit_idx].handle);
		walk(k, (uint32_t *)((char *)b->mem + cmds[i].submit_offset), cmds[i].size / 4, 1);
		k->stats.dwords += cmds[i].size / 4;
	}
	if (k->rd != NULL) {
		uint64_t chip = 0x06010000;
		rd_section(k->rd, RD_CHIP_ID, &chip, 8);
		rd_section(k->rd, RD_CMD, "nmn-fake", 9);
		for (uint32_t i = 0; i < k->bo_count; i++) {
			struct fake_bo *b = &k->bos[i];
			if (!b->live)
				continue;
			uint32_t a[3] = {(uint32_t)b->iova, (uint32_t)b->size, (uint32_t)(b->iova >> 32)};
			rd_section(k->rd, RD_GPUADDR, a, 12);
			rd_section(k->rd, RD_BUFFER_CONTENTS, b->mem, (uint32_t)b->size);
		}
		for (uint32_t i = 0; i < r->nr_cmds; i++) {
			struct fake_bo *b = bo_at(k, bos[cmds[i].submit_idx].handle);
			uint64_t iova = b->iova + cmds[i].submit_offset;
			uint32_t a[3] = {(uint32_t)iova, cmds[i].size / 4, (uint32_t)(iova >> 32)};
			rd_section(k->rd, RD_CMDSTREAM_ADDR, a, 12);
		}
		fflush(k->rd);
	}
	r->fence = ++k->fence;
	return 0;
}

static int fake_call(void *ctx, uint32_t sel, void *data, size_t size)
{
	struct fake_kernel *k = ctx;
	switch (sel) {
	case 0x40: {
		struct drm_msm_param *p = data;
		switch (p->param) {
		case MSM_PARAM_CHIP_ID: p->value = 0x06010000; return 0;
		case MSM_PARAM_GMEM_SIZE: p->value = 132 * 1024; return 0;
		case MSM_PARAM_HIGHEST_BANK_BIT: p->value = 14; return 0;
		case MSM_PARAM_UBWC_SWIZZLE: p->value = 7; return 0;
		case MSM_PARAM_MACROTILE_MODE: p->value = 0; return 0;
		case MSM_PARAM_MAX_FREQ: p->value = 950000000; return 0;
		case MSM_PARAM_VA_START: p->value = 0; return 0;
		case MSM_PARAM_VA_SIZE: p->value = 1ull << 32; return 0;
		default: return EINVAL;
		}
	}
	case 0x42: {
		struct drm_msm_gem_new *r = data;
		uint64_t whole = (r->size + 4095) & ~4095ull;
		void *mem = aligned_alloc(4096, whole);
		if (mem == NULL)
			return ENOMEM;
		memset(mem, 0, whole);
		int pool = k->next_pool + whole <= k->pool_end;
		struct fake_bo *b = bo_add(k, whole, mem, 0, pool);
		r->handle = b->handle;
		k->stats.gem_new++;
		return 0;
	}
	case 0x43: {
		struct drm_msm_gem_info *r = data;
		struct fake_bo *b = bo_at(k, r->handle);
		if (b == NULL)
			return EINVAL;
		if (r->info == MSM_INFO_GET_IOVA) {
			r->value = b->iova;
			return 0;
		}
		return EINVAL;
	}
	case 0x44:
		return bo_at(k, ((struct drm_msm_gem_cpu_prep *)data)->handle) ? 0 : EINVAL;
	case 0x46:
		return do_submit(k, data);
	case 0x47:
		return ((struct drm_msm_wait_fence *)data)->fence <= k->fence ? 0 : EINVAL;
	case 0x09: {
		struct fake_bo *b = bo_at(k, *(uint32_t *)data);
		if (b == NULL)
			return EINVAL;
		if (!b->host)
			free(b->mem);
		b->live = 0;
		k->stats.gem_close++;
		return 0;
	}
	case 0x49: {
		struct { uint64_t pointer, size; uint32_t flags, handle; } *r = data;
		if (size != 24 || (r->pointer & 4095) || (r->size & 4095))
			return EINVAL;
		r->handle = bo_add(k, r->size, (void *)(uintptr_t)r->pointer, 1, 0)->handle;
		return 0;
	}
	case 0x7e: {
		struct { uint32_t surface, handle; uint64_t size; uint32_t offset, row_bytes, width, height, pixel_format, planes; } *r = data;
		if (r->surface == 0 || r->surface > k->surface_count)
			return ENOENT;
		struct fake_surface *s = &k->surfaces[r->surface - 1];
		r->handle = bo_add(k, s->size, s->mem, 1, 1)->handle;
		r->size = s->size;
		r->offset = 0;
		r->row_bytes = s->row_bytes;
		r->width = s->width;
		r->height = s->height;
		r->pixel_format = s->fourcc;
		r->planes = 0;
		k->stats.surfaces++;
		return 0;
	}
	default:
		return ENOSYS;
	}
}

static void *fake_map(void *ctx, uint32_t handle, uint64_t size)
{
	struct fake_bo *b = bo_at(ctx, handle);
	return b != NULL && size <= b->size ? b->mem : NULL;
}

static void fake_unmap(void *ctx, uint32_t handle, void *address, uint64_t size)
{
	(void)ctx; (void)handle; (void)address; (void)size;
}

const struct nw_ops fake_kernel_ops = {fake_call, fake_map, fake_unmap};
