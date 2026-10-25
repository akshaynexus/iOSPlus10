/*
 * negronigl: the part of libdrm's xf86drm.h that Mesa's freedreno uses, on iOS (no DRM).
 * scripts/gpu/mesa-fetch.sh copies this file to Mesa's src/redwood-drm/, which HackiOS's
 * freedreno-darwin.patch (MIT, oosexgang/hackios-xnu-userland tools/mesa) puts on freedreno's
 * include path. The functions are in negroni_drm.c (linked into negronigl.dylib); they answer
 * the msm DRM requests over the RedwoodGPU IOKit user client (ngl_abi.h).
 *
 * The redwood_drm_* names and struct redwood_drm_surface are the ones freedreno-darwin.patch
 * calls (freedreno_bo.c: map, unmap, dmabuf import); their layout matches HackiOS redwood-drm.
 */
#ifndef NEGRONIGL_XF86DRM_H
#define NEGRONIGL_XF86DRM_H

#include <fcntl.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>
#include <sys/ioccom.h>

#include "drm-uapi/drm.h"

#define DRM_NODE_PRIMARY        0
#define DRM_NODE_CONTROL        1
#define DRM_NODE_RENDER         2
#define DRM_NODE_MAX            3
#define DRM_CLOEXEC             O_CLOEXEC
#define DRM_RDWR                O_RDWR

typedef struct _drmVersion {
	int version_major, version_minor, version_patchlevel;
	int name_len;
	char *name;
	int date_len;
	char *date;
	int desc_len;
	char *desc;
} drmVersion, *drmVersionPtr;

#ifdef __cplusplus
extern "C" {
#endif

int drmOpenWithType(const char *name, const char *busid, int type);
int drmIoctl(int fd, unsigned long request, void *arg);
int drmCommandWrite(int fd, unsigned long index, void *data, unsigned long size);
int drmCommandWriteRead(int fd, unsigned long index, void *data, unsigned long size);
drmVersionPtr drmGetVersion(int fd);
void drmFreeVersion(drmVersionPtr version);
int drmGetCap(int fd, uint64_t capability, uint64_t *value);

/* Turnip builds its generic DRM WSI, but iOS has no DRM display device to enumerate. */
enum { DRM_BUS_PCI = 0, DRM_BUS_USB = 1, DRM_BUS_PLATFORM = 2, DRM_BUS_HOST1X = 3 };
struct drmPciBusInfo { uint16_t domain; uint8_t bus, dev, func; };
struct _drmDevice {
	char **nodes;
	int available_nodes;
	int bustype;
	union { struct drmPciBusInfo *pci; } businfo;
};
typedef struct _drmDevice *drmDevicePtr;
static inline int drmGetDevice2(int fd, uint32_t flags, drmDevicePtr *device)
{ (void)fd; (void)flags; if (device) *device = NULL; return -1; }
static inline int drmDevicesEqual(drmDevicePtr a, drmDevicePtr b)
{ (void)a; (void)b; return 0; }
static inline void drmFreeDevice(drmDevicePtr *device)
{ if (device) *device = NULL; }

/* "dma-buf" = an IOSurface, by its ID (see redwood_drm_surface) */
int drmPrimeHandleToFD(int fd, uint32_t handle, uint32_t flags, int *prime_fd);
int drmPrimeFDToHandle(int fd, int surface_id, uint32_t *handle);

int drmSyncobjCreate(int fd, uint32_t flags, uint32_t *handle);
int drmSyncobjDestroy(int fd, uint32_t handle);
int drmSyncobjReset(int fd, const uint32_t *handles, uint32_t count);
int drmSyncobjFDToHandle(int fd, int obj_fd, uint32_t *handle);
int drmSyncobjHandleToFD(int fd, uint32_t handle, int *obj_fd);
int drmSyncobjImportSyncFile(int fd, uint32_t handle, int sync_file_fd);
int drmSyncobjExportSyncFile(int fd, uint32_t handle, int *sync_file_fd);
int drmSyncobjWait(int fd, uint32_t *handles, unsigned num_handles, int64_t timeout_nsec,
    unsigned flags, uint32_t *first_signaled);
int drmSyncobjTimelineWait(int fd, uint32_t *handles, uint64_t *points, unsigned num_handles,
    int64_t timeout_nsec, unsigned flags, uint32_t *first_signaled);
int drmSyncobjSignal(int fd, const uint32_t *handles, uint32_t count);
int drmSyncobjTimelineSignal(int fd, const uint32_t *handles, const uint64_t *points, uint32_t count);
int drmSyncobjQuery(int fd, uint32_t *handles, uint64_t *points, uint32_t count);
int drmSyncobjTransfer(int fd, uint32_t dst_handle, uint64_t dst_point, uint32_t src_handle,
    uint64_t src_point, uint32_t flags);

/* Not libdrm: the buffer's memory in this process (replaces mmap() on the device). MAP_FAILED on error. */
void *redwood_drm_map(int fd, uint32_t handle, uint64_t size);
void redwood_drm_unmap(int fd, uint32_t handle, void *address);

/* Not libdrm: what an IOSurface's memory is as a buffer. 0, or -1 with errno. */
struct redwood_drm_surface {
	uint32_t surface;                       /* IOSurface ID */
	uint32_t handle;                        /* out: GEM handle (NGL_MSM_SURFACE_DESCRIBE: none) */
	uint64_t size;                          /* out: buffer size */
	uint32_t offset, row_bytes;             /* out: first pixel in the buffer, bytes per row */
	uint32_t width, height, pixel_format, planes;
};
int redwood_drm_surface(int fd, struct redwood_drm_surface *surface);

/* Not libdrm: NGL_MSM_SEL_USERPTR (ngl_abi.h, docs/gpu-abi.md section 4). The kernel wires [pointer, pointer + size)
 * of the caller while the handle lives; the CPU keeps its own (cached) mapping. */
struct redwood_drm_userptr {
	uint64_t pointer;                       /* in: 16 KiB aligned user address */
	uint64_t size;                          /* in: bytes, multiple of 16 KiB, at most 256 MiB */
	uint32_t flags;                         /* in: NGL_USERPTR_READ_ONLY or 0 */
	uint32_t handle;                        /* out: GEM handle */
};
#ifdef __cplusplus
static_assert(sizeof(struct redwood_drm_userptr) == 24, "docs/gpu-abi.md: 24 bytes exactly");
#else
_Static_assert(sizeof(struct redwood_drm_userptr) == 24, "docs/gpu-abi.md: 24 bytes exactly");
#endif

/*
 * Not libdrm: a GEM handle over the caller's pages at pointer (VK_EXT_external_memory_host). The IOSurface whose memory
 * starts at pointer (noted before with redwood_drm_note_surface) is imported by ID (0x7e, scalar 12): only such imports
 * take part in the kernel's present path (docs/gpu-abi.md section 8). Other pages: USERPTR (0x49, kernel 0232; msm ABI
 * only), read-only pages with NGL_USERPTR_READ_ONLY. After GPU writes the CPU must drop its lines (CPU_PREP or dc civac).
 * *bo_size = the buffer's size (whole 16 KiB pages). *read_only = imported with NGL_USERPTR_READ_ONLY (the GPU only reads
 * the pages: no cache upkeep is ever needed). 0 or errno (ENOSYS: no way to import these pages here).
 */
int redwood_drm_host_import(int fd, void *pointer, uint64_t size, uint32_t *handle, uint64_t *bo_size, bool *read_only);
/* Not libdrm: CPU_PREP (msm 0x44, scalar 16) of a GEM handle with MSM_PREP_NOSYNC (no wait): if the buffer's last
 * submission is done, the kernel drops the CPU's cache lines over the buffer's pages by their physical addresses, not by a
 * user address (host imports too, patches/xnu/0230 cpuPrep); else EBUSY. For Turnip's vkInvalidateMappedMemoryRanges of
 * a writable host import, whose user mapping the program may have taken away. 0 or errno. */
int redwood_drm_cpu_prep(int fd, uint32_t handle);
/* Not libdrm, exported by Turnip (NegroniMetal's frontend calls it through dlsym before each IOSurface import):
 * IOSurface `surface` is mapped at base (its IOSurfaceGetBaseAddress) for size bytes. */
void redwood_drm_note_surface(const void *base, uint64_t size, uint32_t surface);

#ifdef __cplusplus
}
#endif

#endif
