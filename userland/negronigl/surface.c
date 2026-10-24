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
 * Surfaces the GPU cannot address in place (row pitch not a multiple of 64 bytes, multi-plane)
 * are copied into the texture instead and copied again when their seed moves (CPU writes).
 * Design: ios-sailfish tools/sweetgl/eagl.c (bind_surface, copy_surface, surf_res); own code.
 */
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

/*
 * NOT IMPLEMENTED in this revision (docs/gpu-userland.md "Open items"): the kernel import ->
 * resource_from_handle -> EGLImage path, the CPU copy fallback and its seed refresh. Until then
 * every IOSurface bind fails (CA then drops that layer) and the functions below do nothing.
 */
bool
ngl_bind_surface(IOSurfaceRef s, GLenum target, GLenum format, GLenum type, uint32_t plane, const char *why)
{
	static int logged;
	(void)target; (void)format; (void)type;
	if (logged++ < 20) {
		ngl_log("negronigl: %s: IOSurface %u plane %u: binding not implemented", why, IOSurfaceGetID(s), plane);
	}
	return false;
}

void
ngl_copy_forget(struct ngl_state *st, GLuint tex)
{
	(void)st; (void)tex;
}

void
ngl_copy_refresh(struct ngl_state *st, int unit, int *active)
{
	(void)st; (void)unit; (void)active;
}

void
ngl_set_swizzle(struct ngl_state *st, GLenum target, bool argb)
{
	(void)st; (void)target; (void)argb;
	(void)cur_state;
}
