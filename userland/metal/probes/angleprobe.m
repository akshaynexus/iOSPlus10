/*
 * angleprobe: WebKit's WebGL path (ANGLE's Metal back end, libANGLE-shared.dylib of the 20H392 WebCore framework)
 * driven from an unsandboxed process over SSH, so the plugin's metal.log shows what Safari's GPU process does when a
 * page asks for a WebGL context (docs/metal-webgl-2026-10-27.md). Steps, each timed and printed:
 *   1. EGL_GetPlatformDisplayEXT(EGL_PLATFORM_ANGLE_ANGLE, type METAL) + EGL_Initialize   (DisplayMtl::initialize:
 *      MTLCreateSystemDefaultDevice, command queue, caps/features, default shader library)
 *   2. EGL_ChooseConfig + EGL_CreateContext (ES 2 or 3, WebGL compatibility) + MakeCurrent with no surface
 *   3. GL strings, a red triangle into an RGBA8 renderbuffer FBO, glReadPixels
 *   4. an IOSurface pbuffer (EGL_CreatePbufferFromClientBuffer EGL_IOSURFACE_ANGLE, BGRA8) bound to a texture,
 *      drawn into through an FBO, then read back through the IOSurface on the CPU (WebKit's display buffer path)
 * A watchdog thread sends SIGUSR1 to the main thread after ANGLEPROBE_TIMEOUT_S (default 15 s): the handler prints the
 * main thread's backtrace (atos -o out/metal/NegroniMetal.dSYM/... with the image base from metal.log) and exits 3.
 *   angleprobe [--es2|--es3] [--no-iosurface]
 * Exit: 0 all steps pass, 1 a step failed (printed), 3 watchdog. Built + pushed by scripts/metal/angleprobe.sh.
 * Our own code; EGL/GL constants from the Khronos headers (values only).
 */
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurfaceRef.h>
#include <dlfcn.h>
#include <execinfo.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <mach/mach_time.h>

typedef void *EGLDisplay, *EGLConfig, *EGLContext, *EGLSurface, *EGLClientBuffer;
typedef int32_t EGLint; typedef unsigned EGLBoolean, EGLenum;
typedef unsigned GLenum, GLuint, GLbitfield; typedef int GLint, GLsizei; typedef unsigned char GLubyte, GLboolean;
typedef float GLfloat; typedef intptr_t GLintptr; typedef ptrdiff_t GLsizeiptr; typedef char GLchar;

#define EGL_NONE 0x3038
#define EGL_PLATFORM_ANGLE_ANGLE 0x3202
#define EGL_PLATFORM_ANGLE_TYPE_ANGLE 0x3203
#define EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE 0x3489
#define EGL_SURFACE_TYPE 0x3033
#define EGL_PBUFFER_BIT 0x0001
#define EGL_RENDERABLE_TYPE 0x3040
#define EGL_OPENGL_ES2_BIT 0x0004
#define EGL_OPENGL_ES3_BIT 0x0040
#define EGL_RED_SIZE 0x3024
#define EGL_GREEN_SIZE 0x3023
#define EGL_BLUE_SIZE 0x3022
#define EGL_ALPHA_SIZE 0x3021
#define EGL_CONTEXT_CLIENT_VERSION 0x3098
#define EGL_CONTEXT_WEBGL_COMPATIBILITY_ANGLE 0x33AC
#define EGL_VENDOR 0x3053
#define EGL_VERSION 0x3054
#define EGL_EXTENSIONS 0x3055
#define EGL_WIDTH 0x3057
#define EGL_HEIGHT 0x3056
#define EGL_TEXTURE_FORMAT 0x3080
#define EGL_TEXTURE_RGBA 0x305E
#define EGL_TEXTURE_TARGET 0x3081
#define EGL_TEXTURE_2D 0x305F
#define EGL_IOSURFACE_ANGLE 0x3454
#define EGL_IOSURFACE_PLANE_ANGLE 0x345A
#define EGL_TEXTURE_RECTANGLE_ANGLE 0x345B
#define EGL_TEXTURE_TYPE_ANGLE 0x345C
#define EGL_TEXTURE_INTERNAL_FORMAT_ANGLE 0x345D
#define EGL_IOSURFACE_USAGE_HINT_ANGLE 0x348A
#define EGL_IOSURFACE_READ_HINT_ANGLE 0x0001
#define EGL_IOSURFACE_WRITE_HINT_ANGLE 0x0002
#define EGL_BACK_BUFFER 0x3084
#define GL_BGRA_EXT 0x80E1
#define GL_UNSIGNED_BYTE 0x1401
#define GL_RENDERER 0x1F01
#define GL_VENDOR 0x1F00
#define GL_VERSION 0x1F02
#define GL_SHADING_LANGUAGE_VERSION 0x8B8C
#define GL_EXTENSIONS 0x1F03
#define GL_VERTEX_SHADER 0x8B31
#define GL_FRAGMENT_SHADER 0x8B30
#define GL_COMPILE_STATUS 0x8B81
#define GL_LINK_STATUS 0x8B82
#define GL_ARRAY_BUFFER 0x8892
#define GL_STATIC_DRAW 0x88E4
#define GL_FLOAT 0x1406
#define GL_TRIANGLES 0x0004
#define GL_COLOR_BUFFER_BIT 0x4000
#define GL_RGBA 0x1908
#define GL_RGBA8 0x8058
#define GL_FRAMEBUFFER 0x8D40
#define GL_RENDERBUFFER 0x8D41
#define GL_COLOR_ATTACHMENT0 0x8CE0
#define GL_FRAMEBUFFER_COMPLETE 0x8CD5
#define GL_TEXTURE_2D 0x0DE1
#define GL_TEXTURE_MIN_FILTER 0x2801
#define GL_TEXTURE_MAG_FILTER 0x2800
#define GL_NEAREST 0x2600

static EGLDisplay (*p_eglGetPlatformDisplayEXT)(EGLenum, void *, const EGLint *);
static EGLBoolean (*p_eglInitialize)(EGLDisplay, EGLint *, EGLint *);
static EGLBoolean (*p_eglChooseConfig)(EGLDisplay, const EGLint *, EGLConfig *, EGLint, EGLint *);
static EGLContext (*p_eglCreateContext)(EGLDisplay, EGLConfig, EGLContext, const EGLint *);
static EGLBoolean (*p_eglMakeCurrent)(EGLDisplay, EGLSurface, EGLSurface, EGLContext);
static EGLint (*p_eglGetError)(void);
static const char *(*p_eglQueryString)(EGLDisplay, EGLint);
static EGLSurface (*p_eglCreatePbufferFromClientBuffer)(EGLDisplay, EGLenum, EGLClientBuffer, EGLConfig, const EGLint *);
static EGLBoolean (*p_eglBindTexImage)(EGLDisplay, EGLSurface, EGLint);
static EGLBoolean (*p_eglReleaseTexImage)(EGLDisplay, EGLSurface, EGLint);
static EGLBoolean (*p_eglDestroySurface)(EGLDisplay, EGLSurface);
static void *(*p_eglGetProcAddress)(const char *);

static const GLubyte *(*p_glGetString)(GLenum);
static GLenum (*p_glGetError)(void);
static GLuint (*p_glCreateShader)(GLenum);
static void (*p_glShaderSource)(GLuint, GLsizei, const GLchar *const *, const GLint *);
static void (*p_glCompileShader)(GLuint);
static void (*p_glGetShaderiv)(GLuint, GLenum, GLint *);
static void (*p_glGetShaderInfoLog)(GLuint, GLsizei, GLsizei *, GLchar *);
static GLuint (*p_glCreateProgram)(void);
static void (*p_glAttachShader)(GLuint, GLuint);
static void (*p_glLinkProgram)(GLuint);
static void (*p_glGetProgramiv)(GLuint, GLenum, GLint *);
static void (*p_glGetProgramInfoLog)(GLuint, GLsizei, GLsizei *, GLchar *);
static void (*p_glUseProgram)(GLuint);
static void (*p_glGenBuffers)(GLsizei, GLuint *);
static void (*p_glBindBuffer)(GLenum, GLuint);
static void (*p_glBufferData)(GLenum, GLsizeiptr, const void *, GLenum);
static GLint (*p_glGetAttribLocation)(GLuint, const GLchar *);
static void (*p_glEnableVertexAttribArray)(GLuint);
static void (*p_glVertexAttribPointer)(GLuint, GLint, GLenum, GLboolean, GLsizei, const void *);
static void (*p_glClearColor)(GLfloat, GLfloat, GLfloat, GLfloat);
static void (*p_glClear)(GLbitfield);
static void (*p_glDrawArrays)(GLenum, GLint, GLsizei);
static void (*p_glReadPixels)(GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, void *);
static void (*p_glGenFramebuffers)(GLsizei, GLuint *);
static void (*p_glBindFramebuffer)(GLenum, GLuint);
static void (*p_glGenRenderbuffers)(GLsizei, GLuint *);
static void (*p_glBindRenderbuffer)(GLenum, GLuint);
static void (*p_glRenderbufferStorage)(GLenum, GLenum, GLsizei, GLsizei);
static void (*p_glFramebufferRenderbuffer)(GLenum, GLenum, GLenum, GLuint);
static void (*p_glFramebufferTexture2D)(GLenum, GLenum, GLenum, GLuint, GLint);
static GLenum (*p_glCheckFramebufferStatus)(GLenum);
static void (*p_glViewport)(GLint, GLint, GLsizei, GLsizei);
static void (*p_glGenTextures)(GLsizei, GLuint *);
static void (*p_glBindTexture)(GLenum, GLuint);
static void (*p_glTexParameteri)(GLenum, GLenum, GLint);
static void (*p_glFinish)(void);
static void (*p_glFlush)(void);

static uint64_t t0;
static double ms(void) { static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb); return (double)(mach_absolute_time() - t0) * tb.numer / tb.denom / 1e6; }
static const char *g_step = "start";
static pthread_t g_main;

static void on_sigusr1(int sig)
{
	(void)sig;
	void *bt[64];
	int n = backtrace(bt, 64);
	dprintf(2, "angleprobe: WATCHDOG at step '%s' after %.0f ms: main thread backtrace (%d frames)\n", g_step, ms(), n);
	backtrace_symbols_fd(bt, n, 2);
	_exit(3);
}

static void *watchdog(void *arg)
{
	long s = (long)arg;
	sleep((unsigned)s);
	pthread_kill(g_main, SIGUSR1);
	return NULL;
}

static void step(const char *s) { g_step = s; printf("angleprobe: [%7.0f ms] %s\n", ms(), s); fflush(stdout); }
#define FAIL(...) do { printf("angleprobe: FAIL "); printf(__VA_ARGS__); printf(" (step '%s', %.0f ms, eglError 0x%x)\n", g_step, ms(), p_eglGetError ? p_eglGetError() : 0); fflush(stdout); return 1; } while (0)

static GLuint shader(GLenum type, const char *src)
{
	GLuint s = p_glCreateShader(type);
	p_glShaderSource(s, 1, &src, NULL);
	p_glCompileShader(s);
	GLint ok = 0; p_glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
	if (!ok) { char log[2048] = {}; p_glGetShaderInfoLog(s, sizeof log, NULL, log); printf("angleprobe: shader compile FAIL: %s\n", log); return 0; }
	return s;
}

int main(int argc, char **argv)
{
	int es = 2, iosurf = 1;
	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--es3")) es = 3;
		else if (!strcmp(argv[i], "--es2")) es = 2;
		else if (!strcmp(argv[i], "--no-iosurface")) iosurf = 0;
		else { fprintf(stderr, "usage: angleprobe [--es2|--es3] [--no-iosurface]\n"); return 2; }
	}
	t0 = mach_absolute_time();
	g_main = pthread_self();
	signal(SIGUSR1, on_sigusr1);
	long timeout = getenv("ANGLEPROBE_TIMEOUT_S") ? atol(getenv("ANGLEPROBE_TIMEOUT_S")) : 15;
	pthread_t wd; pthread_create(&wd, NULL, watchdog, (void *)timeout);

	step("dlopen libANGLE-shared");
	void *h = dlopen("/System/Library/PrivateFrameworks/WebCore.framework/Frameworks/libANGLE-shared.dylib", RTLD_NOW);
	if (!h) FAIL("dlopen: %s", dlerror());
#define E(name) do { p_##name = dlsym(h, "EGL_" #name + 0); if (!p_##name) { char n[64]; snprintf(n, sizeof n, "EGL_%s", #name + 3); p_##name = dlsym(h, n); } if (!p_##name) FAIL("no symbol EGL_%s", #name + 3); } while (0)
	E(eglGetPlatformDisplayEXT); E(eglInitialize); E(eglChooseConfig); E(eglCreateContext); E(eglMakeCurrent); E(eglGetError);
	E(eglQueryString); E(eglCreatePbufferFromClientBuffer); E(eglBindTexImage); E(eglReleaseTexImage); E(eglDestroySurface); E(eglGetProcAddress);
#define G(name) do { char n[64]; snprintf(n, sizeof n, "GL_%s", #name + 2); p_##name = dlsym(h, n); if (!p_##name) p_##name = p_eglGetProcAddress(#name); if (!p_##name) FAIL("no symbol %s", n); } while (0)
	G(glGetString); G(glGetError); G(glCreateShader); G(glShaderSource); G(glCompileShader); G(glGetShaderiv); G(glGetShaderInfoLog);
	G(glCreateProgram); G(glAttachShader); G(glLinkProgram); G(glGetProgramiv); G(glGetProgramInfoLog); G(glUseProgram);
	G(glGenBuffers); G(glBindBuffer); G(glBufferData); G(glGetAttribLocation); G(glEnableVertexAttribArray); G(glVertexAttribPointer);
	G(glClearColor); G(glClear); G(glDrawArrays); G(glReadPixels); G(glGenFramebuffers); G(glBindFramebuffer); G(glGenRenderbuffers);
	G(glBindRenderbuffer); G(glRenderbufferStorage); G(glFramebufferRenderbuffer); G(glFramebufferTexture2D); G(glCheckFramebufferStatus);
	G(glViewport); G(glGenTextures); G(glBindTexture); G(glTexParameteri); G(glFinish); G(glFlush);

	step("eglGetPlatformDisplayEXT (Metal)");
	EGLint dattr[] = { EGL_PLATFORM_ANGLE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE, EGL_NONE };
	EGLDisplay dpy = p_eglGetPlatformDisplayEXT(EGL_PLATFORM_ANGLE_ANGLE, NULL, dattr);
	if (!dpy) FAIL("no display");
	step("eglInitialize (DisplayMtl: device, queue, caps, default shaders)");
	EGLint maj = 0, min = 0;
	if (!p_eglInitialize(dpy, &maj, &min)) FAIL("eglInitialize");
	printf("angleprobe: EGL %d.%d vendor=\"%s\" version=\"%s\"\n", maj, min, p_eglQueryString(dpy, EGL_VENDOR), p_eglQueryString(dpy, EGL_VERSION));
	const char *ext = p_eglQueryString(dpy, EGL_EXTENSIONS);
	printf("angleprobe: EGL extensions (%zu chars): %.300s%s\n", ext ? strlen(ext) : 0, ext ? ext : "", ext && strlen(ext) > 300 ? "..." : "");
	step("eglChooseConfig");
	EGLint cattr[] = { EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE, es == 3 ? EGL_OPENGL_ES3_BIT : EGL_OPENGL_ES2_BIT,
		EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_NONE };
	EGLConfig cfg = NULL; EGLint ncfg = 0;
	if (!p_eglChooseConfig(dpy, cattr, &cfg, 1, &ncfg) || ncfg < 1) FAIL("eglChooseConfig (%d configs)", ncfg);
	step("eglCreateContext (WebGL compatibility)");
	EGLint xattr[] = { EGL_CONTEXT_CLIENT_VERSION, es, EGL_CONTEXT_WEBGL_COMPATIBILITY_ANGLE, 1, EGL_NONE };
	EGLContext ctx = p_eglCreateContext(dpy, cfg, NULL, xattr);
	if (!ctx) FAIL("eglCreateContext ES %d", es);
	step("eglMakeCurrent (no surface)");
	if (!p_eglMakeCurrent(dpy, NULL, NULL, ctx)) FAIL("eglMakeCurrent");
	step("glGetString");
	printf("angleprobe: GL_RENDERER=\"%s\" GL_VENDOR=\"%s\" GL_VERSION=\"%s\" GLSL=\"%s\"\n", p_glGetString(GL_RENDERER), p_glGetString(GL_VENDOR), p_glGetString(GL_VERSION), p_glGetString(GL_SHADING_LANGUAGE_VERSION));

	step("program (vs + fs compile + link: ANGLE translator -> MSL -> newLibraryWithSource)");
	GLuint vs = shader(GL_VERTEX_SHADER, "attribute vec2 p; void main(){ gl_Position = vec4(p, 0.0, 1.0); }");
	GLuint fs = shader(GL_FRAGMENT_SHADER, "precision mediump float; void main(){ gl_FragColor = vec4(1.0, 0.0, 0.0, 1.0); }");
	if (!vs || !fs) FAIL("shader compile");
	GLuint pr = p_glCreateProgram(); p_glAttachShader(pr, vs); p_glAttachShader(pr, fs); p_glLinkProgram(pr);
	GLint ok = 0; p_glGetProgramiv(pr, GL_LINK_STATUS, &ok);
	if (!ok) { char log[2048] = {}; p_glGetProgramInfoLog(pr, sizeof log, NULL, log); FAIL("link: %s", log); }
	p_glUseProgram(pr);
	GLuint vbo; p_glGenBuffers(1, &vbo); p_glBindBuffer(GL_ARRAY_BUFFER, vbo);
	float tri[] = { -1, -1, 1, -1, 0, 1 };
	p_glBufferData(GL_ARRAY_BUFFER, sizeof tri, tri, GL_STATIC_DRAW);
	GLint loc = p_glGetAttribLocation(pr, "p"); p_glEnableVertexAttribArray((GLuint)loc); p_glVertexAttribPointer((GLuint)loc, 2, GL_FLOAT, 0, 0, NULL);

	step("FBO renderbuffer RGBA8 64x64");
	GLuint fbo, rb; p_glGenFramebuffers(1, &fbo); p_glBindFramebuffer(GL_FRAMEBUFFER, fbo);
	p_glGenRenderbuffers(1, &rb); p_glBindRenderbuffer(GL_RENDERBUFFER, rb); p_glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, 64, 64);
	p_glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, rb);
	GLenum st = p_glCheckFramebufferStatus(GL_FRAMEBUFFER);
	if (st != GL_FRAMEBUFFER_COMPLETE) FAIL("renderbuffer FBO status 0x%x glError 0x%x", st, p_glGetError());
	p_glViewport(0, 0, 64, 64);
	step("clear blue + draw triangle + glReadPixels (renderbuffer)");
	p_glClearColor(0, 0, 1, 1); p_glClear(GL_COLOR_BUFFER_BIT); p_glDrawArrays(GL_TRIANGLES, 0, 3);
	unsigned char px[4] = {}, px2[4] = {};
	p_glReadPixels(32, 20, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
	p_glReadPixels(1, 62, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px2);
	printf("angleprobe: renderbuffer center=%d,%d,%d,%d corner=%d,%d,%d,%d glError=0x%x -> %s\n", px[0], px[1], px[2], px[3], px2[0], px2[1], px2[2], px2[3], p_glGetError(),
		(px[0] > 200 && px[1] < 50 && px2[2] > 200 && px2[0] < 50) ? "PASS triangle" : "WRONG pixels");
	if (!iosurf) { step("done (no IOSurface step)"); return (px[0] > 200 && px2[2] > 200) ? 0 : 1; }

	step("IOSurface 64x64 BGRA + eglCreatePbufferFromClientBuffer(EGL_IOSURFACE_ANGLE)");
	NSDictionary *props = @{ (id)kIOSurfaceWidth: @64, (id)kIOSurfaceHeight: @64, (id)kIOSurfaceBytesPerElement: @4,
		(id)kIOSurfacePixelFormat: @((uint32_t)'BGRA') };
	IOSurfaceRef surf = IOSurfaceCreate((__bridge CFDictionaryRef)props);
	if (!surf) FAIL("IOSurfaceCreate");
	EGLint pattr[] = { EGL_WIDTH, 64, EGL_HEIGHT, 64, EGL_IOSURFACE_PLANE_ANGLE, 0, EGL_TEXTURE_TARGET, EGL_TEXTURE_2D,
		EGL_TEXTURE_INTERNAL_FORMAT_ANGLE, GL_BGRA_EXT, EGL_TEXTURE_FORMAT, EGL_TEXTURE_RGBA, EGL_TEXTURE_TYPE_ANGLE, GL_UNSIGNED_BYTE,
		EGL_IOSURFACE_USAGE_HINT_ANGLE, EGL_IOSURFACE_WRITE_HINT_ANGLE | EGL_IOSURFACE_READ_HINT_ANGLE, EGL_NONE };
	EGLSurface pb = p_eglCreatePbufferFromClientBuffer(dpy, EGL_IOSURFACE_ANGLE, (EGLClientBuffer)surf, cfg, pattr);
	if (!pb) {
		pattr[7] = EGL_TEXTURE_RECTANGLE_ANGLE;
		pb = p_eglCreatePbufferFromClientBuffer(dpy, EGL_IOSURFACE_ANGLE, (EGLClientBuffer)surf, cfg, pattr);
		if (!pb) FAIL("eglCreatePbufferFromClientBuffer (2D and rectangle targets)");
		printf("angleprobe: pbuffer target = TEXTURE_RECTANGLE_ANGLE\n");
	}
	step("eglBindTexImage + FBO texture");
	GLuint tex; p_glGenTextures(1, &tex); p_glBindTexture(GL_TEXTURE_2D, tex);
	p_glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST); p_glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
	if (!p_eglBindTexImage(dpy, pb, EGL_BACK_BUFFER)) FAIL("eglBindTexImage");
	GLuint fbo2; p_glGenFramebuffers(1, &fbo2); p_glBindFramebuffer(GL_FRAMEBUFFER, fbo2);
	p_glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
	st = p_glCheckFramebufferStatus(GL_FRAMEBUFFER);
	if (st != GL_FRAMEBUFFER_COMPLETE) FAIL("IOSurface FBO status 0x%x glError 0x%x", st, p_glGetError());
	step("clear green + draw triangle into the IOSurface + glFinish");
	p_glClearColor(0, 1, 0, 1); p_glClear(GL_COLOR_BUFFER_BIT); p_glDrawArrays(GL_TRIANGLES, 0, 3);
	p_glReadPixels(32, 20, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
	p_glFinish();
	p_eglReleaseTexImage(dpy, pb, EGL_BACK_BUFFER);
	step("CPU read of the IOSurface");
	IOSurfaceLock(surf, kIOSurfaceLockReadOnly, NULL);
	const unsigned char *base = IOSurfaceGetBaseAddress(surf);
	size_t stride = IOSurfaceGetBytesPerRow(surf);
	const unsigned char *c = base + 20 * stride + 32 * 4, *k = base + 62 * stride + 1 * 4;   // BGRA; GL row 0 = bottom
	const unsigned char *c2 = base + (63 - 20) * stride + 32 * 4, *k2 = base + (63 - 62) * stride + 1 * 4;
	printf("angleprobe: glReadPixels(IOSurface FBO) center=%d,%d,%d,%d; IOSurface bytes (BGRA) row20=%d,%d,%d,%d row43=%d,%d,%d,%d corner row62=%d,%d,%d,%d row1=%d,%d,%d,%d seed=%u glError=0x%x\n",
		px[0], px[1], px[2], px[3], c[0], c[1], c[2], c[3], c2[0], c2[1], c2[2], c2[3], k[0], k[1], k[2], k[3], k2[0], k2[1], k2[2], k2[3], IOSurfaceGetSeed(surf), p_glGetError());
	int red_c = (c[2] > 200 && c[1] < 50) || (c2[2] > 200 && c2[1] < 50);
	int green_k = (k[1] > 200 && k[2] < 50) || (k2[1] > 200 && k2[2] < 50);
	IOSurfaceUnlock(surf, kIOSurfaceLockReadOnly, NULL);
	printf("angleprobe: IOSurface path -> %s\n", red_c && green_k ? "PASS" : "WRONG pixels (GPU writes did not reach the IOSurface, or wrong format/orientation)");
	step("done");
	return (px[0] > 200 && red_c && green_k) ? 0 : 1;
}
