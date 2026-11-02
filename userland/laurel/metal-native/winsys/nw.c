/* SPDX-License-Identifier: MIT */
/* Native Metal stack, winsys. See nw.h. Structures: Mesa include/drm-uapi/msm_drm.h (MIT). Selectors: docs/gpu-abi.md section 4. */
#include "nw.h"
#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "drm-uapi/msm_drm.h"

#define NW_SEL(index) (0x40u + (index))
#define NW_SEL_GEM_CLOSE 0x09u
#define NW_SEL_USERPTR 0x49u
#define NW_SEL_SURFACE 0x7eu
#define NW_SAME_PLACE_BASE 0x80000000ull     /* kernel kSamePlaceBase: at or above it a kernel buffer is the pool's, at VA = PA */
#define NW_CHUNK_SIZE (256u * 1024u)
#define NW_FREE_LISTS 16

struct nw_slab {
	struct nw_bo *bo;
	struct nw_slab *next;
	struct nw_gap { uint64_t offset, size; } *gaps;
	uint32_t gap_count, gap_cap;
	uint64_t used;
};

struct nw_device {
	const struct nw_ops *ops;
	void *ctx;
	struct nw_info info;
	pthread_mutex_t lock;
	uint32_t stamp;
	struct nw_slab *slabs;
	struct nw_bo **free_chunks;
	uint32_t free_chunk_count, free_chunk_cap;
	/* freed large buffers by size class (power of two), for reuse with no kernel call */
	struct nw_bo **free_big[NW_FREE_LISTS];
	uint32_t free_big_count[NW_FREE_LISTS], free_big_cap[NW_FREE_LISTS];
	uint64_t bo_count, bo_bytes, slice_bytes, slice_count, list_hits;
};

static int get_param(struct nw_device *d, uint32_t param, uint64_t *value)
{
	struct drm_msm_param p = {.pipe = MSM_PIPE_3D0, .param = param};
	int e = d->ops->call(d->ctx, NW_SEL(DRM_MSM_GET_PARAM), &p, sizeof(p));
	if (e == 0)
		*value = p.value;
	return e;
}

struct nw_device *nw_device_open(const struct nw_ops *ops, void *ctx, char *why, size_t why_size)
{
	struct nw_device *d = calloc(1, sizeof(*d));
	uint64_t v;
	if (d == NULL) {
		snprintf(why, why_size, "no memory");
		return NULL;
	}
	d->ops = ops;
	d->ctx = ctx;
	pthread_mutex_init(&d->lock, NULL);
	static const struct { uint32_t param; const char *name; } need[] = {
		{MSM_PARAM_CHIP_ID, "CHIP_ID"}, {MSM_PARAM_GMEM_SIZE, "GMEM_SIZE"}, {MSM_PARAM_HIGHEST_BANK_BIT, "HIGHEST_BANK_BIT"},
		{MSM_PARAM_UBWC_SWIZZLE, "UBWC_SWIZZLE"}, {MSM_PARAM_MACROTILE_MODE, "MACROTILE_MODE"}, {MSM_PARAM_MAX_FREQ, "MAX_FREQ"},
	};
	uint64_t got[6];
	for (unsigned i = 0; i < 6; i++) {
		int e = get_param(d, need[i].param, &got[i]);
		if (e != 0) {
			snprintf(why, why_size, "GET_PARAM %s: errno %d", need[i].name, e);
			pthread_mutex_destroy(&d->lock);
			free(d);
			return NULL;
		}
	}
	d->info.chip_id = (uint32_t)got[0];
	d->info.gmem_size = (uint32_t)got[1];
	d->info.highest_bank_bit = (uint32_t)got[2];
	d->info.ubwc_swizzle = (uint32_t)got[3];
	d->info.macrotile_mode = (uint32_t)got[4];
	d->info.max_freq = got[5];
	/* optional: an answer of 0 means the kernel chooses every address, as it does on this phone */
	if (get_param(d, MSM_PARAM_VA_START, &v) == 0)
		d->info.va_start = v;
	if (get_param(d, MSM_PARAM_VA_SIZE, &v) == 0)
		d->info.va_size = v;
	d->info.max_buffer = 48ull << 20;   /* below a pool chunk: kernel GPU_BUFFER_MAX, larger goes to scattered pages */
	return d;
}

const struct nw_info *nw_device_info(const struct nw_device *d) { return &d->info; }

uint64_t nw_now_ns(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC_RAW, &t);
	return (uint64_t)t.tv_sec * 1000000000ull + (uint64_t)t.tv_nsec;
}

static int bo_iova(struct nw_device *d, uint32_t handle, uint64_t *iova)
{
	struct drm_msm_gem_info r = {.handle = handle, .info = MSM_INFO_GET_IOVA};
	int e = d->ops->call(d->ctx, NW_SEL(DRM_MSM_GEM_INFO), &r, sizeof(r));
	if (e == 0)
		*iova = r.value;
	return e;
}

static void bo_close_handle(struct nw_device *d, uint32_t handle)
{
	struct { uint32_t handle, pad; } r = {handle, 0};
	d->ops->call(d->ctx, NW_SEL_GEM_CLOSE, &r, sizeof(r));
}

struct nw_bo *nw_bo_new(struct nw_device *d, uint64_t size, uint32_t flags)
{
	struct drm_msm_gem_new r = {.size = size, .flags = flags ? flags : MSM_BO_WC};
	struct nw_bo *b;
	if (d->ops->call(d->ctx, NW_SEL(DRM_MSM_GEM_NEW), &r, sizeof(r)) != 0)
		return NULL;
	b = calloc(1, sizeof(*b));
	if (b == NULL)
		goto bad;
	b->handle = r.handle;
	b->size = size;
	if (bo_iova(d, r.handle, &b->iova) != 0)
		goto bad;
	b->kind = b->iova >= NW_SAME_PLACE_BASE ? NW_BO_POOL : NW_BO_SCATTERED;
	b->map = d->ops->map(d->ctx, r.handle, size);
	if (b->map == NULL)
		goto bad;
	pthread_mutex_lock(&d->lock);
	d->bo_count++;
	d->bo_bytes += size;
	pthread_mutex_unlock(&d->lock);
	return b;
bad:
	bo_close_handle(d, r.handle);
	free(b);
	return NULL;
}

/* struct redwood_drm_surface, userland/negronigl/drm/xf86drm.h */
struct nw_surface_request {
	uint32_t surface, handle;
	uint64_t size;
	uint32_t offset, row_bytes, width, height, pixel_format, planes;
};

struct nw_bo *nw_bo_import_surface(struct nw_device *d, uint32_t surface_id, uint32_t *offset, uint32_t *row_bytes)
{
	struct nw_surface_request r = {.surface = surface_id, .handle = 0};
	struct nw_bo *b;
	if (d->ops->call(d->ctx, NW_SEL_SURFACE, &r, sizeof(r)) != 0)
		return NULL;
	b = calloc(1, sizeof(*b));
	if (b == NULL || bo_iova(d, r.handle, &b->iova) != 0) {
		bo_close_handle(d, r.handle);
		free(b);
		return NULL;
	}
	b->handle = r.handle;
	b->size = r.size;
	b->kind = NW_BO_SURFACE;
	if (offset != NULL)
		*offset = r.offset;
	if (row_bytes != NULL)
		*row_bytes = r.row_bytes;
	pthread_mutex_lock(&d->lock);
	d->bo_count++;
	pthread_mutex_unlock(&d->lock);
	return b;
}

struct nw_userptr_request {
	uint64_t pointer, size;
	uint32_t flags, handle;
};

struct nw_bo *nw_bo_import_host(struct nw_device *d, void *pointer, uint64_t size, bool read_only)
{
	struct nw_userptr_request r = {.pointer = (uint64_t)(uintptr_t)pointer, .size = size, .flags = read_only ? 1u : 0u};
	struct nw_bo *b;
	if (d->ops->call(d->ctx, NW_SEL_USERPTR, &r, sizeof(r)) != 0)
		return NULL;
	b = calloc(1, sizeof(*b));
	if (b == NULL || bo_iova(d, r.handle, &b->iova) != 0) {
		bo_close_handle(d, r.handle);
		free(b);
		return NULL;
	}
	b->handle = r.handle;
	b->size = size;
	b->kind = NW_BO_HOST;
	b->map = pointer;
	pthread_mutex_lock(&d->lock);
	d->bo_count++;
	pthread_mutex_unlock(&d->lock);
	return b;
}

void nw_bo_free(struct nw_device *d, struct nw_bo *b)
{
	if (b == NULL)
		return;
	if (b->map != NULL && b->kind != NW_BO_HOST)
		d->ops->unmap(d->ctx, b->handle, b->map, b->size);
	bo_close_handle(d, b->handle);
	pthread_mutex_lock(&d->lock);
	d->bo_count--;
	if (b->kind == NW_BO_POOL || b->kind == NW_BO_SCATTERED)
		d->bo_bytes -= b->size;
	pthread_mutex_unlock(&d->lock);
	free(b);
}

void nw_device_close(struct nw_device *d)
{
	if (d == NULL)
		return;
	for (struct nw_slab *s = d->slabs, *n; s != NULL; s = n) {
		n = s->next;
		nw_bo_free(d, s->bo);
		free(s->gaps);
		free(s);
	}
	for (uint32_t i = 0; i < d->free_chunk_count; i++)
		nw_bo_free(d, d->free_chunks[i]);
	free(d->free_chunks);
	for (unsigned c = 0; c < NW_FREE_LISTS; c++) {
		for (uint32_t i = 0; i < d->free_big_count[c]; i++)
			nw_bo_free(d, d->free_big[c][i]);
		free(d->free_big[c]);
	}
	pthread_mutex_destroy(&d->lock);
	free(d);
}

/* ---- slices: first fit in slabs; a freed slice joins its neighbours ---- */

static bool gap_insert(struct nw_slab *s, uint32_t at, uint64_t offset, uint64_t size)
{
	if (s->gap_count == s->gap_cap) {
		uint32_t cap = s->gap_cap ? s->gap_cap * 2 : 16;
		struct nw_gap *g = realloc(s->gaps, cap * sizeof(*g));
		if (g == NULL)
			return false;
		s->gaps = g;
		s->gap_cap = cap;
	}
	memmove(&s->gaps[at + 1], &s->gaps[at], (s->gap_count - at) * sizeof(*s->gaps));
	s->gaps[at].offset = offset;
	s->gaps[at].size = size;
	s->gap_count++;
	return true;
}

static void gap_remove(struct nw_slab *s, uint32_t at)
{
	memmove(&s->gaps[at], &s->gaps[at + 1], (s->gap_count - at - 1) * sizeof(*s->gaps));
	s->gap_count--;
}

static bool slab_take(struct nw_slab *s, uint64_t size, uint64_t alignment, uint64_t *offset)
{
	for (uint32_t i = 0; i < s->gap_count; i++) {
		struct nw_gap g = s->gaps[i];
		uint64_t at = (g.offset + alignment - 1) & ~(alignment - 1);
		uint64_t head = at - g.offset;
		if (head + size > g.size)
			continue;
		uint64_t tail = g.size - head - size;
		if (head != 0 && tail != 0) {
			/* one gap becomes two: needs a free entry first, so a failure changes nothing */
			if (!gap_insert(s, i + 1, at + size, tail))
				continue;
			s->gaps[i].size = head;
		} else if (head != 0) {
			s->gaps[i].size = head;
		} else if (tail != 0) {
			s->gaps[i].offset = at + size;
			s->gaps[i].size = tail;
		} else {
			gap_remove(s, i);
		}
		s->used += size;
		*offset = at;
		return true;
	}
	return false;
}

static void slab_give(struct nw_slab *s, uint64_t offset, uint64_t size)
{
	uint32_t i = 0;
	while (i < s->gap_count && s->gaps[i].offset < offset)
		i++;
	bool joins_prev = i > 0 && s->gaps[i - 1].offset + s->gaps[i - 1].size == offset;
	bool joins_next = i < s->gap_count && offset + size == s->gaps[i].offset;
	s->used -= size;
	if (joins_prev && joins_next) {
		s->gaps[i - 1].size += size + s->gaps[i].size;
		gap_remove(s, i);
	} else if (joins_prev) {
		s->gaps[i - 1].size += size;
	} else if (joins_next) {
		s->gaps[i].offset = offset;
		s->gaps[i].size += size;
	} else if (!gap_insert(s, i, offset, size)) {
		/* no memory for a list entry: these bytes stay out of use until the slab is freed. Nothing else depends on them. */
	}
}

static unsigned size_class(uint64_t size)
{
	unsigned c = 0;
	for (uint64_t v = NW_SLICE_MAX; v < size && c + 1 < NW_FREE_LISTS; v <<= 1)
		c++;
	return c;
}

bool nw_slice_new(struct nw_device *d, uint64_t size, uint64_t alignment, struct nw_slice *out)
{
	if (alignment == 0)
		alignment = 64;
	if (size == 0 || (alignment & (alignment - 1)) != 0)
		return false;
	size = (size + 63) & ~63ull;
	memset(out, 0, sizeof(*out));
	if (size > NW_SLICE_MAX || alignment > 65536) {
		/* its own kernel buffer: from the list of freed ones when the class has one that is large enough */
		uint64_t whole = (size + 4095) & ~4095ull;
		unsigned c = size_class(whole);
		struct nw_bo *b = NULL;
		pthread_mutex_lock(&d->lock);
		for (uint32_t i = d->free_big_count[c]; i-- > 0;) {
			struct nw_bo *o = d->free_big[c][i];
			if (o->size >= whole && o->size <= whole * 2 && (o->iova & (alignment - 1)) == 0) {
				d->free_big[c][i] = d->free_big[c][--d->free_big_count[c]];
				b = o;
				d->list_hits++;
				break;
			}
		}
		pthread_mutex_unlock(&d->lock);
		if (b == NULL)
			b = nw_bo_new(d, whole, MSM_BO_WC);
		if (b == NULL)
			return false;
		out->bo = b;
		out->size = size;
		out->iova = b->iova;
		out->map = b->map;
		pthread_mutex_lock(&d->lock);
		d->slice_bytes += b->size;
		d->slice_count++;
		pthread_mutex_unlock(&d->lock);
		return true;
	}
	pthread_mutex_lock(&d->lock);
	for (struct nw_slab *s = d->slabs; s != NULL; s = s->next) {
		uint64_t offset;
		if (slab_take(s, size, alignment, &offset)) {
			out->bo = s->bo;
			out->offset = offset;
			out->size = size;
			out->iova = s->bo->iova + offset;
			out->map = (char *)s->bo->map + offset;
			out->slab = s;
			d->slice_bytes += size;
			d->slice_count++;
			pthread_mutex_unlock(&d->lock);
			return true;
		}
	}
	pthread_mutex_unlock(&d->lock);
	struct nw_bo *b = nw_bo_new(d, NW_SLAB_SIZE, MSM_BO_WC);
	struct nw_slab *s = calloc(1, sizeof(*s));
	uint64_t offset;
	if (b == NULL || s == NULL || !gap_insert(s, 0, 0, NW_SLAB_SIZE)) {
		nw_bo_free(d, b);
		if (s != NULL)
			free(s->gaps);
		free(s);
		return false;
	}
	s->bo = b;
	pthread_mutex_lock(&d->lock);
	bool ok = slab_take(s, size, alignment, &offset);
	s->next = d->slabs;
	d->slabs = s;
	if (ok) {
		d->slice_bytes += size;
		d->slice_count++;
	}
	pthread_mutex_unlock(&d->lock);
	if (!ok)
		return false;
	out->bo = b;
	out->offset = offset;
	out->size = size;
	out->iova = b->iova + offset;
	out->map = (char *)b->map + offset;
	out->slab = s;
	return true;
}

void nw_slice_free(struct nw_device *d, struct nw_slice *x)
{
	if (x->bo == NULL)
		return;
	pthread_mutex_lock(&d->lock);
	d->slice_count--;
	if (x->slab != NULL) {
		d->slice_bytes -= x->size;
		slab_give(x->slab, x->offset, x->size);
		pthread_mutex_unlock(&d->lock);
	} else {
		unsigned c = size_class(x->bo->size);
		d->slice_bytes -= x->bo->size;
		if (x->bo->size < (32ull << 20) && d->free_big_count[c] < 8) {
			if (d->free_big_count[c] == d->free_big_cap[c]) {
				uint32_t cap = d->free_big_cap[c] ? d->free_big_cap[c] * 2 : 8;
				struct nw_bo **l = realloc(d->free_big[c], cap * sizeof(*l));
				if (l != NULL) {
					d->free_big[c] = l;
					d->free_big_cap[c] = cap;
				}
			}
			if (d->free_big_count[c] < d->free_big_cap[c]) {
				d->free_big[c][d->free_big_count[c]++] = x->bo;
				x->bo = NULL;
			}
		}
		pthread_mutex_unlock(&d->lock);
		if (x->bo != NULL)
			nw_bo_free(d, x->bo);
	}
	memset(x, 0, sizeof(*x));
}

void nw_memory_stats(const struct nw_device *dc, uint64_t out[5])
{
	struct nw_device *d = (struct nw_device *)dc;
	pthread_mutex_lock(&d->lock);
	out[0] = d->bo_count;
	out[1] = d->bo_bytes;
	out[2] = d->slice_bytes;
	out[3] = d->slice_count;
	out[4] = d->list_hits;
	pthread_mutex_unlock(&d->lock);
}

/* ---- command streams ---- */

static struct nw_bo *chunk_new(struct nw_device *d)
{
	struct nw_bo *b = NULL;
	pthread_mutex_lock(&d->lock);
	if (d->free_chunk_count > 0)
		b = d->free_chunks[--d->free_chunk_count];
	pthread_mutex_unlock(&d->lock);
	return b != NULL ? b : nw_bo_new(d, NW_CHUNK_SIZE, MSM_BO_WC);
}

static void chunk_give(struct nw_device *d, struct nw_bo *b)
{
	pthread_mutex_lock(&d->lock);
	if (d->free_chunk_count == d->free_chunk_cap) {
		uint32_t cap = d->free_chunk_cap ? d->free_chunk_cap * 2 : 16;
		struct nw_bo **l = realloc(d->free_chunks, cap * sizeof(*l));
		if (l == NULL) {
			pthread_mutex_unlock(&d->lock);
			nw_bo_free(d, b);
			return;
		}
		d->free_chunks = l;
		d->free_chunk_cap = cap;
	}
	d->free_chunks[d->free_chunk_count++] = b;
	pthread_mutex_unlock(&d->lock);
}

void nw_cs_init(struct nw_cs *cs, struct nw_device *d)
{
	memset(cs, 0, sizeof(*cs));
	cs->dev = d;
}

void nw_cs_reset(struct nw_cs *cs)
{
	for (uint32_t i = 0; i < cs->chunk_count; i++)
		chunk_give(cs->dev, cs->chunks[i]);
	cs->chunk_count = 0;
	cs->ib_count = 0;
	cs->cur = cs->end = cs->start = NULL;
	cs->bo = NULL;
	cs->failed = false;
}

void nw_cs_finish(struct nw_cs *cs)
{
	nw_cs_reset(cs);
	free(cs->chunks);
	free(cs->ibs);
	cs->chunks = NULL;
	cs->ibs = NULL;
	cs->chunk_cap = cs->ib_cap = 0;
}

void nw_cs_end_ib(struct nw_cs *cs)
{
	if (cs->bo == NULL || cs->cur == cs->start)
		return;
	if (cs->ib_count == cs->ib_cap) {
		uint32_t cap = cs->ib_cap ? cs->ib_cap * 2 : 8;
		struct nw_ib *n = realloc(cs->ibs, cap * sizeof(*n));
		if (n == NULL) {
			cs->failed = true;
			return;
		}
		cs->ibs = n;
		cs->ib_cap = cap;
	}
	struct nw_ib *ib = &cs->ibs[cs->ib_count++];
	ib->iova = cs->start_iova;
	ib->dwords = (uint32_t)(cs->cur - cs->start);
	ib->bo = cs->bo;
	ib->offset = (uint32_t)(cs->start_iova - cs->bo->iova);
	cs->start_iova = nw_cs_iova(cs);
	cs->start = cs->cur;
}

/* Scratch for a stream that lost its memory: its words go nowhere and cs->failed fails the submit. Never reaches the GPU. */
static uint32_t nw_cs_lost[1u << 20];

void nw_cs_grow(struct nw_cs *cs, uint32_t dwords)
{
	nw_cs_end_ib(cs);
	if (cs->chunk_count == cs->chunk_cap) {
		uint32_t cap = cs->chunk_cap ? cs->chunk_cap * 2 : 8;
		struct nw_bo **n = realloc(cs->chunks, cap * sizeof(*n));
		if (n == NULL)
			goto lost;
		cs->chunks = n;
		cs->chunk_cap = cap;
	}
	if (dwords > NW_CHUNK_SIZE / 4)
		goto lost;
	struct nw_bo *b = chunk_new(cs->dev);
	if (b == NULL)
		goto lost;
	cs->chunks[cs->chunk_count++] = b;
	cs->bo = b;
	cs->start = cs->cur = b->map;
	cs->end = cs->start + NW_CHUNK_SIZE / 4;
	cs->start_iova = b->iova;
	return;
lost:
	cs->failed = true;
	cs->bo = NULL;
	cs->start = cs->cur = nw_cs_lost;
	cs->end = nw_cs_lost + sizeof(nw_cs_lost) / 4;
	cs->start_iova = 0;
}

/* ---- submission ---- */

void nw_submit_begin(struct nw_submit *s, struct nw_device *d)
{
	memset(s, 0, sizeof(*s));
	s->dev = d;
	pthread_mutex_lock(&d->lock);
	s->stamp = ++d->stamp;
	if (s->stamp == 0)
		s->stamp = ++d->stamp;
	pthread_mutex_unlock(&d->lock);
}

void nw_submit_name(struct nw_submit *s, struct nw_bo *b)
{
	if (b->list_stamp == s->stamp)
		return;
	if (s->name_count == s->name_cap) {
		uint32_t cap = s->name_cap ? s->name_cap * 2 : 32;
		struct nw_bo **n = realloc(s->names, cap * sizeof(*n));
		if (n == NULL)
			return;         /* nw_submit_go sees the short list below */
		s->names = n;
		s->name_cap = cap;
	}
	b->list_stamp = s->stamp;
	b->list_index = s->name_count;
	s->names[s->name_count++] = b;
}

void nw_submit_stream(struct nw_submit *s, struct nw_cs *cs)
{
	if (s->stream_count == s->stream_cap) {
		uint32_t cap = s->stream_cap ? s->stream_cap * 2 : 8;
		struct nw_cs **n = realloc(s->streams, cap * sizeof(*n));
		if (n == NULL)
			return;
		s->streams = n;
		s->stream_cap = cap;
	}
	s->streams[s->stream_count++] = cs;
	for (uint32_t i = 0; i < cs->chunk_count; i++)
		nw_submit_name(s, cs->chunks[i]);
}

int nw_submit_go(struct nw_submit *s, uint32_t *fence)
{
	uint32_t ibs = 0;
	for (uint32_t i = 0; i < s->stream_count; i++) {
		if (s->streams[i]->failed)
			return ENOMEM;
		ibs += s->streams[i]->ib_count;
	}
	if (ibs == 0 || ibs > NW_SUBMIT_MAX_IBS || s->name_count == 0 || s->name_count > NW_SUBMIT_MAX_NAMES)
		return EINVAL;
	/* a stream's chunks were listed when it joined; one that grew after that is listed here */
	for (uint32_t i = 0; i < s->stream_count; i++)
		for (uint32_t j = 0; j < s->streams[i]->chunk_count; j++)
			nw_submit_name(s, s->streams[i]->chunks[j]);
	struct drm_msm_gem_submit_bo *bos = calloc(s->name_count, sizeof(*bos));
	struct drm_msm_gem_submit_cmd *cmds = calloc(ibs, sizeof(*cmds));
	int e = ENOMEM;
	if (bos != NULL && cmds != NULL) {
		for (uint32_t i = 0; i < s->name_count; i++) {
			bos[i].handle = s->names[i]->handle;
			bos[i].flags = MSM_SUBMIT_BO_READ | MSM_SUBMIT_BO_WRITE;
			bos[i].presumed = s->names[i]->iova;
		}
		uint32_t c = 0;
		for (uint32_t i = 0; i < s->stream_count; i++) {
			for (uint32_t j = 0; j < s->streams[i]->ib_count; j++) {
				const struct nw_ib *ib = &s->streams[i]->ibs[j];
				cmds[c].type = MSM_SUBMIT_CMD_BUF;
				cmds[c].submit_idx = ib->bo->list_index;
				cmds[c].submit_offset = ib->offset;
				cmds[c].size = ib->dwords * 4;
				c++;
			}
		}
		struct drm_msm_gem_submit r = {
			.flags = MSM_PIPE_3D0 | MSM_SUBMIT_NO_IMPLICIT,
			.nr_bos = s->name_count,
			.nr_cmds = ibs,
			.bos = (uint64_t)(uintptr_t)bos,
			.cmds = (uint64_t)(uintptr_t)cmds,
			.queueid = 0,
		};
		e = s->dev->ops->call(s->dev->ctx, NW_SEL(DRM_MSM_GEM_SUBMIT), &r, sizeof(r));
		if (e == 0) {
			*fence = r.fence;
			for (uint32_t i = 0; i < s->name_count; i++)
				s->names[i]->fence = r.fence;
		}
	}
	free(bos);
	free(cmds);
	return e;
}

void nw_submit_end(struct nw_submit *s)
{
	free(s->names);
	free(s->streams);
	memset(s, 0, sizeof(*s));
}

int nw_fence_wait(struct nw_device *d, uint32_t fence, uint64_t timeout_ns)
{
	uint64_t at = nw_now_ns() + timeout_ns;
	struct drm_msm_wait_fence w = {.fence = fence};
	w.timeout.tv_sec = (int64_t)(at / 1000000000ull);
	w.timeout.tv_nsec = (int64_t)(at % 1000000000ull);
	return d->ops->call(d->ctx, NW_SEL(DRM_MSM_WAIT_FENCE), &w, sizeof(w));
}

int nw_bo_cpu_prep(struct nw_device *d, struct nw_bo *b)
{
	uint64_t at = nw_now_ns() + 5000000000ull;
	struct drm_msm_gem_cpu_prep r = {.handle = b->handle, .op = MSM_PREP_READ};
	r.timeout.tv_sec = (int64_t)(at / 1000000000ull);
	r.timeout.tv_nsec = (int64_t)(at % 1000000000ull);
	return d->ops->call(d->ctx, NW_SEL(DRM_MSM_GEM_CPU_PREP), &r, sizeof(r));
}
