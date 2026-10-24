/*
 * negronigl: libdrm + msm DRM for Mesa's freedreno on iOS, over the RedwoodGPU IOKit user client.
 *
 * freedreno's msm backend reaches the kernel only through the libdrm calls of xf86drm.h and the
 * redwood_drm_* hooks of HackiOS's freedreno-darwin.patch (buffer map/unmap, IOSurface import).
 * This file answers them for one of the two kernel ABIs of ngl_abi.h:
 *
 *  NGL_ABI_MSM_STRUCT  forwarded as they are: selector = request number, structure in and out.
 *  NGL_ABI_SCALAR      answered here, over seven scalar selectors (design of ios-sailfish
 *                      tools/sweetgl/sweet_drm.c; this is our own code):
 *    GEM_NEW / GEM_CLOSE   BO_NEW / BO_FREE: pinned pages, a GPU VA chosen by the kernel
 *                          ("softpin", msm 1.7) and a write-combined user mapping made by it
 *    GEM_INFO              GET_IOVA from our table; GET_OFFSET is handle << 32 (unused: the
 *                          mapping comes from redwood_drm_map, not from mmap)
 *    GEM_SUBMIT            SUBMIT: CMD_BUF/CTX_RESTORE cmds become IBs (bo VA + offset, dwords);
 *                          every bo of the submit remembers the returned fence
 *    WAIT_FENCE, CPU_PREP  WAIT (polled in chunks of at most 5 s), then BO_CPU_PREP
 *    GET_PARAM             INFO (chip id, GMEM, max freq) + A730 constants (ngl_abi.h)
 *
 * The "DRM fd" is a dup of /dev/null: one GPU, one connection per process.
 */
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <IOKit/IOKitLib.h>
#include <IOSurface/IOSurfaceRef.h>

#include "xf86drm.h"
#include "drm-uapi/msm_drm.h"
#include "ngl_abi.h"
#include "negroni_drm.h"

/* msm_drm.h of newer Linux; Mesa 25.0.7's header may lack some */
#ifndef MSM_PARAM_VA_START
#define MSM_PARAM_VA_START      0x0e
#endif
#ifndef MSM_PARAM_VA_SIZE
#define MSM_PARAM_VA_SIZE       0x0f
#endif
#ifndef MSM_PARAM_HIGHEST_BANK_BIT
#define MSM_PARAM_HIGHEST_BANK_BIT 0x10
#endif
#ifndef MSM_PARAM_RAYTRACING
#define MSM_PARAM_RAYTRACING    0x11
#endif
#ifndef MSM_PARAM_UBWC_SWIZZLE
#define MSM_PARAM_UBWC_SWIZZLE  0x12
#endif
#ifndef MSM_PARAM_MACROTILE_MODE
#define MSM_PARAM_MACROTILE_MODE 0x13
#endif

struct nbo {
	uint64_t iova, size;
	void *map;
	uint32_t seq;           /* fence of the last submit that listed it */
	uint32_t surface;       /* IOSurface ID if imported */
	bool used, live;
};

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static io_connect_t conn;
static enum ngl_abi abi;
static int null_fd = -1;
static struct nbo *bos;
static uint32_t nbos;
static uint32_t queues;
static struct ngl_gpu_info info;
static bool no_cpu_prep_sel;    /* BO_CPU_PREP failed once: the kernel has no such selector */

static const char *
abi_name(enum ngl_abi a)
{
	return a == NGL_ABI_SCALAR ? "scalar" : a == NGL_ABI_MSM_STRUCT ? "msm" : "auto";
}

static int
kr_errno(kern_return_t kr)
{
	switch (kr) {
	case KERN_SUCCESS:
		return 0;
	case kIOReturnNoMemory:
	case kIOReturnNoResources:
		return ENOMEM;
	case kIOReturnBadArgument:
		return EINVAL;
	case kIOReturnTimeout:
		return ETIMEDOUT;
	case kIOReturnBusy:
		return EBUSY;
	case kIOReturnNotFound:
		return ENOENT;
	case kIOReturnUnsupported:
		return ENOSYS;
	case kIOReturnNotReady:
	case kIOReturnOffline:
		return ENODEV;
	case kIOReturnNotPermitted:
	case kIOReturnNotPrivileged:
		return EPERM;
	default:
		return EIO;
	}
}

/* ---- probes: fill info, false if this ABI is not the kernel's ---- */

static bool
probe_scalar(void)
{
	uint64_t out[NGL_SCALAR_INFO_COUNT] = {0};
	uint32_t n = NGL_SCALAR_INFO_COUNT;
	kern_return_t kr = IOConnectCallScalarMethod(conn, NGL_SEL_INFO, NULL, 0, out, &n);
	if (kr != KERN_SUCCESS || n < 4) {
		ngl_log("negronigl: scalar ABI probe: %#x (%u values)", kr, n);
		return false;
	}
	info.chip_id = out[0];
	info.gmem_size = out[1];
	info.gmem_base = out[2];
	info.max_freq = out[3];
	return true;
}

static int msm_call(uint32_t sel, void *data, size_t size);

static bool
probe_msm(void)
{
	struct drm_msm_param p = {.pipe = MSM_PIPE_3D0, .param = MSM_PARAM_CHIP_ID};
	int e = msm_call(NGL_MSM_SEL(DRM_MSM_GET_PARAM), &p, sizeof(p));
	if (e) {
		ngl_log("negronigl: msm ABI probe: errno %d", e);
		return false;
	}
	info.chip_id = p.value;
	p.param = MSM_PARAM_GMEM_SIZE;
	info.gmem_size = msm_call(NGL_MSM_SEL(DRM_MSM_GET_PARAM), &p, sizeof(p)) ? 0 : p.value;
	p.param = MSM_PARAM_GMEM_BASE;
	info.gmem_base = msm_call(NGL_MSM_SEL(DRM_MSM_GET_PARAM), &p, sizeof(p)) ? 0 : p.value;
	p.param = MSM_PARAM_MAX_FREQ;
	info.max_freq = msm_call(NGL_MSM_SEL(DRM_MSM_GET_PARAM), &p, sizeof(p)) ? 0 : p.value;
	return true;
}

static enum ngl_abi
wanted_abi(void)
{
	const char *e = getenv("NEGRONIGL_ABI");
	if (e && strcmp(e, "scalar") == 0) {
		return NGL_ABI_SCALAR;
	}
	if (e && (strcmp(e, "msm") == 0 || strcmp(e, "struct") == 0)) {
		return NGL_ABI_MSM_STRUCT;
	}
	return NGL_ABI_DEFAULT;
}

/* lock held */
static void
connect_dev(void)
{
	io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(NGL_GPU_SERVICE));
	if (svc == IO_OBJECT_NULL) {
		return;
	}
	kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &conn);
	IOObjectRelease(svc);
	if (kr != KERN_SUCCESS) {
		ngl_log("negronigl: IOServiceOpen(%s): %#x", NGL_GPU_SERVICE, kr);
		conn = IO_OBJECT_NULL;
		return;
	}
	enum ngl_abi want = wanted_abi(), first = want == NGL_ABI_AUTO ? NGL_ABI_AUTO_FIRST : want;
	enum ngl_abi second = want != NGL_ABI_AUTO ? NGL_ABI_AUTO :
	    first == NGL_ABI_SCALAR ? NGL_ABI_MSM_STRUCT : NGL_ABI_SCALAR;
	abi = NGL_ABI_AUTO;
	if (first == NGL_ABI_SCALAR ? probe_scalar() : probe_msm()) {
		abi = first;
	} else if (second != NGL_ABI_AUTO && (second == NGL_ABI_SCALAR ? probe_scalar() : probe_msm())) {
		abi = second;
	}
	if (abi == NGL_ABI_AUTO) {
		ngl_log("negronigl: %s answers neither ABI (asked: %s)", NGL_GPU_SERVICE, abi_name(want));
		IOServiceClose(conn);
		conn = IO_OBJECT_NULL;
		return;
	}
	info.abi = abi;
	null_fd = open("/dev/null", O_RDWR | O_CLOEXEC);
	ngl_log("negronigl: %s open, %s ABI, chip %#llx, GMEM %llu KiB, max %llu MHz", NGL_GPU_SERVICE,
	    abi_name(abi), (unsigned long long)info.chip_id, (unsigned long long)info.gmem_size >> 10,
	    (unsigned long long)info.max_freq / 1000000);
}

int
ngl_drm_open(void)
{
	pthread_mutex_lock(&lock);
	if (conn == IO_OBJECT_NULL) {
		connect_dev();
	}
	int fd = conn != IO_OBJECT_NULL && null_fd >= 0 ? dup(null_fd) : -1;
	pthread_mutex_unlock(&lock);
	return fd;
}

bool
ngl_drm_info(struct ngl_gpu_info *out)
{
	pthread_mutex_lock(&lock);
	bool ok = conn != IO_OBJECT_NULL;
	if (ok) {
		*out = info;
	}
	pthread_mutex_unlock(&lock);
	return ok;
}

/* ================= NGL_ABI_MSM_STRUCT ================= */

static int
msm_call(uint32_t sel, void *data, size_t size)
{
	size_t out = size;
	kern_return_t kr = IOConnectCallStructMethod(conn, sel, data, size, data, &out);
	return kr_errno(kr);
}

/* ================= NGL_ABI_SCALAR ================= */

/* lock held: the bo for a handle, or NULL */
static struct nbo *
nbo(uint32_t handle)
{
	return handle >= 1 && handle <= nbos && bos[handle - 1].live ? &bos[handle - 1] : NULL;
}

/* lock held */
static int
nbo_add(uint32_t handle, uint64_t iova, void *map, uint64_t size, uint32_t surface)
{
	if (handle == 0 || handle > (1u << 24)) {
		return EINVAL;
	}
	if (handle > nbos) {
		uint32_t n = nbos ? nbos : 256;
		while (n < handle) {
			n *= 2;
		}
		struct nbo *b = realloc(bos, n * sizeof(*b));
		if (b == NULL) {
			return ENOMEM;
		}
		memset(b + nbos, 0, (n - nbos) * sizeof(*b));
		bos = b;
		nbos = n;
	}
	bos[handle - 1] = (struct nbo){.iova = iova, .map = map, .size = size, .surface = surface, .live = true};
	return 0;
}

static bool
seq_passed(uint32_t seq)
{
	uint64_t in[2] = {seq, 0};
	return IOConnectCallScalarMethod(conn, NGL_SEL_WAIT, in, 2, NULL, NULL) == KERN_SUCCESS;
}

/* wait for seq at most ms (UINT64_MAX: forever) */
static int
seq_wait(uint32_t seq, uint64_t ms)
{
	for (;;) {
		uint64_t chunk = ms > 5000 ? 5000 : ms;
		uint64_t in[2] = {seq, chunk};
		kern_return_t kr = IOConnectCallScalarMethod(conn, NGL_SEL_WAIT, in, 2, NULL, NULL);
		if (kr == KERN_SUCCESS) {
			return 0;
		}
		if (kr != kIOReturnTimeout) {
			ngl_log("negronigl: wait for fence %u: %#x", seq, kr);
			return EIO;
		}
		if (ms != UINT64_MAX) {
			ms -= chunk;
			if (ms == 0) {
				return ETIMEDOUT;
			}
		}
	}
}

/*
 * msm timeouts are absolute times. freedreno-darwin.patch makes them on CLOCK_MONOTONIC_RAW
 * (msm_priv.h get_abs_timeout): the same clock here. -> milliseconds from now.
 */
static uint64_t
timeout_ms(const struct drm_msm_timespec *t)
{
	struct timespec now;
	clock_gettime(CLOCK_MONOTONIC_RAW, &now);
	if (t->tv_sec > now.tv_sec + 3000) {
		return UINT64_MAX;      /* Mesa's "infinite" is now + 1 hour */
	}
	int64_t ns = (t->tv_sec - now.tv_sec) * 1000000000ll + (t->tv_nsec - now.tv_nsec);
	return ns <= 0 ? 0 : (uint64_t)(ns / 1000000) + 1;
}

static int
s_get_param(struct drm_msm_param *p)
{
	switch (p->param) {
	case MSM_PARAM_GPU_ID:
		p->value = 0;   /* a7xx: known by the chip id */
		return 0;
	case MSM_PARAM_CHIP_ID:
		p->value = info.chip_id;
		return 0;
	case MSM_PARAM_GMEM_SIZE:
		p->value = info.gmem_size ? info.gmem_size : NGL_A730_GMEM_SIZE;
		return 0;
	case MSM_PARAM_GMEM_BASE:
		p->value = info.gmem_base;
		return 0;
	case MSM_PARAM_MAX_FREQ:
		p->value = info.max_freq ? info.max_freq : NGL_A730_MAX_FREQ;
		return 0;
	case MSM_PARAM_TIMESTAMP:
		/* the generic timer and the GPU's always-on counter both count the 19.2 MHz XO */
		p->value = mach_absolute_time();
		return 0;
	case MSM_PARAM_PRIORITIES:
		p->value = 1;
		return 0;
	case MSM_PARAM_FAULTS:
	case MSM_PARAM_SUSPENDS:
	case MSM_PARAM_RAYTRACING:
		p->value = 0;
		return 0;
	case MSM_PARAM_HIGHEST_BANK_BIT:
		p->value = NGL_A730_HIGHEST_BANK_BIT;
		return 0;
	case MSM_PARAM_UBWC_SWIZZLE:
		p->value = NGL_A730_UBWC_SWIZZLE;
		return 0;
	case MSM_PARAM_MACROTILE_MODE:
		p->value = NGL_A730_MACROTILE_MODE;
		return 0;
	default:
		/* VA_START/VA_SIZE etc.: no user-space GPU address space (msm 1.7 softpin) */
		return EINVAL;
	}
}

static int
s_gem_new(struct drm_msm_gem_new *r)
{
	uint64_t size = (r->size + NGL_PAGE - 1) & ~(NGL_PAGE - 1), in = size, out[3] = {0};
	uint32_t n = 3;
	kern_return_t kr = IOConnectCallScalarMethod(conn, NGL_SEL_BO_NEW, &in, 1, out, &n);
	if (kr != KERN_SUCCESS || n < 3) {
		ngl_log("negronigl: bo new %llu bytes: %#x", (unsigned long long)r->size, kr);
		return kr == KERN_SUCCESS ? EIO : kr_errno(kr) == EINVAL ? ENOMEM : kr_errno(kr);
	}
	pthread_mutex_lock(&lock);
	int e = nbo_add((uint32_t)out[0], out[1], (void *)(uintptr_t)out[2], size, 0);
	pthread_mutex_unlock(&lock);
	if (e) {
		IOConnectCallScalarMethod(conn, NGL_SEL_BO_FREE, out, 1, NULL, NULL);
		return e;
	}
	r->handle = (uint32_t)out[0];
	return 0;
}

static int
s_gem_close(uint32_t handle)
{
	pthread_mutex_lock(&lock);
	struct nbo *b = nbo(handle);
	if (b) {
		memset(b, 0, sizeof(*b));
	}
	pthread_mutex_unlock(&lock);
	if (b == NULL) {
		return EINVAL;
	}
	uint64_t in = handle;
	return kr_errno(IOConnectCallScalarMethod(conn, NGL_SEL_BO_FREE, &in, 1, NULL, NULL));
}

static int
s_gem_info(struct drm_msm_gem_info *r)
{
	pthread_mutex_lock(&lock);
	struct nbo *b = nbo(r->handle);
	int e = b ? 0 : ENOENT;
	if (b) {
		switch (r->info) {
		case MSM_INFO_GET_OFFSET:
			r->value = (uint64_t)r->handle << 32;
			break;
		case MSM_INFO_GET_IOVA:
			r->value = b->iova;
			break;
		case MSM_INFO_SET_NAME:
		case MSM_INFO_GET_NAME:
#ifdef MSM_INFO_SET_METADATA
		case MSM_INFO_SET_METADATA:
#endif
			break;
#ifdef MSM_INFO_GET_FLAGS
		case MSM_INFO_GET_FLAGS:
			r->value = MSM_BO_WC;
			break;
#endif
		default:
			e = EINVAL;
		}
	}
	pthread_mutex_unlock(&lock);
	return e;
}

static int
s_cpu_prep(struct drm_msm_gem_cpu_prep *r)
{
	pthread_mutex_lock(&lock);
	struct nbo *b = nbo(r->handle);
	uint32_t seq = b ? b->seq : 0;
	bool used = b && b->used;
	pthread_mutex_unlock(&lock);
	if (b == NULL) {
		return ENOENT;
	}
	if (!used) {
		return 0;
	}
	if (!seq_passed(seq)) {
		if (r->op & MSM_PREP_NOSYNC) {
			return EBUSY;
		}
		int e = seq_wait(seq, timeout_ms(&r->timeout));
		if (e) {
			return e;
		}
	}
	if (!no_cpu_prep_sel) {
		uint64_t in = r->handle;
		kern_return_t kr = IOConnectCallScalarMethod(conn, NGL_SEL_BO_CPU_PREP, &in, 1, NULL, NULL);
		if (kr != KERN_SUCCESS) {
			/* WC buffers need nothing; a kernel without the selector is taken to have only those */
			no_cpu_prep_sel = true;
			ngl_log("negronigl: BO_CPU_PREP (selector %d): %#x, not asked again", NGL_SEL_BO_CPU_PREP, kr);
		}
	}
	return 0;
}

static int
s_gem_submit(struct drm_msm_gem_submit *r)
{
	if (r->flags & (MSM_SUBMIT_FENCE_FD_IN | MSM_SUBMIT_FENCE_FD_OUT | MSM_SUBMIT_SYNCOBJ_IN |
	    MSM_SUBMIT_SYNCOBJ_OUT
#ifdef MSM_SUBMIT_FENCE_SN_IN
	    | MSM_SUBMIT_FENCE_SN_IN
#endif
	    )) {
		ngl_log("negronigl: submit flags %#x not supported", r->flags);
		return EINVAL;
	}
	const struct drm_msm_gem_submit_bo *sb = (const void *)(uintptr_t)r->bos;
	const struct drm_msm_gem_submit_cmd *sc = (const void *)(uintptr_t)r->cmds;
	size_t len = sizeof(struct ngl_submit_hdr) + (size_t)r->nr_cmds * sizeof(struct ngl_submit_ib) +
	    (size_t)r->nr_bos * sizeof(uint32_t);
	uint8_t *buf = calloc(1, len);
	if (buf == NULL) {
		return ENOMEM;
	}
	struct ngl_submit_hdr *hdr = (void *)buf;
	struct ngl_submit_ib *ib = (void *)(hdr + 1);
	uint32_t nib = 0;
	int e = 0;
	pthread_mutex_lock(&lock);
	for (uint32_t i = 0; i < r->nr_cmds && e == 0; i++) {
		if (sc[i].type == MSM_SUBMIT_CMD_IB_TARGET_BUF) {
			continue;       /* reached through an IB of another cmd */
		}
		struct nbo *b = sc[i].submit_idx < r->nr_bos ? nbo(sb[sc[i].submit_idx].handle) : NULL;
		if (b == NULL || sc[i].nr_relocs || (sc[i].size & 3) ||
		    (uint64_t)sc[i].submit_offset + sc[i].size > b->size) {
			e = EINVAL;
			break;
		}
		uint64_t va = b->iova + sc[i].submit_offset;
		ib[nib++] = (struct ngl_submit_ib){(uint32_t)va, (uint32_t)(va >> 32), sc[i].size / 4, 0};
	}
	uint32_t *handles = (uint32_t *)(ib + nib);
	for (uint32_t i = 0; i < r->nr_bos && e == 0; i++) {
		if (nbo(sb[i].handle) == NULL) {
			e = EINVAL;
		}
		handles[i] = sb[i].handle;
	}
	pthread_mutex_unlock(&lock);
	if (e == 0 && nib == 0) {
		e = EINVAL;
	}
	uint64_t seq = 0;
	uint32_t n = 1;
	if (e == 0) {
		hdr->nr_ibs = nib;
		hdr->nr_bos = r->nr_bos;
		size_t used = sizeof(*hdr) + nib * sizeof(*ib) + r->nr_bos * sizeof(uint32_t);
		kern_return_t kr = IOConnectCallMethod(conn, NGL_SEL_SUBMIT, NULL, 0, buf, used, &seq, &n, NULL, NULL);
		if (kr != KERN_SUCCESS) {
			ngl_log("negronigl: submit (%u IBs, %u bos): %#x", nib, r->nr_bos, kr);
			e = kr_errno(kr);
		}
	}
	if (e == 0) {
		pthread_mutex_lock(&lock);
		for (uint32_t i = 0; i < r->nr_bos; i++) {
			struct nbo *b = nbo(sb[i].handle);
			if (b) {
				b->seq = (uint32_t)seq;
				b->used = true;
			}
		}
		pthread_mutex_unlock(&lock);
		r->fence = (uint32_t)seq;
	}
	free(buf);
	return e;
}

static int
s_command(unsigned long index, void *data)
{
	switch (index) {
	case DRM_MSM_GET_PARAM:
		return s_get_param(data);
	case DRM_MSM_SET_PARAM:
		return 0;
	case DRM_MSM_GEM_NEW:
		return s_gem_new(data);
	case DRM_MSM_GEM_INFO:
		return s_gem_info(data);
	case DRM_MSM_GEM_CPU_PREP:
		return s_cpu_prep(data);
	case DRM_MSM_GEM_CPU_FINI:
		return 0;
	case DRM_MSM_GEM_SUBMIT:
		return s_gem_submit(data);
	case DRM_MSM_WAIT_FENCE: {
		struct drm_msm_wait_fence *w = data;
		if (seq_passed(w->fence)) {
			return 0;
		}
		return seq_wait(w->fence, timeout_ms(&w->timeout));
	}
	case DRM_MSM_GEM_MADVISE:
		((struct drm_msm_gem_madvise *)data)->retained = 1;
		return 0;
	case DRM_MSM_SUBMITQUEUE_NEW:
		pthread_mutex_lock(&lock);
		((struct drm_msm_submitqueue *)data)->id = ++queues;
		pthread_mutex_unlock(&lock);
		return 0;
	case DRM_MSM_SUBMITQUEUE_CLOSE:
		return 0;
	case DRM_MSM_SUBMITQUEUE_QUERY: {
		struct drm_msm_submitqueue_query *q = data;
		if (q->param != MSM_SUBMITQUEUE_PARAM_FAULTS) {
			return EINVAL;
		}
		if (q->data != 0 && q->len >= sizeof(uint32_t)) {
			*(uint32_t *)(uintptr_t)q->data = 0;
		}
		q->len = sizeof(uint32_t);
		return 0;
	}
	default:
		ngl_log("negronigl: unhandled msm request %lu", index);
		return EINVAL;
	}
}

/* ================= libdrm ================= */

/* 0 or errno */
static int
command(unsigned long index, void *data, unsigned long size)
{
	if (conn == IO_OBJECT_NULL) {
		return ENODEV;
	}
	if (abi == NGL_ABI_MSM_STRUCT) {
		return msm_call(NGL_MSM_SEL(index), data, size);
	}
	return s_command(index, data);
}

int
drmOpenWithType(const char *name, const char *busid, int type)
{
	(void)busid;
	(void)type;
	return name && strcmp(name, "msm") == 0 ? ngl_drm_open() : -1;
}

/* libdrm: drmCommand* return -errno */
int
drmCommandWrite(int fd, unsigned long index, void *data, unsigned long size)
{
	(void)fd;
	int e = command(index, data, size);
	if (e) {
		errno = e;
	}
	return -e;
}

int
drmCommandWriteRead(int fd, unsigned long index, void *data, unsigned long size)
{
	return drmCommandWrite(fd, index, data, size);
}

/* libdrm: drmIoctl returns -1 with errno */
int
drmIoctl(int fd, unsigned long request, void *arg)
{
	(void)fd;
	unsigned nr = (unsigned)(request & 0xff);
	int e;
	if (conn == IO_OBJECT_NULL) {
		e = ENODEV;
	} else if (request == DRM_IOCTL_GEM_CLOSE) {
		e = abi == NGL_ABI_MSM_STRUCT ? msm_call(NGL_MSM_SEL_GEM_CLOSE, arg, sizeof(struct drm_gem_close)) :
		    s_gem_close(((struct drm_gem_close *)arg)->handle);
	} else if (((request >> 8) & 0xff) == DRM_IOCTL_BASE && nr >= DRM_COMMAND_BASE && nr < DRM_COMMAND_END) {
		e = command(nr - DRM_COMMAND_BASE, arg, IOCPARM_LEN(request));
	} else {
		ngl_log("negronigl: unhandled drm ioctl %#lx", request);
		e = EINVAL;
	}
	if (e) {
		errno = e;
		return -1;
	}
	return 0;
}

drmVersionPtr
drmGetVersion(int fd)
{
	(void)fd;
	if (conn == IO_OBJECT_NULL) {
		return NULL;
	}
	drmVersionPtr v = calloc(1, sizeof(*v));
	if (v == NULL) {
		return NULL;
	}
	/* 1.7: kernel-chosen GPU addresses told by GET_IOVA, nothing newer */
	v->version_major = 1;
	v->version_minor = 7;
	v->name = strdup("msm");
	v->name_len = 3;
	v->date = strdup("");
	v->desc = strdup("Adreno 730 on XNU (negronigl)");
	v->desc_len = (int)strlen(v->desc);
	return v;
}

void
drmFreeVersion(drmVersionPtr v)
{
	if (v) {
		free(v->name);
		free(v->date);
		free(v->desc);
		free(v);
	}
}

int
drmGetCap(int fd, uint64_t capability, uint64_t *value)
{
	(void)fd;
	(void)capability;
	*value = 0;
	errno = EINVAL;
	return -1;
}

void *
redwood_drm_map(int fd, uint32_t handle, uint64_t size)
{
	(void)fd;
	if (abi == NGL_ABI_MSM_STRUCT) {
		mach_vm_address_t addr = 0;
		mach_vm_size_t len = 0;
		kern_return_t kr = IOConnectMapMemory64(conn, handle, mach_task_self(), &addr, &len, kIOMapAnywhere);
		if (kr != KERN_SUCCESS || len < size) {
			ngl_log("negronigl: map of bo %u (%llu bytes): %#x", handle, (unsigned long long)size, kr);
			if (kr == KERN_SUCCESS) {
				IOConnectUnmapMemory64(conn, handle, mach_task_self(), addr);
			}
			return MAP_FAILED;
		}
		return (void *)(uintptr_t)addr;
	}
	pthread_mutex_lock(&lock);
	struct nbo *b = nbo(handle);
	void *p = b && b->map ? b->map : MAP_FAILED;
	pthread_mutex_unlock(&lock);
	return p;
}

void
redwood_drm_unmap(int fd, uint32_t handle, void *address)
{
	(void)fd;
	if (abi == NGL_ABI_MSM_STRUCT && address != NULL && address != MAP_FAILED) {
		IOConnectUnmapMemory64(conn, handle, mach_task_self(), (mach_vm_address_t)(uintptr_t)address);
	}
	/* scalar ABI: the kernel's mapping goes with BO_FREE; an IOSurface's base is the surface's own */
}

/* what the IOSurface looks like, from IOSurface's own API (same process) */
static bool
describe_local(struct redwood_drm_surface *s)
{
	IOSurfaceRef ref = IOSurfaceLookup(s->surface);
	if (ref == NULL) {
		return false;
	}
	s->width = (uint32_t)IOSurfaceGetWidth(ref);
	s->height = (uint32_t)IOSurfaceGetHeight(ref);
	s->row_bytes = (uint32_t)IOSurfaceGetBytesPerRow(ref);
	s->pixel_format = IOSurfaceGetPixelFormat(ref);
	s->planes = (uint32_t)IOSurfaceGetPlaneCount(ref);
	s->offset = (uint32_t)((uintptr_t)IOSurfaceGetBaseAddress(ref) & vm_page_mask);
	CFRelease(ref);
	return true;
}

int
redwood_drm_surface(int fd, struct redwood_drm_surface *s)
{
	(void)fd;
	int e = 0;
	if (conn == IO_OBJECT_NULL) {
		e = ENODEV;
	} else if (abi == NGL_ABI_MSM_STRUCT) {
		s->handle = NGL_MSM_SURFACE_DESCRIBE;
		e = msm_call(NGL_MSM_SEL_SURFACE, s, sizeof(*s));
	} else {
		/* the size is the one the import told (drmPrimeFDToHandle runs first in fd_bo_from_dmabuf) */
		uint64_t size = 0;
		pthread_mutex_lock(&lock);
		for (uint32_t i = nbos; i > 0 && size == 0; i--) {
			if (bos[i - 1].live && bos[i - 1].surface == s->surface) {
				size = bos[i - 1].size;
			}
		}
		pthread_mutex_unlock(&lock);
		e = describe_local(s) && size ? 0 : ENOENT;
		s->size = size;
	}
	if (e) {
		errno = e;
		return -1;
	}
	return 0;
}

int
ngl_drm_import_surface(uint32_t surface, uint32_t *handle, uint64_t *size)
{
	if (conn == IO_OBJECT_NULL) {
		return ENODEV;
	}
	if (abi == NGL_ABI_MSM_STRUCT) {
		struct redwood_drm_surface s = {.surface = surface};
		int e = msm_call(NGL_MSM_SEL_SURFACE, &s, sizeof(s));
		if (e == 0) {
			*handle = s.handle;
			*size = s.size;
		}
		return e;
	}
	IOSurfaceRef ref = IOSurfaceLookup(surface);
	void *base = ref ? IOSurfaceGetBaseAddress(ref) : NULL;
	uint64_t in = surface, out[3] = {0};
	uint32_t n = 3;
	kern_return_t kr = IOConnectCallScalarMethod(conn, NGL_SEL_BO_IMPORT, &in, 1, out, &n);
	if (ref) {
		CFRelease(ref);     /* the kernel holds the memory while the bo lives; CA holds the surface */
	}
	if (kr != KERN_SUCCESS || n < 3) {
		return kr == KERN_SUCCESS ? EIO : kr_errno(kr);
	}
	/* map = the page that holds the surface's first byte (the bo starts there) */
	void *map = base ? (void *)((uintptr_t)base & ~(uintptr_t)vm_page_mask) : NULL;
	pthread_mutex_lock(&lock);
	int e = nbo_add((uint32_t)out[0], out[1], map, out[2], surface);
	pthread_mutex_unlock(&lock);
	if (e) {
		IOConnectCallScalarMethod(conn, NGL_SEL_BO_FREE, out, 1, NULL, NULL);
		return e;
	}
	*handle = (uint32_t)out[0];
	*size = out[2];
	return 0;
}

int
drmPrimeFDToHandle(int fd, int surface_id, uint32_t *handle)
{
	(void)fd;
	uint64_t size = 0;
	int e = ngl_drm_import_surface((uint32_t)surface_id, handle, &size);
	if (e) {
		ngl_log("negronigl: import of IOSurface %d: errno %d", surface_id, e);
		errno = e;
		return -1;
	}
	return 0;
}

static int
none(void)
{
	errno = ENOSYS;
	return -1;
}

/* buffers and fences as file descriptors for other processes/drivers: none here */
int drmPrimeHandleToFD(int fd, uint32_t h, uint32_t f, int *p) { (void)fd; (void)h; (void)f; (void)p; return none(); }
int drmSyncobjCreate(int fd, uint32_t f, uint32_t *h) { (void)fd; (void)f; (void)h; return none(); }
int drmSyncobjDestroy(int fd, uint32_t h) { (void)fd; (void)h; return none(); }
int drmSyncobjReset(int fd, const uint32_t *h, uint32_t n) { (void)fd; (void)h; (void)n; return none(); }
int drmSyncobjFDToHandle(int fd, int o, uint32_t *h) { (void)fd; (void)o; (void)h; return none(); }
int drmSyncobjHandleToFD(int fd, uint32_t h, int *o) { (void)fd; (void)h; (void)o; return none(); }
int drmSyncobjImportSyncFile(int fd, uint32_t h, int s) { (void)fd; (void)h; (void)s; return none(); }
int drmSyncobjExportSyncFile(int fd, uint32_t h, int *s) { (void)fd; (void)h; (void)s; return none(); }
int
drmSyncobjWait(int fd, uint32_t *h, unsigned n, int64_t t, unsigned f, uint32_t *s)
{
	(void)fd; (void)h; (void)n; (void)t; (void)f; (void)s;
	return none();
}
int
drmSyncobjTimelineWait(int fd, uint32_t *h, uint64_t *p, unsigned n, int64_t t, unsigned f, uint32_t *s)
{
	(void)fd; (void)h; (void)p; (void)n; (void)t; (void)f; (void)s;
	return none();
}
