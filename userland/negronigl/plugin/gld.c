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
#include <errno.h>
#include <sys/stat.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "gld.h"
#include "negronigl.h"
#include "negroni_gpu_policy.h"

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

/*
 * The app gate, decided once per process (docs/gpu-userland.md "GL driver for apps"). Control files
 * live in the bundle too (the NegroniMetal design): every process that loads the bundle can read it,
 * a sandboxed app cannot read /var/db, and an unreadable kill switch must not fail open.
 *   1. NEGRONIGL_APPS=1|0 in the environment wins (test tools).
 *   2. Off: BUNDLE/off exists, or cannot be checked (stat fails with anything but ENOENT): closed.
 *      /var/db/negronigl/off exists: closed (a sandbox EPERM/EACCES there leaves it to BUNDLE/off).
 *   3. Lists BUNDLE/apps (staged by gl-build.sh), BUNDLE/apps.local (the owner's, phone-gl.sh apps on)
 *      and /var/db/negronigl/apps: "*" = all, "-NAME" = never NAME; a "-NAME" in any file wins.
 *   4. The GPU: ngl_init() with freedreno (softpipe only with NEGRONIGL_ALLOW_SW=1 or
 *      NEGRONIGL_DRIVER=softpipe).
 * Closed = ngl_gli_register is not called: eagl_init binds GLEngine's table, GLEngine asks our
 * gldChoosePixelFormat, which refuses, and EAGLContexts are nil, as without the bundle.
 */
static bool
bundle_dir(char *out, size_t size)
{
	Dl_info info;
	if (!dladdr((const void *)&bundle_dir, &info) || info.dli_fname == NULL) {
		return false;
	}
	snprintf(out, size, "%s", info.dli_fname);
	char *slash = strrchr(out, '/');
	if (slash == NULL) {
		return false;
	}
	*slash = 0;
	return true;
}

/* 1 = exists, 0 = ENOENT, -1 = cannot check (errno in *err) */
static int
exists(const char *path, int *err)
{
	struct stat sb;
	if (stat(path, &sb) == 0) {
		return 1;
	}
	*err = errno;
	return errno == ENOENT ? 0 : -1;
}

static const char *
apps_closed(const char *prog, char *why, size_t size)
{
	char dir[512], path[600];
	int err = 0;
	if (!bundle_dir(dir, sizeof(dir))) {
		return "bundle path unknown (dladdr): fail closed";
	}
	snprintf(path, sizeof(path), "%s/off", dir);
	switch (exists(path, &err)) {
	case 1:
		snprintf(why, size, "%s exists", path);
		return why;
	case -1:
		snprintf(why, size, "cannot check %s (%s): fail closed", path, strerror(err));
		return why;
	}
	err = 0;
	if (exists(NGL_GATE_DIR "/off", &err) == 1) {
		return NGL_GATE_DIR "/off exists";
	}
	const char *lists[3] = {"apps", "apps.local", NULL};
	int any = 0;
	for (int i = 0; i < 3; i++) {
		if (lists[i] != NULL) {
			snprintf(path, sizeof(path), "%s/%s", dir, lists[i]);
		} else {
			snprintf(path, sizeof(path), "%s", NGL_GATE_DIR "/apps");
		}
		int c = ngl_gate_list(path, prog);
		if (c < 0) {
			snprintf(why, size, "listed as -%s in %s", prog, path);
			return why;
		}
		any |= c == 1;
	}
	if (!any) {
		snprintf(why, size, "not in %s/apps, %s/apps.local or " NGL_GATE_DIR "/apps", dir, dir);
		return why;
	}
	return NULL;
}

static void
policy_log(const char *line)
{
	ngl_log("negronigl: %s", line);
}

/*
 * GPU policy (userland/gpu-policy, docs/gpu-hybrid-plan.md), on top of the lists above:
 *   - fallback: a process the lists leave closed gets GL when its policy order puts gl after metal and Metal
 *     FAILED in this boot (NegroniMetal dead-man at the limit, or a failure record). A self-test (triangle +
 *     IOSurface) must pass first; a failed self-test marks GL failed for the process (next: CPU).
 *   - dead-man: an open gate arms a GL strike (cleared by the first frames, 15 s or exit); at the limit
 *     (NEGRONIGL_STRIKE_LIMIT, 2) GL stays closed for the process in this boot. Metal and GL both failed = CPU.
 *   - NEGRONIGPU=0, /var/db/negronigpu/off or BUNDLE/gpu-policy.off: the lists alone, as before.
 */
static bool
apps_gate(const char *prog)
{
	static int decided = -1;
	if (decided >= 0) {
		return decided == 1;
	}
	char buf[700], pw[1200], dir[512];
	const char *why = NULL;
	bool fallback = false, policy = !ngp_off();
	if (policy) {
		ngp_set_logger(policy_log);
	}
	const char *gl_bundle = bundle_dir(dir, sizeof(dir)) ? dir : NULL;
	const char *e = getenv("NEGRONIGL_APPS");
	if (e != NULL && e[0] != 0) {
		why = ngl_env_on("NEGRONIGL_APPS", false) ? NULL : "NEGRONIGL_APPS=0";
	} else {
		why = apps_closed(prog, buf, sizeof(buf));
		if (why != NULL && policy && ngp_gl_fallback(prog, NULL, gl_bundle, pw, sizeof(pw)) == NGP_GL) {
			ngl_log("negronigl: gpu-policy: GL as the fallback renderer for %s (%s)", prog, pw);
			why = NULL;
			fallback = true;
		}
	}
	if (why == NULL && policy && ngp_gl_health(prog, gl_bundle, pw, sizeof(pw)) == NGP_FAILED) {
		why = pw;
	}
	if (why == NULL && !ngl_init()) {
		why = "no GL screen (RedwoodGPU did not open and softpipe failed)";
	}
	if (why == NULL && ngl_soft()) {
		const char *d = getenv("NEGRONIGL_DRIVER");
		bool wanted = d != NULL && (strcmp(d, "softpipe") == 0 || strcmp(d, "sw") == 0);
		if (!wanted && !ngl_env_on("NEGRONIGL_ALLOW_SW", false)) {
			why = "screen is softpipe, not the GPU (NEGRONIGL_ALLOW_SW=1 allows it)";
		}
	}
	/* armed before the fallback self-test: a crash in it counts as an unclean start too */
	if (why == NULL && policy && !ngp_gl_arm(prog, pw, sizeof(pw))) {
		why = pw;
	}
	if (why == NULL && fallback && !(ngl_selftest() && ngl_surface_selftest())) {
		ngp_record_failure(prog, NGP_GL, "NegroniGL fallback self-test (triangle + IOSurface) failed");
		ngp_gl_disarm("fallback self-test failed: clean refusal, GL marked failed");
		why = "GL fallback self-test failed (GL marked failed for this boot)";
	}
	decided = why == NULL ? 1 : 0;
	if (why == NULL) {
		ngl_log("negronigl: NegroniGL app gate open for %s (%s%s)", prog, ngl_soft() ? "softpipe" : "freedreno",
		    fallback ? ", gpu-policy fallback" : "");
	} else {
		ngl_log("negronigl: NegroniGL app gate closed for %s: %s; EAGLContexts stay nil", prog, why);
	}
	return why == NULL;
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
		ngl_log_image_base();
	}
	/* eagl_init is inside GLEngine's gliInitializeLibrary now: hand OpenGLES our GLI table. Every
	 * load (also after gliTerminateLibrary let libGFXShared unload us); it is idempotent. */
	const char *prog = getprogname();
	if (apps_gate(prog ? prog : "?")) {
		ngl_gli_register();
	}
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
