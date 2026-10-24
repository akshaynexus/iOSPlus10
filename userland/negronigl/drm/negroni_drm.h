/* negronigl: what the rest of the library uses of the msm DRM emulation (negroni_drm.c) and the log. */
#ifndef NEGRONI_DRM_H
#define NEGRONI_DRM_H

#include <stdbool.h>
#include <stdint.h>

struct ngl_gpu_info {
	int abi;                        /* enum ngl_abi */
	uint64_t chip_id, gmem_size, gmem_base, max_freq;
};

/* A "DRM fd" for fd_device_new (a dup of /dev/null), or -1 while RedwoodGPU is not there. */
int ngl_drm_open(void);

/* After a successful ngl_drm_open: what the kernel said. */
bool ngl_drm_info(struct ngl_gpu_info *info);

/* A GEM handle for an IOSurface's memory. 0 or errno. */
int ngl_drm_import_surface(uint32_t surface, uint32_t *handle, uint64_t *size);

/*
 * One log line. NEGRONIGL_LOG: "console" (default: /dev/console, the kernel console = serial/USB
 * live log), "oslog", "stderr", "none", or a file path to append to. os_log gets every line too.
 */
void ngl_log(const char *fmt, ...) __attribute__((format(printf, 1, 2)));

#endif
