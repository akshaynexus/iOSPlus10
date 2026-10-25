/*
 * NegroniGL.bundle: the GLD renderer plugin that libGFXShared loads for IOAcceleratorES
 * (IOGLESBundleName = "NegroniGL", kernel patch 0205).
 *
 * Load path on 20H392 [V, docs/notes.md section 15]: -[EAGLSharegroup initWithAPI:sharedWithCompute:]
 * -> eagl_init -> GLEngine gliInitializeLibrary -> libGFXShared gfxInitializeLibrary -> dlopen
 * /System/Library/Extensions/NegroniGL.bundle/NegroniGL -> gldInitializeLibrary, gldGetVersion
 * (must be 4, 1, 0x10, id) and dlsym of all 129 names (gld-names.txt; the generated gld_stubs.c has
 * the ones not here). Then per accelerator: gldCreateDevice. eagl_init fills OpenGLES's _gli_plugin
 * table with GLEngine's 18 GLI functions, asks gliGetVersion and gliChoosePixelFormat; GLEngine's
 * gliChoosePixelFormat calls our gldChoosePixelFormat. GLEngine itself would need a real GLD
 * renderer (render dispatch, state readback); the bundle does not provide one. Instead
 * gldInitializeLibrary -> ngl_gli_register (gli_table.c) points _gli_plugin[0] at this bundle, so
 * eagl_init binds our own gli* entries on Mesa; gldChoosePixelFormat refuses (GLEngine path only).
 * The sharegroup asks libGFXShared for a shared state: gldCreateShareGroup.
 *
 * Rule: no call may crash or block the caller. What is not ready fails with a CGL error code.
 */
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "gld.h"
#include "negroni_drm.h"

/* Apple's defaults (AppleMetalGLRenderer GLRPixelFormat::preflight, 20H392 0x209fd28d0/0x209fd28e0) */
struct ngl_pixel_format ngl_pf = {
	.next = NULL,
	.device_id = 0x01000000u | NGL_GFX_PLUGIN_BIT | NGL_DRIVER_ID,
	.flags = 0x000225ddu,
	.words = {0, 0x08000000u, 0x80000000u, 1, 1},
};

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static int library_refs;
static uint32_t device_count;

int
ngl_gld_unexpected(int index, const char *name)
{
	static unsigned char seen[129];
	if (index >= 0 && index < 129 && !__atomic_exchange_n(&seen[index], 1, __ATOMIC_RELAXED)) {
		ngl_log("negronigl: NegroniGL: unexpected GLD call %s (index %d): kCGLBadState", name, index);
	}
	return NGL_ERR_BAD_STATE;
}

/* never unloaded: Mesa keeps process-wide state (glapi TLS, the screen) that dlclose would break */
static void
pin_self(void)
{
	Dl_info info;
	if (dladdr((const void *)&pin_self, &info) && info.dli_fname != NULL) {
		void *h = dlopen(info.dli_fname, RTLD_LAZY | RTLD_NOLOAD | RTLD_NODELETE);
		(void)h;                        /* one reference that is never dropped */
	}
}

NGL_GLD void
gldInitializeLibrary(const uint32_t *services, void *io_data, uint32_t mask, void *get_surface_props,
    void *get_new_surface, uint32_t flags)
{
	(void)io_data;
	(void)get_surface_props;
	(void)get_new_surface;
	pthread_mutex_lock(&lock);
	bool first = library_refs++ == 0;
	pthread_mutex_unlock(&lock);
	if (first) {
		pin_self();
		const char *prog = getprogname();
		ngl_log("negronigl: NegroniGL.bundle loaded into %s (pid %d): service %#x mask %#x flags %#x",
		    prog ? prog : "?", getpid(), services ? services[0] : 0, mask, flags);
	}
	/* eagl_init is inside GLEngine's gliInitializeLibrary now: hand OpenGLES our GLI table. Every
	 * load (also after gliTerminateLibrary let libGFXShared unload us); it is idempotent. */
	ngl_gli_register();
}

NGL_GLD void
gldTerminateLibrary(void)
{
	pthread_mutex_lock(&lock);
	if (library_refs > 0) {
		library_refs--;
	}
	pthread_mutex_unlock(&lock);
}

NGL_GLD int
gldGetVersion(int *major, int *minor, int *revision, int *driver_id)
{
	if (major == NULL || minor == NULL || revision == NULL || driver_id == NULL) {
		return 0;
	}
	*major = 4;
	*minor = 1;
	*revision = 0x10;
	*driver_id = (int)NGL_DRIVER_ID;
	return 1;
}

/*
 * libGFXShared: gldCreateDevice(&device->gld (+0x18), device->mask (+0x14), &device->info (+0x20));
 * device->id (+0x10) = plugin ID | count << 24 is set before the call. Apple writes info = {0, 1}.
 */
struct ngl_device {
	uint32_t magic, id, mask;
};
#define NGL_DEVICE_MAGIC 0x4e474c44u    /* 'NGLD' */

NGL_GLD int
gldCreateDevice(void **out, uint32_t mask, uint8_t *info)
{
	if (out == NULL) {
		return NGL_ERR_BAD_ATTRIBUTE;
	}
	*out = NULL;
	struct ngl_device *d = calloc(1, sizeof(*d));
	if (d == NULL) {
		return NGL_ERR_BAD_ALLOC;
	}
	d->magic = NGL_DEVICE_MAGIC;
	d->mask = mask;
	/* the ID libGFXShared gave this device: 4 bytes before &device->gld [V gfxInitializeLibrary 0x1d3f6ea78] */
	uint32_t id = *(const uint32_t *)((const char *)out - 8);
	if ((id & 0xffff00u) != (NGL_GFX_PLUGIN_BIT | NGL_DRIVER_ID)) {
		id = 0x01000000u | NGL_GFX_PLUGIN_BIT | NGL_DRIVER_ID;
	}
	d->id = id;
	pthread_mutex_lock(&lock);
	if (device_count++ == 0) {
		ngl_pf.device_id = id;      /* the pixel format names this device (gfxCreateSharedState) */
	}
	pthread_mutex_unlock(&lock);
	if (info != NULL) {
		memset(info, 0, 4);
		info[4] = 1;
	}
	*out = d;
	return 0;
}

NGL_GLD int
gldDestroyDevice(void *device)
{
	struct ngl_device *d = device;
	if (d != NULL && d->magic == NGL_DEVICE_MAGIC) {
		d->magic = 0;
		free(d);
		pthread_mutex_lock(&lock);
		if (device_count > 0) {
			device_count--;
		}
		pthread_mutex_unlock(&lock);
	}
	return 0;
}

/*
 * The GLD-plugin pixel format: refused on purpose. The only caller is GLEngine's gliChoosePixelFormat
 * (plugin record +0x468, GLEngine 0x1f6e96574; libGFXShared, OpenGLES, libGLImage, libCoreVMClient,
 * CoreImage and QuartzCore never read +0x468 [V out/gpu/re]). GLEngine's gli* functions are bound
 * only when ngl_gli_register did not install our table (wrong OpenGLES build, or a second
 * gfxInitializeLibrary that did not reload us). A format here would then make GLEngine drive the
 * bundle as a GLD renderer (25-entry render dispatch, gldCreateContext ...), which we do not have.
 * With the refusal eagl_init fails cleanly (nil EAGLContexts). The EAGL path takes ngl_pf from our
 * own gliChoosePixelFormat (gli_table.c); libGFXShared reads only its device ID (+8, gfxCreateSharedState).
 */
NGL_GLD int
gldChoosePixelFormat(void **out, const int *attribs)
{
	(void)attribs;
	if (out != NULL) {
		*out = NULL;
	}
	static int logged;
	if (!__atomic_exchange_n(&logged, 1, __ATOMIC_RELAXED)) {
		ngl_log("negronigl: NegroniGL gldChoosePixelFormat: GLEngine path (our GLI table is not "
		    "installed): no pixel format, EAGL contexts stay nil");
	}
	return NGL_ERR_BAD_PIXEL_FORMAT;
}

NGL_GLD int
gldDestroyPixelFormat(void *pf)
{
	(void)pf;                       /* static */
	return 0;
}

/*
 * libGFXShared gfxCreateSharedState (EAGLSharegroup -loadGLIPlugin:): gldCreateShareGroup(device->gld,
 * &entry->gld, 4); nonzero = no sharegroup = nil EAGLContext.
 */
struct ngl_share_group {
	uint32_t magic;
};
#define NGL_SHARE_MAGIC 0x4e474c53u     /* 'NGLS' */

NGL_GLD int
gldCreateShareGroup(void *device, void **out, int kind)
{
	(void)device;
	(void)kind;
	if (out == NULL) {
		return NGL_ERR_BAD_ATTRIBUTE;
	}
	struct ngl_share_group *g = calloc(1, sizeof(*g));
	if (g == NULL) {
		*out = NULL;
		return NGL_ERR_BAD_ALLOC;
	}
	g->magic = NGL_SHARE_MAGIC;
	*out = g;
	return 0;
}

NGL_GLD int
gldDestroyShareGroup(void *group)
{
	struct ngl_share_group *g = group;
	if (g != NULL && g->magic == NGL_SHARE_MAGIC) {
		g->magic = 0;
		free(g);
	}
	return 0;
}

/* GLEngine's gliQueryRendererInfo path: no renderer info from this plugin */
NGL_GLD int
gldPopulateRendererInfo(void *device, void *out)
{
	(void)device;
	(void)out;
	return NGL_ERR_BAD_RENDERER_INFO;
}

/* GLEngine context creation: GLEngine gets no pixel format from us, so it is not reached; fail cleanly */
NGL_GLD int
gldCreateContext(void **out)
{
	if (out != NULL) {
		*out = NULL;
	}
	ngl_gld_unexpected(13, "gldCreateContext");
	return NGL_ERR_BAD_CONTEXT;
}

NGL_GLD int
gldDestroyContext(void *ctx)
{
	(void)ctx;
	return 0;
}

NGL_GLD int
gldReclaimContext(void *ctx)
{
	(void)ctx;
	return 0;
}
