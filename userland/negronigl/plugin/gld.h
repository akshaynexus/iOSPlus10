/*
 * NegroniGL.bundle internals shared by gld.c (the GLD exports) and the generated gld_stubs.c.
 * Interface facts: docs/notes.md section 15 (20H392 shared cache, unslid).
 */
#ifndef NGL_GLD_H
#define NGL_GLD_H

#include <stdbool.h>
#include <stdint.h>

#define NGL_GLD __attribute__((visibility("default")))

/* CGLError-style codes that libGFXShared, GLEngine and EAGL use */
enum {
	NGL_ERR_BAD_ATTRIBUTE = 0x2710,
	NGL_ERR_BAD_PIXEL_FORMAT = 0x2712,
	NGL_ERR_BAD_RENDERER_INFO = 0x2713,
	NGL_ERR_BAD_CONTEXT = 0x2714,
	NGL_ERR_BAD_DRAWABLE = 0x2715,
	NGL_ERR_BAD_STATE = 0x2717,
	NGL_ERR_BAD_ALLOC = 0x2720,
	NGL_ERR_BAD_CONNECTION = 0x2721,
};

/*
 * gldGetVersion's 4th value: the driver ID (bits 8-15 only; libGFXShared rejects d & 0xffff00ff and
 * gives 0x400 a special meaning). Apple's AppleMetalGLRenderer uses 0x7f00. 'N' = 0x4e.
 */
#define NGL_DRIVER_ID 0x4e00u
#define NGL_GFX_PLUGIN_BIT 0x20000u     /* libGFXShared: plugin ID = driver ID | 0x20000 */

/*
 * The GLD pixel format record (Apple's GLRPixelFormat + 0x40, from GLRPixelFormat::preflight):
 * +0 next, +8 device ID (GLEngine ORs 0x20000 in), +0xc flags: 0x100 = usable by EAGL, 0x20000 =
 * OpenGL ES 3 (EAGLSharegroup -initWithAPI:sharedWithCompute: masks 0, 0, 0x20000 for API 1, 2, 3).
 * The words after +0xc are Apple's defaults; EAGL reads only +0, +8 and +0xc.
 */
struct ngl_pixel_format {
	struct ngl_pixel_format *next;
	uint32_t device_id;
	uint32_t flags;
	uint32_t words[12];
};

extern struct ngl_pixel_format ngl_pf;

int ngl_gld_unexpected(int index, const char *name);

#endif
