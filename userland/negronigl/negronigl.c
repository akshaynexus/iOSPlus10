/*
 * negronigl: Mesa (gallium freedreno + GLES 3.x) as a library inside iOS processes.
 *
 * A minimal gallium frontend (like Mesa's frontends/hgl and ios-sailfish tools/sweetgl/sweetgl.c):
 * one pipe_screen over the msm DRM emulation (drm/negroni_drm.c), GLES contexts made current
 * without a drawable. CoreAnimation draws into FBOs only, whose color buffers are IOSurfaces
 * (surface.c); nothing here needs a window system.
 *
 * Load hook (ngl_load): the EAGL shim (eagl.c) is installed in a process only when
 *   1. the gate says so: /var/db/negronigl/off absent, and the process name is listed in
 *      /var/db/negronigl/clients ("*" = all, "-NAME" = never NAME; no file = nobody), or
 *      NEGRONIGL_EAGL=1 in the environment (NEGRONIGL_EAGL=0 = never), and
 *   2. the preflight passes (ngl_preflight, the port of ios-spes xnu/graphics/spes_gl_preflight.c):
 *      RedwoodGPU is there within NEGRONIGL_WAIT s (default 30), the screen is freedreno (renderer
 *      has "FD730"; softpipe only with NEGRONIGL_ALLOW_SW=1), ngl_selftest() and
 *      ngl_surface_selftest() PASS. NEGRONIGL_PREFLIGHT=0 skips step 2.
 *   A failed step leaves Apple's EAGL methods untouched, so backboardd runs as before.
 * NEGRONIGL_TEST=1 also runs the self tests on a thread at load, with retries while RedwoodGPU is
 * not there yet; results go to the log (log.c).
 *
 * Environment (defaults set here, a value in the environment wins):
 *   FD_MESA_DEBUG=sysmem      no GMEM tiling: GMEM resolves write whole tile rows, past the end
 *                             of IOSurfaces that are not padded for it (ios-sailfish boot 0154a)
 *   IR3_SHADER_DEBUG=nofp16   CA's mediump/lowp texture coordinates need fp32 (ios-sailfish)
 */
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <mach/mach_time.h>
#include <sys/sysctl.h>

#include "pipe/p_screen.h"
#include "pipe/p_context.h"
#include "frontend/api.h"
#include "state_tracker/st_context.h"
#include "util/driconf.h"
#include "util/xmlconfig.h"
#include "freedreno/drm/freedreno_drm_public.h"
#include "softpipe/sp_public.h"
#include "frontend/sw_winsys.h"

#include "negronigl.h"

#ifndef NEGRONIGL_MESA_VERSION
#define NEGRONIGL_MESA_VERSION "?"
#endif

static const driOptionDescription ngl_driconf[] = {
#include "freedreno/driinfo_freedreno.h"
};

struct ngl_ctx {
	struct st_context *st;
	int api;
};

static pthread_mutex_t init_lock = PTHREAD_MUTEX_INITIALIZER;
static struct pipe_frontend_screen *fscreen;
static driOptionCache opt_info, opts;

bool
ngl_env_on(const char *name, bool dflt)
{
	const char *v = getenv(name);
	if (v == NULL || v[0] == 0) {
		return dflt;
	}
	return !(v[0] == '0' || v[0] == 'n' || v[0] == 'N' || v[0] == 'f' || v[0] == 'F');
}

const char *
ngl_version(void)
{
	return "negronigl (Mesa " NEGRONIGL_MESA_VERSION ", freedreno A730 / softpipe)";
}

bool
ngl_gpu_info(struct ngl_gpu_info *info)
{
	return ngl_drm_info(info);
}

/*
 * Which gallium driver: NEGRONIGL_DRIVER=freedreno|softpipe|auto in the environment, else the
 * boot-arg negronigl_sw=1 (softpipe in every process), else auto: freedreno when RedwoodGPU opens,
 * softpipe when it does not (no GPU kernel path, or a sandbox without access to it).
 */
enum ngl_driver { NGL_DRV_AUTO, NGL_DRV_FREEDRENO, NGL_DRV_SOFTPIPE };

static enum ngl_driver
wanted_driver(void)
{
	const char *e = getenv("NEGRONIGL_DRIVER");
	if (e != NULL && (strcmp(e, "softpipe") == 0 || strcmp(e, "sw") == 0)) {
		return NGL_DRV_SOFTPIPE;
	}
	if (e != NULL && (strcmp(e, "freedreno") == 0 || strcmp(e, "gpu") == 0)) {
		return NGL_DRV_FREEDRENO;
	}
	char args[1024] = "";
	size_t n = sizeof(args) - 1;
	if (sysctlbyname("kern.bootargs", args, &n, NULL, 0) == 0) {
		args[n < sizeof(args) ? n : sizeof(args) - 1] = 0;
		for (char *p = strstr(args, "negronigl_sw="); p != NULL; p = strstr(p + 1, "negronigl_sw=")) {
			if ((p == args || p[-1] == ' ') && p[13] == '1') {
				return NGL_DRV_SOFTPIPE;
			}
		}
	}
	return NGL_DRV_AUTO;
}

static bool soft;

bool
ngl_soft(void)
{
	return soft;
}

static struct pipe_screen *
freedreno_screen(void)
{
	int fd = ngl_drm_open();
	if (fd < 0) {
		return NULL;
	}
	setenv("FD_MESA_DEBUG", "sysmem", 0);
	setenv("IR3_SHADER_DEBUG", "nofp16", 0);
	driParseOptionInfo(&opt_info, ngl_driconf, ARRAY_SIZE(ngl_driconf));
	driParseConfigFiles(&opts, &opt_info, 0, "msm", NULL, NULL, NULL, 0, NULL, 0);
	struct pipe_screen_config cfg = {.options = &opts, .options_info = &opt_info};
	struct pipe_screen *screen = fd_drm_screen_create_renderonly(fd, NULL, &cfg);
	if (screen == NULL) {
		ngl_log("negronigl: freedreno screen creation failed");
		close(fd);
	}
	return screen;
}

/* st_api_create_context calls fscreen->get_param unconditionally (st_manager.c, Mesa 25.0.7):
 * without it the first context jumps to address 0. ST_MANAGER_BROKEN_INVALIDATE = 0: we have no
 * window drawables (CA draws into FBOs on IOSurface images), so glViewport has nothing to
 * invalidate. */
static int
ngl_get_param(struct pipe_frontend_screen *fs, enum st_manager_param param)
{
	(void)fs;
	(void)param;
	return 0;
}

/* Once per process: the load address of this image, so a crash pc/lr can be symbolicated
 * against the unstripped build (out/gpu/negronigl.dylib, out/gpu/NegroniGL.bundle/NegroniGL). */
void
ngl_log_image_base(void)
{
	static bool done;
	if (done) {
		return;
	}
	done = true;
	Dl_info info = { 0 };
	if (dladdr((void *)ngl_log_image_base, &info) == 0) {
		ngl_log("negronigl: image base unknown (dladdr failed)");
		return;
	}
	ngl_log("negronigl: image base %p %s (atos -o out/gpu/%s -l BASE ADDR)", info.dli_fbase,
	    info.dli_fname ? info.dli_fname : "?",
	    info.dli_fname && strstr(info.dli_fname, "NegroniGL.bundle") ? "NegroniGL.bundle/NegroniGL" : "negronigl.dylib");
}

bool
ngl_init(void)
{
	pthread_mutex_lock(&init_lock);
	if (fscreen == NULL) {
		enum ngl_driver want = wanted_driver();
		struct pipe_screen *screen = want != NGL_DRV_SOFTPIPE ? freedreno_screen() : NULL;
		if (screen == NULL && want != NGL_DRV_FREEDRENO) {
			struct sw_winsys *ws = ngl_sw_winsys_create();
			screen = ws ? softpipe_create_screen(ws) : NULL;
			if (screen == NULL && ws != NULL) {
				ws->destroy(ws);
			}
			soft = screen != NULL;
		}
		if (screen != NULL) {
			struct pipe_frontend_screen *f = calloc(1, sizeof(*f));
			if (f == NULL) {
				screen->destroy(screen);
			} else {
				f->screen = screen;
				f->get_param = ngl_get_param;  /* called by every st_api_create_context */
				ngl_image_hooks(f);     /* before any context: st reads them at creation */
				fscreen = f;
				ngl_log("negronigl: %s, screen %s (%s)%s", ngl_version(), screen->get_name(screen),
				    screen->get_vendor(screen), soft ? ", CPU (softpipe)" : "");
			}
		}
	}
	bool ok = fscreen != NULL;
	pthread_mutex_unlock(&init_lock);
	return ok;
}

struct pipe_screen *
ngl_screen(void)
{
	return fscreen ? fscreen->screen : NULL;
}

struct ngl_ctx *
ngl_create(int api, struct ngl_ctx *share)
{
	if (!ngl_init()) {
		return NULL;
	}
	struct st_context_attribs attribs = {
		.profile = API_OPENGLES2,
		.major = api >= 3 ? 3 : 2,
		/* 3.1: glGetTexLevelParameteriv (rectangle texture sizes in eagl.c) */
		.minor = api >= 3 ? 1 : 0,
	};
	enum st_context_error err = ST_CONTEXT_SUCCESS;
	struct st_context *st = st_api_create_context(fscreen, &attribs, &err, share ? share->st : NULL);
	if (st == NULL && attribs.major == 3 && attribs.minor == 1) {
		attribs.minor = 0;              /* a driver without ES 3.1 */
		st = st_api_create_context(fscreen, &attribs, &err, share ? share->st : NULL);
	}
	if (st == NULL) {
		ngl_log("negronigl: GLES %d.%d context failed: %d", attribs.major, attribs.minor, err);
		return NULL;
	}
	struct ngl_ctx *c = calloc(1, sizeof(*c));
	if (c == NULL) {
		st_destroy_context(st);
		return NULL;
	}
	c->st = st;
	c->api = attribs.major;
	st->frontend_context = c;
	return c;
}

bool
ngl_make_current(struct ngl_ctx *c)
{
	return st_api_make_current(c ? c->st : NULL, NULL, NULL);
}

void
ngl_destroy(struct ngl_ctx *c)
{
	if (c == NULL) {
		return;
	}
	if (st_api_get_current() == c->st) {
		st_api_make_current(NULL, NULL, NULL);
	}
	st_destroy_context(c->st);
	free(c);
}

/* ---- self tests ---- */

static double
ms_since(uint64_t t0)
{
	static mach_timebase_info_data_t tb;
	if (tb.denom == 0) {
		mach_timebase_info(&tb);
	}
	return (double)(mach_absolute_time() - t0) * tb.numer / tb.denom / 1e6;
}

static GLuint
shader(GLenum type, const char *src)
{
	GLuint s = glCreateShader(type);
	glShaderSource(s, 1, &src, NULL);
	glCompileShader(s);
	GLint ok = 0;
	glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
	if (!ok) {
		char log[256] = "";
		glGetShaderInfoLog(s, sizeof(log), NULL, log);
		ngl_log("negronigl: selftest shader: %s", log);
	}
	return s;
}

static GLuint
red_program(void)
{
	GLuint prog = glCreateProgram();
	glAttachShader(prog, shader(GL_VERTEX_SHADER,
	    "#version 300 es\nlayout(location = 0) in vec2 p;\nvoid main() { gl_Position = vec4(p, 0.0, 1.0); }\n"));
	glAttachShader(prog, shader(GL_FRAGMENT_SHADER,
	    "#version 300 es\nprecision mediump float;\nout vec4 c;\nvoid main() { c = vec4(1.0, 0.0, 0.0, 1.0); }\n"));
	glLinkProgram(prog);
	return prog;
}

/* clear blue, red triangle over the lower left half of the bound 256x256 framebuffer */
static void
draw_test_frame(GLuint prog)
{
	static const float tri[] = {-1, -1, 1, -1, -1, 1};
	GLuint vbo;
	glGenBuffers(1, &vbo);
	glBindBuffer(GL_ARRAY_BUFFER, vbo);
	glBufferData(GL_ARRAY_BUFFER, sizeof(tri), tri, GL_STATIC_DRAW);
	glEnableVertexAttribArray(0);
	glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, 0);
	glUseProgram(prog);
	glViewport(0, 0, 256, 256);
	glClearColor(0, 0, 1, 1);
	glClear(GL_COLOR_BUFFER_BIT);
	glDrawArrays(GL_TRIANGLES, 0, 3);
	glDeleteBuffers(1, &vbo);
}

bool
ngl_selftest(void)
{
	uint64_t t0 = mach_absolute_time();
	struct ngl_ctx *c = ngl_create(3, NULL);
	if (c == NULL || !ngl_make_current(c)) {
		ngl_log("negronigl: selftest: no context");
		ngl_destroy(c);
		return false;
	}
	double t_ctx = ms_since(t0);
	ngl_log("negronigl: GL_VERSION %s / GL_RENDERER %s / GLSL %s", glGetString(GL_VERSION),
	    glGetString(GL_RENDERER), glGetString(GL_SHADING_LANGUAGE_VERSION));

	GLuint tex, fbo;
	glGenTextures(1, &tex);
	glBindTexture(GL_TEXTURE_2D, tex);
	glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, 256, 256);
	glGenFramebuffers(1, &fbo);
	glBindFramebuffer(GL_FRAMEBUFFER, fbo);
	glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
	GLenum fbs = glCheckFramebufferStatus(GL_FRAMEBUFFER);
	GLuint prog = red_program();
	GLint linked = 0;
	glGetProgramiv(prog, GL_LINK_STATUS, &linked);

	uint64_t t1 = mach_absolute_time();
	draw_test_frame(prog);
	static uint8_t px[256 * 256 * 4];
	glReadPixels(0, 0, 256, 256, GL_RGBA, GL_UNSIGNED_BYTE, px);
	double t_draw = ms_since(t1);
	GLenum err = glGetError();
	const uint8_t *a = &px[(32 * 256 + 32) * 4], *b = &px[(224 * 256 + 224) * 4];
	bool ok = fbs == GL_FRAMEBUFFER_COMPLETE && linked && err == GL_NO_ERROR &&
	    a[0] == 255 && a[1] == 0 && a[2] == 0 && a[3] == 255 && b[0] == 0 && b[1] == 0 && b[2] == 255 && b[3] == 255;
	ngl_log("negronigl: selftest fbo %#x linked %d err %#x px(32,32) %02x%02x%02x%02x px(224,224) %02x%02x%02x%02x "
	    "context %.1f ms draw+readback %.2f ms: %s", fbs, linked, err, a[0], a[1], a[2], a[3], b[0], b[1], b[2], b[3],
	    t_ctx, t_draw, ok ? "PASS" : "FAIL");

	uint64_t t2 = mach_absolute_time();
	draw_test_frame(prog);
	glFinish();
	ngl_log("negronigl: second frame clear+draw+finish %.2f ms", ms_since(t2));
	glDeleteFramebuffers(1, &fbo);
	glDeleteTextures(1, &tex);
	glDeleteProgram(prog);
	ngl_make_current(NULL);
	ngl_destroy(c);
	return ok;
}

/*
 * A 256x256 BGRA IOSurface as the color buffer (the path CA's render targets take), triangle
 * drawn, read back on the CPU through the surface's own mapping.
 */
bool
ngl_surface_selftest(void)
{
	const void *keys[] = {kIOSurfaceWidth, kIOSurfaceHeight, kIOSurfaceBytesPerElement, kIOSurfacePixelFormat,
	    kIOSurfaceBytesPerRow};
	int w = 256, h = 256, bpe = 4, fmt = 'BGRA', pitch = 1024;
	CFNumberRef vals[5] = {CFNumberCreate(NULL, kCFNumberIntType, &w), CFNumberCreate(NULL, kCFNumberIntType, &h),
	    CFNumberCreate(NULL, kCFNumberIntType, &bpe), CFNumberCreate(NULL, kCFNumberIntType, &fmt),
	    CFNumberCreate(NULL, kCFNumberIntType, &pitch)};
	CFDictionaryRef props = CFDictionaryCreate(NULL, keys, (const void **)vals, 5, &kCFTypeDictionaryKeyCallBacks,
	    &kCFTypeDictionaryValueCallBacks);
	IOSurfaceRef s = IOSurfaceCreate(props);
	CFRelease(props);
	for (int i = 0; i < 5; i++) {
		CFRelease(vals[i]);
	}
	if (s == NULL) {
		ngl_log("negronigl: surface selftest: IOSurfaceCreate failed");
		return false;
	}
	struct ngl_ctx *c = ngl_create(3, NULL);
	if (c == NULL || !ngl_make_current(c)) {
		ngl_destroy(c);
		CFRelease(s);
		return false;
	}
	GLuint tex, fbo;
	glGenTextures(1, &tex);
	glBindTexture(GL_TEXTURE_2D, tex);
	bool bound = ngl_bind_surface(s, GL_TEXTURE_2D, GL_BGRA_EXT, GL_UNSIGNED_BYTE, 0, "selftest");
	glGenFramebuffers(1, &fbo);
	glBindFramebuffer(GL_FRAMEBUFFER, fbo);
	glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
	GLenum fbs = glCheckFramebufferStatus(GL_FRAMEBUFFER);
	GLuint prog = red_program();
	draw_test_frame(prog);
	glFinish();
	IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL);
	const uint8_t *base = IOSurfaceGetBaseAddress(s);
	size_t row = IOSurfaceGetBytesPerRow(s);
	/* GL row 32 from the bottom = memory row 32 (GL's origin is the first row in memory) */
	const uint8_t *a = base + 32 * row + 32 * 4, *b = base + 224 * row + 224 * 4;
	bool ok = bound && fbs == GL_FRAMEBUFFER_COMPLETE && a[2] == 255 && a[0] == 0 && b[0] == 255 && b[2] == 0;
	ngl_log("negronigl: surface selftest bound %d fbo %#x BGRA(32,32) %02x%02x%02x%02x BGRA(224,224) "
	    "%02x%02x%02x%02x: %s", bound, fbs, a[0], a[1], a[2], a[3], b[0], b[1], b[2], b[3], ok ? "PASS" : "FAIL");
	IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
	glDeleteFramebuffers(1, &fbo);
	glDeleteTextures(1, &tex);
	glDeleteProgram(prog);
	ngl_make_current(NULL);
	ngl_destroy(c);
	CFRelease(s);
	return ok;
}

static void *
selftest_thread(void *arg)
{
	(void)arg;
	for (int i = 0; i < 120 && !ngl_init(); i++) {   /* RedwoodGPU starts during boot */
		sleep(1);
	}
	if (!ngl_init()) {
		ngl_log("negronigl: selftest: no GPU after 2 minutes");
		return NULL;
	}
	ngl_selftest();
	ngl_surface_selftest();
	return NULL;
}

/* ---- the gates: /var/db/negronigl/{clients,apps,off} (same form as the Metal path's /var/db/negronimetal) ----
 *   clients  processes whose EAGLContext the dylib's shim takes (backboardd: CoreAnimation)
 *   apps     processes in which NegroniGL.bundle installs its GLI table (apps and frameworks); the
 *            bundle also reads BUNDLE/{off,apps,apps.local}, as a sandboxed app cannot read /var/db
 *            (plugin/gld.c apps_gate)
 *   off      the GL path off everywhere (both lists ignored)
 * Two lists so that the backboardd A/B (phone-gl.sh on|off) and the app driver (phone-gl.sh apps
 * on|off) switch independently: "*" in apps must not put backboardd on the shim. */

/* name listed in the file at path: 1 yes, 0 no / no file, -1 listed as "-name" */
int
ngl_gate_list(const char *path, const char *prog)
{
	FILE *f = fopen(path, "r");
	if (f == NULL) {
		return 0;
	}
	int r = 0;
	char line[512];
	while (fgets(line, sizeof(line), f) != NULL) {
		char *save = NULL;
		for (char *w = strtok_r(line, " \t\r\n", &save); w != NULL; w = strtok_r(NULL, " \t\r\n", &save)) {
			if (w[0] == '#') {
				break;
			}
			if (w[0] == '-' && strcmp(w + 1, prog) == 0) {
				r = -1;
				break;
			}
			if (strcmp(w, "*") == 0 || strcmp(w, prog) == 0) {
				r = 1;
			}
		}
		if (r < 0) {
			break;
		}
	}
	fclose(f);
	return r;
}

bool
ngl_gate_off(void)
{
	return access(NGL_GATE_DIR "/off", F_OK) == 0;
}

static bool
gate_open(const char *prog)
{
	const char *e = getenv("NEGRONIGL_EAGL");
	if (e != NULL && e[0] != 0) {
		return ngl_env_on("NEGRONIGL_EAGL", false);
	}
	if (ngl_gate_off()) {
		ngl_log("negronigl: %s off: EAGL shim not installed in %s", NGL_GATE_DIR "/off", prog);
		return false;
	}
	int c = ngl_gate_list(NGL_GATE_DIR "/clients", prog);
	if (c != 1) {
		ngl_log("negronigl: %s is not in %s/clients (%s): EAGL shim not installed", prog, NGL_GATE_DIR,
		    c < 0 ? "listed as -" : "no entry or no file");
	}
	return c == 1;
}

/*
 * Preflight (ios-spes spes_gl_preflight.c, adapted): a real GPU render must pass before any
 * Apple method is replaced. Synchronous, in the constructor, as there: backboardd's own EAGL
 * contexts are made later, after the constructors. No persistent pass flag.
 */
static bool
ngl_preflight(void)
{
	if (!ngl_env_on("NEGRONIGL_PREFLIGHT", true)) {
		ngl_log("negronigl: preflight skipped (NEGRONIGL_PREFLIGHT=0)");
		return true;
	}
	long wait_s = 30;
	const char *w = getenv("NEGRONIGL_WAIT");
	if (w != NULL && w[0] != 0) {
		wait_s = strtol(w, NULL, 10);
	}
	uint64_t t0 = mach_absolute_time();
	bool up = false;
	for (long i = 0; i <= wait_s * 10 && !(up = ngl_init()); i++) {
		usleep(100000);                 /* RedwoodGPU starts during boot */
	}
	if (!up) {
		ngl_log("negronigl: preflight FAIL: no GL screen after %ld s: Apple's EAGL kept", wait_s);
		return false;
	}
	if (ngl_soft() && !ngl_env_on("NEGRONIGL_ALLOW_SW", false)) {
		ngl_log("negronigl: preflight FAIL: screen is softpipe, not the GPU (NEGRONIGL_ALLOW_SW=1 allows it): "
		    "Apple's EAGL kept");
		return false;
	}
	struct pipe_screen *scr = ngl_screen();
	const char *renderer = scr ? scr->get_name(scr) : "";
	if (!ngl_soft() && strstr(renderer, "FD730") == NULL) {
		ngl_log("negronigl: preflight FAIL: renderer '%s' is not FD730: Apple's EAGL kept", renderer);
		return false;
	}
	bool tri = ngl_selftest();
	bool surf = tri && ngl_surface_selftest();
	ngl_log("negronigl: preflight %s renderer=%s triangle=%s iosurface=%s after %.0f ms", tri && surf ? "PASS" : "FAIL",
	    renderer, tri ? "PASS" : "FAIL", surf ? "PASS" : "FAIL", ms_since(t0));
	return tri && surf;
}

#ifndef NGL_PLUGIN       /* NegroniGL.bundle: libGFXShared loads it; plugin/gli.c is the entry */
__attribute__((constructor)) static void
ngl_load(void)
{
	const char *prog = getprogname();
	prog = prog ? prog : "?";
	bool eagl = gate_open(prog);
	ngl_log("negronigl: loaded into %s (pid %d), EAGL shim %s", prog, getpid(), eagl ? "wanted" : "off");
	ngl_log_image_base();
	if (eagl && ngl_preflight()) {
		ngl_eagl_install();
	}
	if (ngl_env_on("NEGRONIGL_TEST", false)) {
		pthread_t th;
		if (pthread_create(&th, NULL, selftest_thread, NULL) == 0) {
			pthread_detach(th);
		}
	}
}
#endif
