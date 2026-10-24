/*
 * negronigl: the kernel GPU user-client ABI, as user space sees it. The ONE place to change when
 * the kernel side changes (docs/gpu-abi.md is the kernel's description; docs/gpu-userland.md
 * "Kernel ABI" says which of the two below we expect).
 *
 * Two ABIs are built in; negroni_drm.c picks one when it opens the service:
 *
 *  NGL_ABI_SCALAR      "SweetGPU style": a few scalar selectors that do what freedreno needs; the
 *                      msm DRM requests are answered in user space. Design of ios-sailfish
 *                      (joranv1/ios-sailfish, xnu/patches/0150-sailfish-gpu-bo-submit.patch,
 *                      0151 cpu prep), service name changed to RedwoodGPU.
 *  NGL_ABI_MSM_STRUCT  "passthrough": every msm DRM request is one IOConnectCallStructMethod with
 *                      the request number (low byte of the ioctl code) as the selector and the
 *                      Linux structure in and out; a buffer's memory is IOConnectMapMemory64 of
 *                      memory type = handle. The RedwoodGPU of external/slop patch 0118 and
 *                      HackiOS tools/mesa/redwood-drm (MIT).
 *
 * NEGRONIGL_ABI=scalar|msm|auto in the environment overrides NGL_ABI_DEFAULT. "auto" tries the
 * default first, then the other one: each probe fails cleanly on the other kernel (a scalar call
 * without a structure is kIOReturnBadArgument there, selector 0x40 is unknown to a scalar one).
 */
#ifndef NGL_ABI_H
#define NGL_ABI_H

#include <stdint.h>

#define NGL_GPU_SERVICE         "RedwoodGPU"

enum ngl_abi {
	NGL_ABI_AUTO = 0,
	NGL_ABI_SCALAR = 1,
	NGL_ABI_MSM_STRUCT = 2,
};
#ifndef NGL_ABI_DEFAULT
#define NGL_ABI_DEFAULT         NGL_ABI_AUTO
#endif
/* first ABI tried by "auto" (the task brief: SweetGPU semantics until docs/gpu-abi.md says otherwise) */
#ifndef NGL_ABI_AUTO_FIRST
#define NGL_ABI_AUTO_FIRST      NGL_ABI_SCALAR
#endif

/* ---- NGL_ABI_SCALAR: selectors (IOConnectCallScalarMethod unless noted) ---- */
enum {
	/* in: size.  out: handle, GPU VA, user address of a write-combined mapping in the caller */
	NGL_SEL_BO_NEW          = 10,
	/* in: handle */
	NGL_SEL_BO_FREE         = 11,
	/* in: IOSurface ID.  out: handle, GPU VA, size (whole pages of the surface's memory) */
	NGL_SEL_BO_IMPORT       = 12,
	/* struct in: ngl_submit_hdr + ngl_submit_ib[nr_ibs] + uint32_t handles[nr_bos].  out: fence seq */
	NGL_SEL_SUBMIT          = 13,
	/* in: seq, timeout ms (0: just ask; the kernel caps it at 60000).  kIOReturnTimeout: not yet */
	NGL_SEL_WAIT            = 14,
	/* out: chip id, GMEM size, GMEM base, max freq (Hz), user address of the read-only fence page */
	NGL_SEL_INFO            = 15,
	/* in: handle.  the GPU is done with it: drop CPU cache lines over what the GPU wrote */
	NGL_SEL_BO_CPU_PREP     = 16,
};
#define NGL_SCALAR_INFO_COUNT   5

struct ngl_submit_hdr {
	uint32_t nr_ibs, nr_bos;
};
struct ngl_submit_ib {
	uint32_t iova_lo, iova_hi, dwords, pad;
};

/* ---- NGL_ABI_MSM_STRUCT: selectors = Linux numbers ---- */
#define NGL_MSM_SEL(drm_command_index)  (0x40u + (drm_command_index))   /* DRM_COMMAND_BASE + DRM_MSM_* */
#define NGL_MSM_SEL_GEM_CLOSE   0x09u           /* DRM_IOCTL_GEM_CLOSE */
#define NGL_MSM_SEL_SURFACE     0x7eu           /* not Linux's: struct redwood_drm_surface (xf86drm.h) */
#define NGL_MSM_SURFACE_DESCRIBE 0xffffffffu    /* .handle = this: only describe, make no buffer */

/*
 * msm GET_PARAM answers that the scalar ABI does not ask the kernel for (A730 = Adreno 730,
 * SM8450): Linux adreno_device.c / a6xx_gpu.c values, the same as external/slop patch 0118.
 */
#define NGL_A730_CHIP_ID        0x07030001u
#define NGL_A730_GMEM_SIZE      (2u << 20)
#define NGL_A730_HIGHEST_BANK_BIT 16
#define NGL_A730_UBWC_SWIZZLE   6
#define NGL_A730_MACROTILE_MODE 1
#define NGL_A730_MAX_FREQ       818000000ull

/* GEM buffers are whole pages of this size (iOS arm64 user pages) */
#define NGL_PAGE                16384ull

#endif
