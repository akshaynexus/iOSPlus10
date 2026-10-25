/*
 * negronigl: the software winsys of the softpipe fallback (no GPU: Mesa draws on the CPU).
 *
 * softpipe keeps "display targets" (textures that live outside Mesa) in the winsys. Here they are
 * either plain memory (displaytarget_create, textures Mesa marks shared/scanout) or IOSurfaces
 * (displaytarget_from_handle, WINSYS_HANDLE_TYPE_SHARED with .handle = the IOSurface ID; surface.c
 * makes them for -texImageIOSurface: and -attachImage:toCoreSurface:). An IOSurface is drawn into
 * and read in place: map = IOSurfaceLock + its base address, unmap = IOSurfaceUnlock. Nothing is
 * copied. The pattern follows Mesa's winsys/sw/null and winsys/sw/wrapper; own code.
 */
#include <stdlib.h>
#include <string.h>
#include <IOSurface/IOSurfaceRef.h>

#include "pipe/p_defines.h"
#include "pipe/p_state.h"
#include "frontend/sw_winsys.h"
#include "frontend/winsys_handle.h"
#include "util/format/u_format.h"

#include "negronigl.h"

struct ngl_dt {
	IOSurfaceRef surface;           /* NULL: malloc memory in data */
	void *data;
	unsigned stride;
	size_t offset;                  /* plane offset in the surface */
	int maps;                       /* map calls not yet unmapped */
};

static struct ngl_dt *
dt_of(struct sw_displaytarget *dt)
{
	return (struct ngl_dt *)dt;
}

static bool
ws_format_ok(struct sw_winsys *ws, unsigned usage, enum pipe_format format)
{
	(void)ws;
	(void)usage;
	return util_format_get_blocksize(format) > 0;
}

static struct sw_displaytarget *
ws_create(struct sw_winsys *ws, unsigned usage, enum pipe_format format, unsigned width, unsigned height,
    unsigned alignment, const void *front_private, unsigned *stride)
{
	(void)ws;
	(void)usage;
	(void)front_private;
	unsigned bs = util_format_get_blocksize(format);
	if (bs == 0 || width == 0 || height == 0 || width > 16384 || height > 16384) {
		return NULL;
	}
	if (alignment < 64) {
		alignment = 64;
	}
	unsigned pitch = (util_format_get_stride(format, width) + alignment - 1) / alignment * alignment;
	size_t rows = util_format_get_nblocksy(format, height);
	struct ngl_dt *d = calloc(1, sizeof(*d));
	if (d == NULL) {
		return NULL;
	}
	if (posix_memalign(&d->data, 64, (size_t)pitch * rows) != 0) {
		free(d);
		return NULL;
	}
	memset(d->data, 0, (size_t)pitch * rows);
	d->stride = pitch;
	*stride = pitch;
	return (struct sw_displaytarget *)d;
}

static struct sw_displaytarget *
ws_from_handle(struct sw_winsys *ws, const struct pipe_resource *templ, struct winsys_handle *wh, unsigned *stride)
{
	(void)ws;
	if (wh->type != WINSYS_HANDLE_TYPE_SHARED || wh->handle == 0) {
		return NULL;
	}
	IOSurfaceRef s = IOSurfaceLookup((IOSurfaceID)wh->handle);       /* +1 */
	if (s == NULL) {
		return NULL;
	}
	size_t plane = wh->plane, pitch, w, h, bpe;
	if (IOSurfaceGetPlaneCount(s) > 1) {
		pitch = IOSurfaceGetBytesPerRowOfPlane(s, plane);
		w = IOSurfaceGetWidthOfPlane(s, plane);
		h = IOSurfaceGetHeightOfPlane(s, plane);
		bpe = IOSurfaceGetBytesPerElementOfPlane(s, plane);
	} else {
		pitch = IOSurfaceGetBytesPerRow(s);
		w = IOSurfaceGetWidth(s);
		h = IOSurfaceGetHeight(s);
		bpe = IOSurfaceGetBytesPerElement(s);
	}
	unsigned need = util_format_get_stride(templ->format, templ->width0);
	if (pitch < need || w < templ->width0 || h < templ->height0 || bpe == 0 ||
	    (size_t)wh->offset + pitch * util_format_get_nblocksy(templ->format, templ->height0) > IOSurfaceGetAllocSize(s)) {
		ngl_log("negronigl: softpipe: IOSurface %u (%zux%zu pitch %zu) does not fit %ux%u %s", wh->handle, w, h,
		    pitch, templ->width0, templ->height0, util_format_short_name(templ->format));
		CFRelease(s);
		return NULL;
	}
	struct ngl_dt *d = calloc(1, sizeof(*d));
	if (d == NULL) {
		CFRelease(s);
		return NULL;
	}
	d->surface = s;
	d->stride = (unsigned)pitch;
	d->offset = wh->offset;
	*stride = d->stride;
	return (struct sw_displaytarget *)d;
}

static bool
ws_get_handle(struct sw_winsys *ws, struct sw_displaytarget *dt, struct winsys_handle *wh)
{
	(void)ws;
	struct ngl_dt *d = dt_of(dt);
	if (d->surface == NULL || wh->type != WINSYS_HANDLE_TYPE_SHARED) {
		return false;
	}
	wh->handle = IOSurfaceGetID(d->surface);
	wh->stride = d->stride;
	wh->offset = (unsigned)d->offset;
	return true;
}

static void *
ws_map(struct sw_winsys *ws, struct sw_displaytarget *dt, unsigned flags)
{
	(void)ws;
	struct ngl_dt *d = dt_of(dt);
	if (d->surface == NULL) {
		return d->data;
	}
	/* a read-write lock every time: nested maps (sampler + render target) keep one lock kind */
	(void)flags;
	IOSurfaceLock(d->surface, 0, NULL);
	__atomic_add_fetch(&d->maps, 1, __ATOMIC_RELAXED);
	uint8_t *base = IOSurfaceGetBaseAddress(d->surface);
	return base ? base + d->offset : NULL;
}

static void
ws_unmap(struct sw_winsys *ws, struct sw_displaytarget *dt)
{
	(void)ws;
	struct ngl_dt *d = dt_of(dt);
	if (d->surface != NULL && __atomic_load_n(&d->maps, __ATOMIC_RELAXED) > 0) {
		__atomic_sub_fetch(&d->maps, 1, __ATOMIC_RELAXED);
		IOSurfaceUnlock(d->surface, 0, NULL);
	}
}

static void
ws_display(struct sw_winsys *ws, struct sw_displaytarget *dt, void *ctx, unsigned nboxes, struct pipe_box *box)
{
	(void)ws;
	(void)dt;
	(void)ctx;
	(void)nboxes;
	(void)box;
}

static void
ws_destroy_dt(struct sw_winsys *ws, struct sw_displaytarget *dt)
{
	(void)ws;
	struct ngl_dt *d = dt_of(dt);
	if (d == NULL) {
		return;
	}
	while (d->surface != NULL && d->maps > 0) {
		d->maps--;
		IOSurfaceUnlock(d->surface, 0, NULL);
	}
	if (d->surface != NULL) {
		CFRelease(d->surface);
	}
	free(d->data);
	free(d);
}

static void
ws_destroy(struct sw_winsys *ws)
{
	free(ws);
}

struct sw_winsys *
ngl_sw_winsys_create(void)
{
	struct sw_winsys *ws = calloc(1, sizeof(*ws));
	if (ws == NULL) {
		return NULL;
	}
	ws->destroy = ws_destroy;
	ws->is_displaytarget_format_supported = ws_format_ok;
	ws->displaytarget_create = ws_create;
	ws->displaytarget_from_handle = ws_from_handle;
	ws->displaytarget_get_handle = ws_get_handle;
	ws->displaytarget_map = ws_map;
	ws->displaytarget_unmap = ws_unmap;
	ws->displaytarget_display = ws_display;
	ws->displaytarget_destroy = ws_destroy_dt;
	return ws;
}
