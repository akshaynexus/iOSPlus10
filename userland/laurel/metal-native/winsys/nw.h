/* SPDX-License-Identifier: MIT */
/*
 * Native Metal stack, winsys: GPU buffers, one address space, command streams and submission on RedwoodGPU, with no Vulkan and no Mesa at run time.
 * The kernel's interface is the msm request set (docs/gpu-abi.md section 4; the laurel kernel: iokit/Kernel/arm/RedwoodGPU.cpp). The transport is a table of three calls, so the same code
 * runs on the phone (winsys_iokit.c) and on the build host against a fake kernel (tests/fake_kernel.c), which writes what it gets to a .rd file for Mesa's cffdump.
 *
 * What differs from Turnip on the same kernel, and why (docs/laurel_sprout/ios26-native-metal.md section 4):
 *  - A submission names only what the kernel must act on: its command buffers, IOSurfaces, scattered buffers the CPU has written. Turnip names every buffer of the device (881 to 1,537 a submission on the phone).
 *    The kernel uses a name for three things only: its CPU cache push, the fence of GEM_CLOSE and CPU_PREP, and the fence the display waits on. Lifetime of a buffer no submission names is the caller's: nw_slice_free after the GPU has passed the buffer's last fence.
 *  - Small resources share large buffers (nw_slice), so the kernel sees few handles.
 */
#ifndef NW_H
#define NW_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

/* The kernel, as a table. Each call answers 0 or a positive errno. */
struct nw_ops {
	int (*call)(void *ctx, uint32_t selector, void *data, size_t size);    /* the msm structure in and out */
	void *(*map)(void *ctx, uint32_t handle, uint64_t size);               /* NULL: refused */
	void (*unmap)(void *ctx, uint32_t handle, void *address, uint64_t size);
};

struct nw_info {
	uint32_t chip_id, gmem_size, highest_bank_bit, ubwc_swizzle, macrotile_mode;
	uint64_t max_freq, va_start, va_size, max_buffer;
};

enum nw_bo_kind {
	NW_BO_POOL = 0,         /* kernel memory the GPU reaches at VA = PA or in the pool: write-combined, no cache push (kernel 2154) */
	NW_BO_SCATTERED,        /* the pool was full: ordinary pages, cached; the kernel pushes them when they are named */
	NW_BO_SURFACE,          /* an IOSurface */
	NW_BO_HOST,             /* the caller's own pages (0x49); a name pushes the whole buffer, so name it only when the CPU wrote */
};

struct nw_bo {
	uint32_t handle;
	enum nw_bo_kind kind;
	uint64_t iova, size;
	void *map;              /* NULL until mapped; a host buffer's is the caller's */
	uint32_t fence;         /* the last submission that named it */
	/* the submit's list: this buffer's index in it, valid when stamp is the submit's */
	uint32_t list_index, list_stamp;
};

struct nw_device;

/* NULL: *why says why (the caller logs one line and turns the stack off). */
struct nw_device *nw_device_open(const struct nw_ops *ops, void *ctx, char *why, size_t why_size);
void nw_device_close(struct nw_device *);
const struct nw_info *nw_device_info(const struct nw_device *);

/* Whole kernel buffers. flags: MSM_BO_* (WC is the only cache mode we ask for). The buffer is mapped. */
struct nw_bo *nw_bo_new(struct nw_device *, uint64_t size, uint32_t flags);
struct nw_bo *nw_bo_import_surface(struct nw_device *, uint32_t surface_id, uint32_t *offset, uint32_t *row_bytes);
struct nw_bo *nw_bo_import_host(struct nw_device *, void *pointer, uint64_t size, bool read_only);
void nw_bo_free(struct nw_device *, struct nw_bo *);    /* the kernel waits up to 1 s for the fence of the last naming submission */

/* A piece of a shared buffer. Buffers and textures of up to NW_SLICE_MAX bytes live here; larger ones get a kernel buffer of their own, from a list of freed ones when one fits. */
#define NW_SLAB_SIZE    (4ull << 20)
#define NW_SLICE_MAX    (1ull << 20)
struct nw_slice {
	struct nw_bo *bo;
	uint64_t offset, size;
	uint64_t iova;
	void *map;
	struct nw_slab *slab;   /* NULL: bo is whole, and the list of freed buffers takes it back */
};
bool nw_slice_new(struct nw_device *, uint64_t size, uint64_t alignment, struct nw_slice *out);
void nw_slice_free(struct nw_device *, struct nw_slice *);
/* counters for one log line and the host test: kernel buffers now, bytes in them, bytes in use, slices, list hits */
void nw_memory_stats(const struct nw_device *, uint64_t out[5]);

/*
 * A command stream: dwords in write-combined memory. nw_cs_reserve never fails for the caller: a full chunk becomes one IB and a new chunk begins, so no packet crosses a chunk. A chunk with no memory sets `failed`, and the submit refuses the stream.
 * A finished stream is a list of IBs. Streams are reused after their fence.
 */
struct nw_cs {
	struct nw_device *dev;
	uint32_t *cur, *end, *start;
	struct nw_bo *bo;
	uint64_t start_iova;
	struct nw_ib {
		uint64_t iova;
		uint32_t dwords;
		struct nw_bo *bo;
		uint32_t offset;
	} *ibs;
	uint32_t ib_count, ib_cap;
	struct nw_bo **chunks;
	uint32_t chunk_count, chunk_cap;
	bool failed;
};
void nw_cs_init(struct nw_cs *, struct nw_device *);
void nw_cs_finish(struct nw_cs *);      /* gives its chunks back */
void nw_cs_reset(struct nw_cs *);       /* after the fence */
void nw_cs_grow(struct nw_cs *, uint32_t dwords);
void nw_cs_end_ib(struct nw_cs *);      /* the words since the last end become one IB */
static inline void nw_cs_reserve(struct nw_cs *cs, uint32_t dwords)
{
	if ((uint32_t)(cs->end - cs->cur) < dwords)
		nw_cs_grow(cs, dwords);
}
static inline void nw_cs_emit(struct nw_cs *cs, uint32_t v) { *cs->cur++ = v; }
static inline void nw_cs_emit_qw(struct nw_cs *cs, uint64_t v) { *cs->cur++ = (uint32_t)v; *cs->cur++ = (uint32_t)(v >> 32); }
static inline uint64_t nw_cs_iova(const struct nw_cs *cs) { return cs->start_iova + (uint64_t)((const char *)cs->cur - (const char *)cs->start); }

/* Packet headers, Mesa's rule (adreno_pm4.xml.h, freedreno_pm4.h). */
static inline unsigned nw_odd_parity(uint32_t v)
{
	v ^= v >> 16; v ^= v >> 8; v ^= v >> 4; v &= 0xf;
	return (~0x6996u >> v) & 1u;
}
static inline uint32_t nw_pkt4(uint32_t reg, uint32_t count)
{
	return 0x40000000u | count | (nw_odd_parity(count) << 7) | ((reg & 0x3ffffu) << 8) | (nw_odd_parity(reg) << 27);
}
static inline uint32_t nw_pkt7(uint32_t opcode, uint32_t count)
{
	return 0x70000000u | count | (nw_odd_parity(count) << 15) | ((opcode & 0x7fu) << 16) | (nw_odd_parity(opcode) << 23);
}

/*
 * One submission. The kernel's list holds: the stream's chunks, and the buffers added with nw_submit_name.
 * nw_submit_name dedups in constant time.
 */
struct nw_submit {
	struct nw_device *dev;
	uint32_t stamp;
	struct nw_bo **names;
	uint32_t name_count, name_cap;
	struct nw_cs **streams;
	uint32_t stream_count, stream_cap;
};
void nw_submit_begin(struct nw_submit *, struct nw_device *);
void nw_submit_name(struct nw_submit *, struct nw_bo *);
void nw_submit_stream(struct nw_submit *, struct nw_cs *);
/* 0 and *fence, or a positive errno. The kernel takes at most NW_SUBMIT_MAX_IBS IBs and NW_SUBMIT_MAX_NAMES names. */
#define NW_SUBMIT_MAX_IBS       128     /* kernel GPU_SUBMIT_CMDS */
#define NW_SUBMIT_MAX_NAMES     8192    /* kernel GPU_SUBMIT_BOS */
int nw_submit_go(struct nw_submit *, uint32_t *fence);
void nw_submit_end(struct nw_submit *);

/* Fences are one global sequence of the ring (docs/gpu-abi.md section 3 item 8). */
static inline bool nw_fence_at_least(uint32_t a, uint32_t b) { return (int32_t)(a - b) >= 0; }
/* 0 done, ETIMEDOUT, or another errno (ENODEV: the GPU stopped). timeout_ns from now; the kernel caps a wait at 60 s. */
int nw_fence_wait(struct nw_device *, uint32_t fence, uint64_t timeout_ns);
/* After the fence: the CPU may read a scattered or surface buffer (the kernel drops its cache lines). */
int nw_bo_cpu_prep(struct nw_device *, struct nw_bo *);

/* The monotonic clock of the kernel's WAIT_FENCE deadline: CLOCK_MONOTONIC_RAW on Darwin (ios26-gpu-lag.md section 3, cause 2). */
uint64_t nw_now_ns(void);

#ifdef __cplusplus
}
#endif
#endif
