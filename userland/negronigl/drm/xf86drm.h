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

int drmOpenWithType(const char *name, const char *busid, int type);
int drmIoctl(int fd, unsigned long request, void *arg);
int drmCommandWrite(int fd, unsigned long index, void *data, unsigned long size);
int drmCommandWriteRead(int fd, unsigned long index, void *data, unsigned long size);
drmVersionPtr drmGetVersion(int fd);
void drmFreeVersion(drmVersionPtr version);
int drmGetCap(int fd, uint64_t capability, uint64_t *value);

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

#endif
