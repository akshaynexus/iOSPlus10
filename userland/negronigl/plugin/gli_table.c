/*
 * NegroniGL.bundle GLI table: the 18 entry points OpenGLES's eagl_init binds into _gli_plugin, and
 * ngl_gli_register() that hands them over. Facts: docs/notes.md section 15 (20H392, unslid addrs).
 *
 * How EAGL picks up the table [V 20H392]: -[EAGLSharegroup initWithAPI:sharedWithCompute:] calls
 * eagl_init (0x1d3f52444). eagl_init dlopens GLEngine, stores the handle at _gli_plugin[0]
 * (0x1e25b0da0 + slide), calls gliInitializeLibrary. GLEngine's gliInitializeLibrary first calls
 * libGFXShared gfxInitializeLibrary (0x1d3f6e2f0), which reads IOGLESBundleName="NegroniGL" (patch
 * 0205), dlopens our bundle and calls gldInitializeLibrary -> ngl_gli_register (below). We overwrite
 * _gli_plugin[0] with our own bundle handle. When control returns to eagl_init, its loop (0x1d3f52648)
 * does dlsym(_gli_plugin[0], name) for each of the 18 _eagl_gli_names (0x1d3f53350) and stores the
 * result at _gli_plugin[+0x08 .. +0x90]; because the handle is now ours, it binds our exports. Then
 * eagl_init calls gliGetVersion (+0x80) and gliChoosePixelFormat (+0x08): nonzero version and a
 * non-NULL pixel format set _eagl_initialized (0x1e25b0e44). EAGLContexts then work.
 *
 * Order of _eagl_gli_names, so _gli_plugin offsets land where EAGL reads them [V, bytes at 0x1d3f53350]:
 *   +0x08 gliChoosePixelFormat   +0x10 gliDestroyPixelFormat   +0x18 gliQueryRendererInfo
 *   +0x20 gliDestroyRendererInfo +0x28 gliCreateContext        +0x30 gliCreateContextWithShared
 *   +0x38 gliDestroyContext      +0x40 gliAttachDrawable       +0x48 gliAttachDrawableWithOptions
 *   +0x50 gliSetInteger          +0x58 gliGetInteger           +0x60 gliGetAttribute
 *   +0x68 gliSetAttribute        +0x70 gliCopyAttributes       +0x78 gliGetMemoryAnnotationList
 *   +0x80 gliGetVersion          +0x88 gliBindViewES           +0x90 gliPresentViewES
 * EAGL reads +0x08 (choose), +0x30 (createWithShared), +0x38 (destroy), +0x50 (set), +0x58 (get),
 * +0x80 (version), +0x88 (bind), +0x90 (present). The rest exist so the loop never binds NULL.
 *
 * Rule: no call crashes or blocks. What is not ready returns a CGL error code.
 */
#include <dlfcn.h>
#include <stdint.h>
#include <string.h>

#include "gli.h"
#include "negroni_drm.h"

/* 20H392 shared-cache unslid addresses [V, out/gpu/re/OpenGLES.s]. The whole cache shares one slide,
 * so slide = &EAGLGetVersion - its unslid address, and every other address adds the same slide. */
#define NGL_UNSLID_EAGLGetVersion    0x1d3f52878ull
#define NGL_UNSLID_gli_plugin        0x1e25b0da0ull
#define NGL_UNSLID_eagl_initialized  0x1e25b0e44ull

void
ngl_gli_register(void)
{
	static int done;
	if (__atomic_exchange_n(&done, 1, __ATOMIC_RELAXED)) {
		return;                 /* register once; gldInitializeLibrary may be called per accelerator */
	}
	void *ev = dlsym(RTLD_DEFAULT, "EAGLGetVersion");
	if (ev == NULL) {
		ngl_log("negronigl: GLI register: no EAGLGetVersion (OpenGLES not loaded?)");
		return;
	}
	intptr_t slide = (intptr_t)(uintptr_t)ev - (intptr_t)NGL_UNSLID_EAGLGetVersion;
	void **gli = (void **)(uintptr_t)((intptr_t)NGL_UNSLID_gli_plugin + slide);
	const volatile uint8_t *inited = (const uint8_t *)(uintptr_t)((intptr_t)NGL_UNSLID_eagl_initialized + slide);
	/* eagl_init is mid-flight: GLEngine's handle is at gli[0] and EAGL is not initialized yet. If the
	 * layout does not match this build, bail without writing (EAGL stays as it was, no crash). */
	if (*inited != 0 || gli[0] == NULL) {
		ngl_log("negronigl: GLI register: unexpected state (initialized=%d, plugin0=%p); not installed",
		    (int)*inited, gli[0]);
		return;
	}
	Dl_info info;
	if (!dladdr((const void *)&ngl_gli_register, &info) || info.dli_fname == NULL) {
		return;
	}
	void *self = dlopen(info.dli_fname, RTLD_LAZY | RTLD_NOLOAD | RTLD_NODELETE);
	if (self == NULL) {
		ngl_log("negronigl: GLI register: dlopen(self) failed");
		return;
	}
	gli[0] = self;                  /* eagl_init's dlsym loop now binds our gli* exports */
	ngl_log("negronigl: GLI table installed in OpenGLES _gli_plugin (slide %#lx)", (long)slide);
}

/* +0x08: eagl_init stores *out at _gli_pixelformat; -[EAGLSharegroup init..] needs flags bit 0x100
 * (and 0x20000 for API 3), which ngl_pf.flags (0x225dd, gld.c) has. ngl_pf.device_id = our gld device. */
NGL_GLD int
gliChoosePixelFormat(void **out, const int *attribs)
{
	(void)attribs;
	if (out != NULL) {
		*out = &ngl_pf;
	}
	static int logged;
	if (!__atomic_exchange_n(&logged, 1, __ATOMIC_RELAXED)) {
		ngl_log("negronigl: gliChoosePixelFormat -> NegroniGL pixel format (device %#x, flags %#x)",
		    ngl_pf.device_id, ngl_pf.flags);
	}
	return 0;
}

NGL_GLD int
gliDestroyPixelFormat(void *pf)
{
	(void)pf;                       /* ngl_pf is static */
	return 0;
}

/* +0x80: eagl_init needs a nonzero return; GLEngine reports (2, 3, 0x20000) here. */
NGL_GLD int
gliGetVersion(int *a, int *b, int *c)
{
	if (a != NULL) {
		*a = 2;
	}
	if (b != NULL) {
		*b = 3;
	}
	if (c != NULL) {
		*c = 0x20000;
	}
	return 1;
}

/* +0x28: the non-shared context entry (macOS CGL name). iOS EAGL uses gliCreateContextWithShared;
 * if something does call this, make a context with no sharing. Unknown exact arg order on 20H392, so
 * forward only the shape EAGL's createWithShared uses, minus the shared-state argument. */
NGL_GLD int
gliCreateContext(void **out, void *pf, void *disp1, void *disp2, uint32_t flags)
{
	return gliCreateContextWithShared(out, pf, NULL, disp1, disp2, flags);
}

/* +0x18/+0x20: renderer-info queries (gliQueryRendererInfo). We publish no GLD renderer info. */
NGL_GLD int
gliQueryRendererInfo(void *a, void *b, void *c)
{
	(void)a;
	(void)b;
	(void)c;
	return NGL_ERR_BAD_RENDERER_INFO;
}

NGL_GLD int
gliDestroyRendererInfo(void *info)
{
	(void)info;
	return 0;
}

/* +0x60..+0x78: attribute/annotation queries, not used by the iOS EAGL path; succeed as no-ops. */
NGL_GLD int
gliGetAttribute(void *ctx, int attr, int *value)
{
	(void)ctx;
	(void)attr;
	if (value != NULL) {
		*value = 0;
	}
	return 0;
}

NGL_GLD int
gliSetAttribute(void *ctx, int attr, const int *value)
{
	(void)ctx;
	(void)attr;
	(void)value;
	return 0;
}

NGL_GLD int
gliCopyAttributes(void *dst, void *src, uint32_t mask)
{
	(void)dst;
	(void)src;
	(void)mask;
	return 0;
}

NGL_GLD int
gliGetMemoryAnnotationList(void *ctx, void *out, void *count)
{
	(void)ctx;
	if (out != NULL) {
		*(void **)out = NULL;
	}
	if (count != NULL) {
		*(uint32_t *)count = 0;
	}
	return 0;
}
