/*
 * NegroniGL.bundle GLI view/drawable entries: the last four of the 18 _gli_plugin slots that
 * eagl_init dlsym()s from our bundle (docs/notes.md section 15). gli_table.c installs the table,
 * gli_context.c makes the Mesa context; this file binds a CAEAGLLayer drawable's IOSurface as the
 * color renderbuffer and presents it.
 *
 *   +0x40 gliAttachDrawable          +0x48 gliAttachDrawableWithOptions   (CGL/macOS; iOS does not
 *                                    use them, but the dlsym loop drops the whole table if any of
 *                                    the 18 names is NULL, so they must exist: no-op, succeed)
 *   +0x88 gliBindViewES              +0x90 gliPresentViewES
 *
 * -[EAGLContext renderbufferStorage:fromDrawable:] [V 0x1d3f518f4] calls, through _gli_plugin+0x88:
 *   gliBindViewES(GLIContext, NULL, 0, 0)                          -- detach the old view first
 *   gliBindViewES(GLIContext, nativeWindow, retained, colorformat) -- then attach; nonzero = ok
 * -[EAGLContext presentRenderbuffer:] / atTime: / afterMinimumDuration: [V 0x1d3f51b48..0x1d3f51c5c]
 * call gliPresentViewES(GLIContext, afterMinimumDuration 0/1, d0 = time or duration, 0 = now).
 *
 * The native window is QuartzCore's _CAEAGLNativeWindow (-[CAEAGLLayer nativeWindow] 0x188468d68)
 * [V 20H392]: a table of functions, each taking the window as argument 0:
 *   +0x00 uint32 version (5)
 *   +0x08 bool attach(nw, fourcc, callbacks)  0x1882adf1c: sets "attached" (bit 1 of +0x84), takes a
 *         reference (+0x80), copies callbacks {ctx, create(ctx, surface), destroy(ctx, surface),
 *         preflight(ctx, w, h, flags) or NULL} to +0x40..+0x58
 *   +0x10 void detach(nw)                     0x18846961c: drops the reference
 *   +0x18 IOSurfaceRef begin_iosurface(nw)    0x188469a30: the next drawable surface; NULL while not
 *         attached (so it must follow attach; GLEngine _gliBindViewES 0x1f6f57940 does the same)
 *   +0x20 bool swap(nw, mode, double time)    native_window_swap(_zero_time): queues the surface to CA
 *   +0x30 uint32 begin_properties(nw)         (version >= 2) orientation flags
 * GLEngine passes {renderbuffer, eagl_create_buffer (returns 1), eagl_destroy_buffer (forgets the
 * surface), eagl_preflight_properties}; ours are the same minus preflight (CA checks it for NULL,
 * 0x18846a1b0). Present: GLEngine flushes, then swap(nw, version >= 5 && time != 0 ? (after ? 5 : 3)
 * : 1, time) [V 0x1f6f57e94]. The next frame draws into the next begin_iosurface surface.
 *
 * Rule: never crash the caller. A NULL pointer or a bad surface fails with 0 (EAGL returns NO).
 * [I] begin_iosurface can wait for a free drawable (CA's drawable timeout), as with Apple's GL.
 */
#include <stdint.h>
#include <stddef.h>

#include <CoreFoundation/CoreFoundation.h>
#include <IOSurface/IOSurfaceRef.h>

#include "negronigl.h"
#include "gli.h"

struct ngl_nw {                 /* _CAEAGLNativeWindow function table (head only) */
	uint32_t version;
	uint32_t pad;
	bool (*attach)(void *nw, uint32_t fourcc, void *const *callbacks);
	void (*detach)(void *nw);
	IOSurfaceRef (*begin_iosurface)(void *nw);
	bool (*swap)(void *nw, uint32_t mode, double t);
	void *collect;
	uint32_t (*begin_properties)(void *nw);
};

/* callbacks CA calls when it makes or drops a drawable surface for us */
static bool
cb_create(void *ctx, IOSurfaceRef s)
{
	(void)ctx;
	(void)s;
	return true;
}

static void
cb_destroy(void *ctx, IOSurfaceRef s)
{
	(void)ctx;
	(void)s;                /* our view_surface holds its own reference */
}

static IOSurfaceRef
valid_surface(IOSurfaceRef s)
{
	return s != NULL && CFGetTypeID(s) == IOSurfaceGetTypeID() ? s : NULL;
}

/* make the drawable surface s the storage of renderbuffer rb (current context = g) */
static bool
bind_storage(struct ngl_gli *g, GLuint rb, IOSurfaceRef s)
{
	GLint was = 0;
	glGetIntegerv(GL_RENDERBUFFER_BINDING, &was);
	if ((GLuint)was != rb) {
		glBindRenderbuffer(GL_RENDERBUFFER, rb);
	}
	/* surface.c reads the GL format from the IOSurface pixel format (format/type 0 = infer) */
	bool ok = ngl_bind_surface(s, GL_RENDERBUFFER, 0, 0, 0, "gliBindViewES");
	if ((GLuint)was != rb) {
		glBindRenderbuffer(GL_RENDERBUFFER, (GLuint)was);
	}
	if (ok) {
		if (g->view_surface != NULL) {
			CFRelease(g->view_surface);
		}
		g->view_surface = (IOSurfaceRef)CFRetain(s);
	}
	return ok;
}

/* detach the drawable and release its surface; gliBindViewES and gliDestroyContext. No GL calls. */
void
ngl_gli_view_unbind(struct ngl_gli *g)
{
	if (g == NULL) {
		return;
	}
	struct ngl_nw *nw = g->view;
	if (nw != NULL && nw->detach != NULL) {
		nw->detach(nw);         /* drops the reference attach took */
	}
	if (g->view_surface != NULL) {
		CFRelease(g->view_surface);
		g->view_surface = NULL;
	}
	g->view = NULL;
	g->view_rb = 0;
	g->view_colorformat = 0;
}

/*
 * +0x88: attach (nativeWindow != NULL) or detach (NULL) the drawable. On attach, the app has bound
 * the renderbuffer that receives the storage (glBindRenderbuffer before the method). Nonzero = ok.
 */
NGL_GLD int
gliBindViewES(void *rctx, void *native_window, uint32_t retained, uint32_t colorformat)
{
	struct ngl_gli *g = rctx;
	if (g == NULL) {
		return 0;
	}
	ngl_gli_view_unbind(g);                 /* drop the previous drawable, if any */
	if (native_window == NULL) {
		return 1;                       /* detach only: EAGL ignores this call's result */
	}
	struct ngl_nw *nw = native_window;
	if (nw->attach == NULL || nw->detach == NULL || nw->begin_iosurface == NULL || nw->swap == NULL) {
		return 0;
	}
	NGL_CUR(g);
	GLint rb = 0;
	glGetIntegerv(GL_RENDERBUFFER_BINDING, &rb);
	if (rb <= 0) {
		return 0;               /* no renderbuffer bound: nothing to give the storage to */
	}
	/* 'BGRA' for every color format: the one drawable format surface.c imports (GLEngine maps
	 * GL_RGB565 to 'L565' and two wide formats to 10-bit ones) */
	g->view_cb[0] = g;
	g->view_cb[1] = (void *)cb_create;
	g->view_cb[2] = (void *)cb_destroy;
	g->view_cb[3] = NULL;
	if (!nw->attach(nw, 'BGRA', g->view_cb)) {
		ngl_log("negronigl: gliBindViewES: drawable attach failed (colorformat %#x)", colorformat);
		return 0;
	}
	g->view = nw;
	if (nw->version >= 2 && nw->begin_properties != NULL) {
		(void)nw->begin_properties(nw);         /* orientation flags; rotation is not applied */
	}
	IOSurfaceRef s = valid_surface(nw->begin_iosurface(nw));
	if (s == NULL || !bind_storage(g, (GLuint)rb, s)) {
		static int logged;
		if (!__atomic_exchange_n(&logged, 1, __ATOMIC_RELAXED)) {
			ngl_log("negronigl: gliBindViewES: no usable IOSurface from the drawable (colorformat %#x)",
			    colorformat);
		}
		ngl_gli_view_unbind(g);
		return 0;
	}
	g->view_rb = (GLuint)rb;
	g->view_colorformat = colorformat;
	static int logged;
	if (!__atomic_exchange_n(&logged, 1, __ATOMIC_RELAXED)) {
		ngl_log("negronigl: gliBindViewES: drawable IOSurface %u (%zux%zu) bound as renderbuffer %d "
		    "(colorformat %#x, retained %u)", IOSurfaceGetID(s), IOSurfaceGetWidth(s), IOSurfaceGetHeight(s),
		    rb, colorformat, retained);
	}
	return 1;
}

/*
 * +0x90: present the renderbuffer. glFinish makes the frame land in the drawable IOSurface, swap
 * hands the surface to CoreAnimation, then the renderbuffer gets the next drawable surface.
 */
NGL_GLD int
gliPresentViewES(void *rctx, uint32_t after_minimum, double t)
{
	struct ngl_gli *g = rctx;
	if (g == NULL) {
		return 0;
	}
	NGL_CUR(g);
	glFinish();
	struct ngl_nw *nw = g->view;
	if (nw == NULL) {
		return 0;               /* no drawable (EAGL ignores the result) */
	}
	uint32_t mode = nw->version >= 5 && t != 0.0 ? (after_minimum ? 5 : 3) : 1;
	bool ok = nw->swap(nw, mode, t);
	if (g->view_rb != 0 && glIsRenderbuffer(g->view_rb)) {
		IOSurfaceRef s = valid_surface(nw->begin_iosurface(nw));
		if (s != NULL && s != g->view_surface && !bind_storage(g, g->view_rb, s)) {
			static int logged;
			if (!__atomic_exchange_n(&logged, 1, __ATOMIC_RELAXED)) {
				ngl_log("negronigl: gliPresentViewES: next drawable IOSurface %u not bound",
				    IOSurfaceGetID(s));
			}
		}
	}
	return ok ? 1 : 0;
}

/* +0x40/+0x48: CGL window/pbuffer attach. iOS EAGL never calls these; they exist so the dlsym loop
 * never binds NULL. No drawable to attach: succeed as a no-op. */
NGL_GLD int
gliAttachDrawable(void *rctx, int kind, void *drawable)
{
	(void)rctx;
	(void)kind;
	(void)drawable;
	static int logged;
	if (!__atomic_exchange_n(&logged, 1, __ATOMIC_RELAXED)) {
		ngl_log("negronigl: gliAttachDrawable called (iOS EAGL uses gliBindViewES); ignored");
	}
	return 0;
}

NGL_GLD int
gliAttachDrawableWithOptions(void *rctx, int kind, void *drawable, const void *options)
{
	(void)options;
	return gliAttachDrawable(rctx, kind, drawable);
}
