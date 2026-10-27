/*
 * negronigl: IOSurfaces as GL texture storage.
 *
 * CA renders into IOSurfaces (-attachImage:toCoreSurface:invertedRender:, the texture becomes an
 * FBO color buffer) and samples them (-texImageIOSurface:...). Like EGL images on Linux: the
 * surface's pages become a GEM buffer (the kernel's import, reached through
 * drmPrimeFDToHandle with the surface ID as the "dma-buf fd"), Mesa wraps the buffer in a
 * pipe_resource (resource_from_handle, WINSYS_HANDLE_TYPE_FD) and the frontend hands it to
 * glEGLImageTargetTexture2DOES (get_egl_image below). Nothing is copied.
 *
 * softpipe (no GPU): the surface is a softpipe display target that sw_winsys.c maps with
 * IOSurfaceLock; the CPU draws into it and samples it in place.
 * Multi-plane surfaces (video 420v/420f, CA's 'b3a8'): no GPU import (the kernel import and Mesa's
 * resource_from_handle take one plane); a texture of one plane is filled by a CPU copy instead
 * (plane_copy below; NEGRONIGL_PLANE_COPY=0 refuses them as before). Render targets with planes stay refused.
 * Design: ios-sailfish tools/sweetgl/eagl.c (bind_surface, copy_surface, surf_res); own code.
 * plane_copy: idea from HackiOS surface_to_texture (out/src/hackios-next 8851317 userland/src/eagl.c:674-720,
 * MIT, Copyright (c) 2025-2026 the HakiOS authors); own code.
 */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mach/vm_page_size.h>

#include "pipe/p_screen.h"
#include "pipe/p_state.h"
#include "frontend/api.h"
#include "frontend/winsys_handle.h"
#include "util/u_inlines.h"
#include "drm-uapi/drm_fourcc.h"

#include "negronigl.h"
#include "drm/xf86drm.h"

struct ngl_image {
	struct pipe_resource *res;
	enum pipe_format format;
	unsigned internalformat;
};

static bool
get_egl_image(struct pipe_frontend_screen *fs, void *image, struct st_egl_image *out)
{
	(void)fs;
	struct ngl_image *img = image;
	pipe_resource_reference(&out->texture, img->res);
	out->format = img->format;
	out->level = 0;
	out->layer = 0;
	out->internalformat = img->internalformat;
	return true;
}

static bool
validate_egl_image(struct pipe_frontend_screen *fs, void *image)
{
	(void)fs;
	return image != NULL;
}

void
ngl_image_hooks(struct pipe_frontend_screen *fs)
{
	fs->get_egl_image = get_egl_image;
	fs->validate_egl_image = validate_egl_image;
}

/* GL format/type CA passed -> gallium format and the GL internal format */
static enum pipe_format
gl_format(GLenum format, GLenum type, unsigned *ifmt)
{
	bool half = type == GL_HALF_FLOAT || type == GL_HALF_FLOAT_OES;
	switch (format) {
	case GL_BGRA_EXT:
		*ifmt = GL_RGBA8;
		return PIPE_FORMAT_B8G8R8A8_UNORM;
	case GL_RGBA:
		*ifmt = half ? GL_RGBA16F : GL_RGBA8;
		return half ? PIPE_FORMAT_R16G16B16A16_FLOAT : PIPE_FORMAT_R8G8B8A8_UNORM;
	case GL_LUMINANCE_ALPHA:
		*ifmt = GL_LUMINANCE_ALPHA;
		return PIPE_FORMAT_L8A8_UNORM;
	case GL_LUMINANCE:
		*ifmt = GL_LUMINANCE;
		return PIPE_FORMAT_L8_UNORM;
	case GL_ALPHA:
		*ifmt = GL_ALPHA;
		return PIPE_FORMAT_A8_UNORM;
	case GL_RED:
		*ifmt = half ? GL_R16F : GL_R8;
		return half ? PIPE_FORMAT_R16_FLOAT : PIPE_FORMAT_R8_UNORM;
	case GL_RG:
		*ifmt = half ? GL_RG16F : GL_RG8;
		return half ? PIPE_FORMAT_R16G16_FLOAT : PIPE_FORMAT_R8G8_UNORM;
	default:
		return PIPE_FORMAT_NONE;
	}
}

/* GL upload format/type of a surface by its IOSurface pixel format (0: CA's own, by size) */
static void
upload_format(uint32_t fourcc, size_t bpe, GLenum *format, GLenum *type)
{
	*type = GL_UNSIGNED_BYTE;
	switch (fourcc) {
	case 0:
		*format = bpe == 4 ? GL_BGRA_EXT : bpe == 8 ? GL_RGBA : bpe == 1 ? GL_RED : 0;
		*type = bpe == 8 ? GL_HALF_FLOAT : GL_UNSIGNED_BYTE;
		break;
	case 'BGRA': *format = GL_BGRA_EXT; break;
	case 'RGBA': *format = GL_RGBA; break;
	case 'RGhA': *format = GL_RGBA; *type = GL_HALF_FLOAT; break;
	case 'LA08': *format = GL_LUMINANCE_ALPHA; break;
	case 'A008': *format = GL_ALPHA; break;
	case 'L008': *format = GL_RED; break;
	case 'L016': *format = GL_RG; break;
	default: *format = 0;
	}
}

static enum pipe_format
surface_format(uint32_t fourcc, size_t bpe, unsigned *ifmt)
{
	GLenum f = 0, t = 0;
	upload_format(fourcc, bpe, &f, &t);
	return f ? gl_format(f, t, ifmt) : PIPE_FORMAT_NONE;
}

static struct ngl_state *cur_state(void)
{
	return ngl_cur ? ngl_cur->st : NULL;
}

/* bytes of one texel for an upload format/type (HackiOS bytes_a_pixel, same table) */
static unsigned
texel_bytes(GLenum format, GLenum type)
{
	unsigned parts = format == GL_RGBA || format == GL_BGRA_EXT ? 4 : format == GL_RGB ? 3 :
	    format == GL_RG || format == GL_LUMINANCE_ALPHA ? 2 : 1;
	switch (type) {
	case GL_UNSIGNED_BYTE: return parts;
	case GL_HALF_FLOAT: case GL_HALF_FLOAT_OES: case GL_UNSIGNED_SHORT: return 2 * parts;
	case GL_FLOAT: return 4 * parts;
	default: return 0;
	}
}

/* sized internal format for an ES 3 upload of format/type (0 = not handled) */
static GLenum
upload_internal(GLenum format, GLenum type)
{
	bool half = type == GL_HALF_FLOAT || type == GL_HALF_FLOAT_OES;
	if (type != GL_UNSIGNED_BYTE && !half) return 0;
	switch (format) {
	case GL_LUMINANCE: case GL_LUMINANCE_ALPHA: case GL_ALPHA: return half ? 0 : format;
	case GL_RED: return half ? GL_R16F : GL_R8;
	case GL_RG: return half ? GL_RG16F : GL_RG8;
	case GL_RGBA: return half ? GL_RGBA16F : GL_RGBA;
	case GL_BGRA_EXT: return half ? 0 : GL_BGRA_EXT;
	default: return 0;
	}
}

/*
 * A texture from one plane of a multi-plane surface, copied by the CPU (the GPU import takes one plane).
 * CA's GL renderer samples video as one texture per plane (luma, chroma) and converts in its shader [I].
 * Each bind copies again, so a new frame (a new or refilled surface that CA binds again) is seen.
 */
static bool
plane_copy(IOSurfaceRef s, GLenum target, GLenum format, GLenum type, uint32_t plane, const char *why)
{
	static unsigned logged;
	static int on = -1;
	if (on < 0) on = ngl_env_on("NEGRONIGL_PLANE_COPY", true) ? 1 : 0;
	size_t planes = IOSurfaceGetPlaneCount(s);
	if (!on || target == GL_RENDERBUFFER || (planes && plane >= planes) || (!planes && plane != 0)) return false;
	size_t w = planes ? IOSurfaceGetWidthOfPlane(s, plane) : IOSurfaceGetWidth(s);
	size_t h = planes ? IOSurfaceGetHeightOfPlane(s, plane) : IOSurfaceGetHeight(s);
	size_t row = planes ? IOSurfaceGetBytesPerRowOfPlane(s, plane) : IOSurfaceGetBytesPerRow(s);
	size_t bpe = planes ? IOSurfaceGetBytesPerElementOfPlane(s, plane) : IOSurfaceGetBytesPerElement(s);
	if (format == 0) {              /* CA did not say: by the plane's element size */
		format = bpe == 1 ? GL_LUMINANCE : bpe == 2 ? GL_LUMINANCE_ALPHA : bpe == 4 ? GL_BGRA_EXT : 0;
		type = GL_UNSIGNED_BYTE;
	}
	unsigned texel = texel_bytes(format, type);
	GLenum ifmt = upload_internal(format, type);
	uint32_t fourcc = IOSurfaceGetPixelFormat(s);
	if (!w || !h || !texel || !ifmt || row % texel != 0 || row / texel < w) {
		if (logged++ < 16) ngl_log("negronigl: %s: IOSurface %u plane %u of %zu ('%c%c%c%c') format %#x type %#x: "
		    "no CPU copy for it", why, IOSurfaceGetID(s), plane, planes, (char)(fourcc >> 24), (char)(fourcc >> 16),
		    (char)(fourcc >> 8), (char)fourcc, format, type);
		return false;
	}
	if (IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL) != 0) return false;
	const void *base = planes ? IOSurfaceGetBaseAddressOfPlane(s, plane) : IOSurfaceGetBaseAddress(s);
	if (base == NULL) {
		IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
		return false;
	}
	GLint row_length = 0, alignment = 4;
	glGetIntegerv(GL_UNPACK_ROW_LENGTH, &row_length);
	glGetIntegerv(GL_UNPACK_ALIGNMENT, &alignment);
	glPixelStorei(GL_UNPACK_ROW_LENGTH, (GLint)(row / texel));
	glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
	struct ngl_state *st = ngl_cur ? ngl_cur->st : NULL;
	GLuint tex = 0;
	glGetIntegerv(GL_TEXTURE_BINDING_2D, (GLint *)&tex);
	if (st) { ngl_copy_forget(st, tex); ngl_set_swizzle(st, target, false); }
	for (int i = 0; i < 8 && glGetError() != GL_NO_ERROR; i++) {
		/* an older error must not be taken as this upload's */
	}
	glTexImage2D(target, 0, (GLint)ifmt, (GLsizei)w, (GLsizei)h, 0, format, type, base);
	GLenum err = glGetError();
	if (err != GL_NO_ERROR && ifmt != format) {
		/* an ES 2 context (CA's) takes no sized formats: internal format = format (EXT_texture_rg for RED/RG) */
		glTexImage2D(target, 0, (GLint)format, (GLsizei)w, (GLsizei)h, 0, format, type, base);
		err = glGetError();
	}
	glPixelStorei(GL_UNPACK_ROW_LENGTH, row_length);
	glPixelStorei(GL_UNPACK_ALIGNMENT, alignment);
	IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
	if (err == GL_NO_ERROR) ngl_tex_size(target, 0, (GLsizei)w, (GLsizei)h);
	if (logged++ < 16) ngl_log("negronigl: %s: IOSurface %u plane %u of %zu ('%c%c%c%c') %zux%zu format %#x: "
	    "CPU copy (no GPU import for planes)%s", why, IOSurfaceGetID(s), plane, planes, (char)(fourcc >> 24),
	    (char)(fourcc >> 16), (char)(fourcc >> 8), (char)fourcc, w, h, format, err ? ": GL error" : "");
	return err == GL_NO_ERROR;
}

bool
ngl_bind_surface(IOSurfaceRef s, GLenum target, GLenum format, GLenum type, uint32_t plane, const char *why)
{
	static unsigned logged;
	if (s == NULL) return false;
	if (plane != 0 || IOSurfaceGetPlaneCount(s) > 1) return plane_copy(s, target, format, type, plane, why);
	size_t w = IOSurfaceGetWidth(s), h = IOSurfaceGetHeight(s), pitch = IOSurfaceGetBytesPerRow(s);
	unsigned ifmt = 0;
	enum pipe_format pf = format ? gl_format(format, type, &ifmt) :
	    surface_format(IOSurfaceGetPixelFormat(s), IOSurfaceGetBytesPerElement(s), &ifmt);
	bool argb = !format && IOSurfaceGetPixelFormat(s) == 0 && IOSurfaceGetBytesPerElement(s) == 4;
	if (argb) { pf = PIPE_FORMAT_R8G8B8A8_UNORM; ifmt = GL_RGBA8; }
	if (pf == PIPE_FORMAT_NONE || !w || !h || pitch > UINT32_MAX) return false;
	struct pipe_resource templ = {
		.target = PIPE_TEXTURE_2D, .format = pf, .width0 = (uint32_t)w,
		.height0 = (uint32_t)h, .depth0 = 1, .array_size = 1,
		.bind = PIPE_BIND_SAMPLER_VIEW | PIPE_BIND_RENDER_TARGET | PIPE_BIND_SHARED,
	};
	struct winsys_handle wh = {
		.type = WINSYS_HANDLE_TYPE_SHARED, .handle = IOSurfaceGetID(s),
		.stride = (unsigned)pitch, .format = pf, .modifier = DRM_FORMAT_MOD_LINEAR,
	};
	uint32_t pixel_format = IOSurfaceGetPixelFormat(s);
	if (!ngl_soft()) {
		/* freedreno: the surface's pages as a GEM buffer (kernel import, "dma-buf fd" = surface ID) */
		struct redwood_drm_surface info = {.surface = IOSurfaceGetID(s)};
		if (redwood_drm_surface(-1, &info) != 0) {
			if (logged++ < 32) ngl_log("negronigl: %s: IOSurface %u describe failed: %d", why, info.surface, errno);
			return false;
		}
		wh.type = WINSYS_HANDLE_TYPE_FD;
		wh.handle = (int)info.surface;
		wh.offset = info.offset;
		wh.size = info.size;
		pixel_format = info.pixel_format;
	}
	/* softpipe: sw_winsys.c maps the IOSurface itself (WINSYS_HANDLE_TYPE_SHARED, handle = ID) */
	struct pipe_screen *screen = ngl_screen();
	struct pipe_resource *res = screen && screen->resource_from_handle ?
	    screen->resource_from_handle(screen, &templ, &wh, PIPE_HANDLE_USAGE_FRAMEBUFFER_WRITE) : NULL;
	if (res == NULL) {
		if (logged++ < 32) ngl_log("negronigl: %s: IOSurface %u import failed (%ux%u pitch %u format %#x)",
		    why, IOSurfaceGetID(s), (unsigned)w, (unsigned)h, (unsigned)pitch, pixel_format);
		return false;
	}
	struct ngl_image img = {.res = res, .format = pf, .internalformat = ifmt};
	if (target == GL_RENDERBUFFER) {
		/* -attachImage:toCoreSurface: with GL_RENDERBUFFER: the surface is the renderbuffer's storage */
		_mesa_EGLImageTargetRenderbufferStorageOES(target, (GLeglImageOES)&img);
		pipe_resource_reference(&res, NULL);
		return glGetError() == GL_NO_ERROR;
	}
	struct ngl_state *st = cur_state();
	GLuint tex = 0;
	glGetIntegerv(GL_TEXTURE_BINDING_2D, (GLint *)&tex);
	if (st) { ngl_copy_forget(st, tex); ngl_set_swizzle(st, target, argb); }
	_mesa_EGLImageTargetTexture2DOES(target, (GLeglImageOES)&img);
	pipe_resource_reference(&res, NULL);
	ngl_tex_size(target, 0, (GLsizei)w, (GLsizei)h);
	if (glGetError() != GL_NO_ERROR) return false;
	return true;
}

void
ngl_copy_forget(struct ngl_state *st, GLuint tex)
{
	if (st == NULL || tex >= NGL_NAMES) return;
	struct ngl_copy *c = &st->copies[tex];
	if (c->surface) CFRelease(c->surface);
	memset(c, 0, sizeof(*c));
}

void
ngl_copy_refresh(struct ngl_state *st, int unit, int *active)
{
	(void)st; (void)unit; (void)active;
}

void
ngl_set_swizzle(struct ngl_state *st, GLenum target, bool argb)
{
	if (st == NULL) return;
	GLint tex = 0;
	glGetIntegerv(GL_TEXTURE_BINDING_2D, &tex);
	if (tex > 0 && tex < NGL_NAMES && st->tex_argb[tex] != argb) {
		st->tex_argb[tex] = argb;
		glTexParameteri(target, GL_TEXTURE_SWIZZLE_R, argb ? GL_ALPHA : GL_RED);
		glTexParameteri(target, GL_TEXTURE_SWIZZLE_G, argb ? GL_BLUE : GL_GREEN);
		glTexParameteri(target, GL_TEXTURE_SWIZZLE_B, argb ? GL_GREEN : GL_BLUE);
		glTexParameteri(target, GL_TEXTURE_SWIZZLE_A, argb ? GL_RED : GL_ALPHA);
	}
}
