/*
 * NegroniFlashlight (iOSPlus10): the iOS side of the torch (kernel patch 0387, /dev/negroniflash).
 * Built into NegroniCamera.driver (mediaserverd) together with the userland/camera sources. See README.md here.
 */
#ifndef NEGRONI_FLASHLIGHT_H
#define NEGRONI_FLASHLIGHT_H
#include <stdbool.h>
#include <stdint.h>

#define NEGRONIFLASH_DEVICE "/dev/negroniflash"
#define NEGRONIFLASH_LEVELS 10

/*
 * Once, from the bundle constructor (mediaserverd), with the shared cache slide. Opens /dev/negroniflash
 * (O_WRONLY) and makes the fallback vendor classes. False when the kernel has no torch (no node, or
 * negroniflash=0, or its self-check turned it off): every other call then does nothing.
 */
bool negroni_flashlight_init(uintptr_t slide);

/* TorchLevel (0..1) of a stream: written as "N\n", N = round(level * 10), at least 1 for level > 0. */
void negroni_flashlight_set(float level);

/*
 * For +[BWFigCaptureDeviceVendor sharedCaptureDeviceVendor] when the camera's device cannot be made
 * (/dev/negronicam absent or failed): the flashlight's own vendor, but only when the caller (the return
 * address of the hook) is FigFlashlight code of the 20H392 cache; NULL otherwise (the caller keeps the
 * camera vendor). Returns an unretained, never freed object (id as void *).
 */
void *negroni_flashlight_vendor_for(uintptr_t return_address);
#endif
