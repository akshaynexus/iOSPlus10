/*
 * negronigl: CAEAGLLayer drawables (the "native window") as renderbuffer storage, and the present.
 * Shared by the dylib's EAGL shim (eagl.c -renderbufferStorage:fromDrawable: / -presentRenderbuffer:)
 * and the bundle's GLI entries (plugin/gli_view.c gliBindViewES / gliPresentViewES).
 *
 * The native window is QuartzCore's _CAEAGLNativeWindow (-[CAEAGLLayer nativeWindow] 0x188468d68)
 * [V 20H392, docs/notes.md 15a]: a table of functions, each taking the window as argument 0:
 *   +0x00 uint32 version (5)
 *   +0x08 bool attach(nw, fourcc, callbacks)  0x1882adf1c: takes a reference (+0x80), copies callbacks
 *         {ctx, create(ctx, surface), destroy(ctx, surface), preflight(ctx, w, h, flags) or NULL}
 *   +0x10 void detach(nw)                     0x18846961c: drops the reference
 *   +0x18 IOSurfaceRef begin_iosurface(nw)    0x188469a30: the next drawable surface; NULL until attached
 *   +0x20 bool swap(nw, mode, double time)    native_window_swap(_zero_time): queues the surface to CA
 *   +0x30 uint32 begin_properties(nw)         (version >= 2) orientation flags
 * GLEngine passes {renderbuffer, eagl_create_buffer (returns 1), eagl_destroy_buffer, eagl_preflight_properties};
 * ours are the same minus preflight (CA checks it for NULL, 0x18846a1b0). Present: flush, then
 * swap(nw, version >= 5 && time != 0 ? (after ? 5 : 3) : 1, time) [V 0x1f6f57e94]; the next frame draws
 * into the next begin_iosurface surface.
 *
 * Present = glFlush, not glFinish: the flush submits the batch, the kernel marks the drawable IOSurface
 * (its imported GEM buffer is listed in the submission, drm/negroni_drm.c s_gem_submit) with that
 * fence, and the display path waits on the fence recorded at swap time (patch 0254, docs/gpu-abi.md
 * section 8). The ring is in order, so a process that samples the surface later (backboardd) is ordered
 * behind the render too. glFinish comes back (the ios-spes default) with NEGRONIGL_FINISH=1, or the
 * file /var/db/negronigl/finish, or (NegroniGL.bundle, readable by sandboxed apps) BUNDLE/finish;
 * NEGRONIGL_FINISH=0 wins over the files. Without any of them the kernel decides (2026-10-26, patch
 * 0289): RedwoodGPU's property RedwoodWaitsForGPU = true says the IOSurface CPU lock waits for the
 * surface's GPU fence (the ios-spes/HackiOS `display_waits()` contract), so glFlush is enough for the
 * display chain (0254) and for a CPU reader (a snapshot, CA's CPU fallback); a kernel without the
 * property (older than 0289) gets glFinish.
 *
 * Rule: never crash the caller. A NULL pointer or a bad surface fails with false (EAGL returns NO).
 * [I] begin_iosurface can wait for a free drawable (CA's drawable timeout), as with Apple's GL.
 */
#include <dlfcn.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <CoreFoundation/CoreFoundation.h>
#include <IOSurface/IOSurfaceRef.h>

#include "negronigl.h"
#include "negroni_gpu_policy.h"

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

static int finish_mode = -1;    /* 1 = glFinish on every flush/present */

/* the bundle's own directory when this image is NegroniGL.bundle/NegroniGL, else "" */
static void
bundle_file(char *out, size_t size, const char *name)
{
	Dl_info info;
	out[0] = 0;
	if (dladdr((const void *)&bundle_file, &info) && info.dli_fname != NULL &&
	    strstr(info.dli_fname, ".bundle/") != NULL) {
		snprintf(out, size, "%s", info.dli_fname);
		char *slash = strrchr(out, '/');
		if (slash != NULL) {
			snprintf(slash + 1, size - (size_t)(slash + 1 - out), "%s", name);
		}
	}
}

static int
want_finish(const char **why)
{
	const char *e = getenv("NEGRONIGL_FINISH");
	if (e != NULL && e[0] != 0) {
		*why = "NEGRONIGL_FINISH";
		return ngl_env_on("NEGRONIGL_FINISH", false);
	}
	if (access(NGL_GATE_DIR "/finish", F_OK) == 0) {
		*why = NGL_GATE_DIR "/finish";
		return 1;
	}
	static char path[600];
	bundle_file(path, sizeof(path), "finish");
	if (path[0] != 0 && access(path, F_OK) == 0) {
		*why = path;
		return 1;
	}
	if (!ngl_drm_kernel_waits_for_gpu()) {
		*why = "the kernel has no RedwoodWaitsForGPU (older than 0289): the IOSurface lock does not wait for the GPU";
		return 1;
	}
	*why = "default: RedwoodWaitsForGPU";
	return 0;
}

void
ngl_flush(void)
{
	if (__builtin_expect(finish_mode < 0, 0)) {
		const char *why = "";
		finish_mode = want_finish(&why);
		ngl_log("negronigl: flush = %s (%s)", finish_mode ? "glFinish" : "glFlush + kernel fence", why);
	}
	if (finish_mode) {
		glFinish();
	} else {
		glFlush();
	}
	ngp_gl_frame_ok();      /* GPU policy dead-man: the first frames clear the armed GL strike */
}

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
	bool ok = ngl_bind_surface(s, GL_RENDERBUFFER, 0, 0, 0, "renderbufferStorage");
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

/* detach the drawable and release its surface. No GL calls (safe from dealloc on any thread). */
void
ngl_view_unbind(struct ngl_gli *g)
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
 * Attach (native_window != NULL) or detach (NULL) the drawable. On attach, the caller has bound the
 * renderbuffer that receives the storage (glBindRenderbuffer before the method). true = ok.
 */
bool
ngl_view_bind(struct ngl_gli *g, void *native_window, unsigned colorformat, unsigned retained)
{
	if (g == NULL) {
		return false;
	}
	ngl_view_unbind(g);                     /* drop the previous drawable, if any */
	if (native_window == NULL) {
		return true;                    /* detach only */
	}
	struct ngl_nw *nw = native_window;
	if (nw->attach == NULL || nw->detach == NULL || nw->begin_iosurface == NULL || nw->swap == NULL) {
		ngl_log("negronigl: renderbufferStorage: native window %p has no function table", native_window);
		return false;
	}
	NGL_CUR(g);
	GLint rb = 0;
	glGetIntegerv(GL_RENDERBUFFER_BINDING, &rb);
	if (rb <= 0) {
		ngl_log("negronigl: renderbufferStorage: no renderbuffer bound");
		return false;           /* no renderbuffer bound: nothing to give the storage to */
	}
	/* 'BGRA' for every color format: the one drawable format surface.c imports (GLEngine maps
	 * GL_RGB565 to 'L565' and two wide formats to 10-bit ones) */
	g->view_cb[0] = g;
	g->view_cb[1] = (void *)cb_create;
	g->view_cb[2] = (void *)cb_destroy;
	g->view_cb[3] = NULL;
	if (!nw->attach(nw, 'BGRA', g->view_cb)) {
		ngl_log("negronigl: renderbufferStorage: drawable attach failed (colorformat %#x)", colorformat);
		return false;
	}
	g->view = nw;
	if (nw->version >= 2 && nw->begin_properties != NULL) {
		(void)nw->begin_properties(nw);         /* orientation flags; rotation is not applied */
	}
	IOSurfaceRef s = valid_surface(nw->begin_iosurface(nw));
	if (s == NULL || !bind_storage(g, (GLuint)rb, s)) {
		static int logged;
		if (!__atomic_exchange_n(&logged, 1, __ATOMIC_RELAXED)) {
			ngl_log("negronigl: renderbufferStorage: no usable IOSurface from the drawable (colorformat %#x)",
			    colorformat);
		}
		ngl_view_unbind(g);
		return false;
	}
	g->view_rb = (GLuint)rb;
	g->view_colorformat = colorformat;
	static int logged;
	if (!__atomic_exchange_n(&logged, 1, __ATOMIC_RELAXED)) {
		ngl_log("negronigl: renderbufferStorage: drawable IOSurface %u (%zux%zu) bound as renderbuffer %d "
		    "(colorformat %#x, retained %u, window version %u)", IOSurfaceGetID(s), IOSurfaceGetWidth(s),
		    IOSurfaceGetHeight(s), rb, colorformat, retained, nw->version);
	}
	return true;
}

/*
 * Present the renderbuffer: flush (the kernel fence covers the drawable), swap hands the surface to
 * CoreAnimation, then the renderbuffer gets the next drawable surface. after_minimum / t: the
 * -presentRenderbuffer:afterMinimumDuration: / :atTime: forms (0, 0.0 = now).
 */
/* make CA's next drawable surface the renderbuffer storage; false = none (view_surface unchanged) */
static bool
next_drawable(struct ngl_gli *g, struct ngl_nw *nw)
{
	if (g->view_rb == 0 || !glIsRenderbuffer(g->view_rb)) {
		return false;
	}
	IOSurfaceRef s = valid_surface(nw->begin_iosurface(nw));
	if (s == NULL) {
		static int logged;
		if (!__atomic_exchange_n(&logged, 1, __ATOMIC_RELAXED)) {
			ngl_log("negronigl: presentRenderbuffer: no next drawable from CA (begin_iosurface NULL): "
			    "retried at the next present");
		}
		return false;
	}
	if (s == g->view_surface) {
		return true;
	}
	if (!bind_storage(g, g->view_rb, s)) {
		static int logged;
		if (!__atomic_exchange_n(&logged, 1, __ATOMIC_RELAXED)) {
			ngl_log("negronigl: presentRenderbuffer: next drawable IOSurface %u not bound", IOSurfaceGetID(s));
		}
		return false;
	}
	return true;
}

bool
ngl_view_present(struct ngl_gli *g, unsigned after_minimum, double t)
{
	if (g == NULL) {
		return false;
	}
	NGL_CUR(g);
	ngl_flush();
	struct ngl_nw *nw = g->view;
	if (nw == NULL) {
		static int logged;
		if (!__atomic_exchange_n(&logged, 1, __ATOMIC_RELAXED)) {
			ngl_log("negronigl: presentRenderbuffer: no drawable attached");
		}
		return false;
	}
	/* the last present got no next drawable (view_surface cleared): get one now, before the swap */
	if (g->view_surface == NULL && !next_drawable(g, nw)) {
		static int logged;
		if (!__atomic_exchange_n(&logged, 1, __ATOMIC_RELAXED)) {
			ngl_log("negronigl: presentRenderbuffer: still no drawable from CA: frame not presented "
			    "(retried at every present)");
		}
		return false;
	}
	uint32_t mode = nw->version >= 5 && t != 0.0 ? (after_minimum ? 5 : 3) : 1;
	bool ok = nw->swap(nw, mode, t);
	/* the swapped surface is CA's now: never draw into it again. No next drawable (begin_iosurface
	 * NULL, e.g. all buffers out) = view_surface cleared, retried at the next present. */
	if (!next_drawable(g, nw) && g->view_surface != NULL) {
		CFRelease(g->view_surface);
		g->view_surface = NULL;
	}
	static unsigned presents;
	unsigned n = __atomic_add_fetch(&presents, 1, __ATOMIC_RELAXED);
	if (n == 1 || n == 60 || (n % 3600) == 0) {
		ngl_log("negronigl: presentRenderbuffer #%u: swap %s (mode %u), drawable now IOSurface %u", n,
		    ok ? "ok" : "refused", mode, g->view_surface ? IOSurfaceGetID(g->view_surface) : 0);
	}
	return ok;
}
