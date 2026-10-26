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
 * The native window (_CAEAGLNativeWindow function table), the attach/begin_iosurface/swap order and
 * the flush-then-swap present are in ../view.c, shared with the dylib's EAGL shim (eagl.c
 * -renderbufferStorage:fromDrawable: / -presentRenderbuffer:). This file only adapts the GLI calls.
 *
 * Rule: never crash the caller. A NULL pointer or a bad surface fails with 0 (EAGL returns NO).
 * [I] begin_iosurface can wait for a free drawable (CA's drawable timeout), as with Apple's GL.
 */
#include <stdint.h>
#include <stddef.h>

#include "negronigl.h"
#include "gli.h"

/*
 * +0x88: attach (nativeWindow != NULL) or detach (NULL) the drawable. On attach, the app has bound
 * the renderbuffer that receives the storage (glBindRenderbuffer before the method). Nonzero = ok;
 * EAGL ignores the result of the detach call.
 */
NGL_GLD int
gliBindViewES(void *rctx, void *native_window, uint32_t retained, uint32_t colorformat)
{
	return ngl_view_bind(rctx, native_window, colorformat, retained) ? 1 : 0;
}

/*
 * +0x90: present the renderbuffer (view.c: flush, swap hands the surface to CoreAnimation, the
 * renderbuffer gets the next drawable surface). after_minimum: 0 = presentRenderbuffer: / atTime:,
 * 1 = afterMinimumDuration:; t in d0 (0 = now).
 */
NGL_GLD int
gliPresentViewES(void *rctx, uint32_t after_minimum, double t)
{
	return ngl_view_present(rctx, after_minimum, t) ? 1 : 0;
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
