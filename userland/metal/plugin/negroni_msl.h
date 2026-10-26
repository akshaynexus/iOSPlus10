/*
 * negroni_msl.h: Apple's MSL front end in the calling process (no MTLCompilerService XPC).
 *
 * MTLCompiler.framework (the code inside MTLCompilerService) compiles a source request with the C API of
 * libGPUCompiler.dylib (GPUCompiler.framework/Libraries, 31001.722 on 20H392, also on macOS):
 *   compiler = MTLGPUCompilerCreate(0)                       MTLCompilerObject::MTLCompilerObject, 0x1bbdaebbc
 *   ok = MTLGPUCompilerBuildFromSourceToBuffer(compiler, LLVMContext *, source, 0, 0, 0, options, &log, &buffer)
 *                                                             MTLCompilerObject::buildRequest, 0x1bbdabd58
 * buffer = LLVMMemoryBufferRef with a metallib ("MTLB", AIR per function); log = strdup'd diagnostics or NULL
 * (libGPUCompiler sub_1bbfc23c0). The LLVMContext comes from libLLVM's C API (LLVMContextCreate = new LLVMContext).
 * Addresses: unslid 20H392 dyld cache (out/metal/spi/disass/compiler/). The real front end is
 * libGPUCompilerImplLazy.dylib (dlopened by libGPUCompiler); the MSL headers are read from
 * GPUCompiler.framework/Libraries/lib/clang/<version>/include/metal at compile time.
 *
 * Everything is resolved with dlopen/dlsym, so a missing image or symbol is an error string, not a load failure.
 * One compile at a time (one compiler object per process, behind a mutex).
 */
#ifndef NEGRONI_MSL_H
#define NEGRONI_MSL_H

#include <dirent.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#define NMSL_GPUCOMPILER "/System/Library/PrivateFrameworks/GPUCompiler.framework/Libraries/libGPUCompiler.dylib"
#define NMSL_GPUCOMPILER_MAC "/System/Library/PrivateFrameworks/GPUCompiler.framework/GPUCompiler" /* macOS: LLVM is inside */
#define NMSL_LLVM "/usr/lib/libLLVM.dylib"

typedef void *(*nmsl_create_fn)(int);
typedef int (*nmsl_build_fn)(void *compiler, void *context, const char *source, void *a3, void *a4, void *a5,
                             const char *options, char **log, void **buffer);
typedef void *(*nmsl_ctx_create_fn)(void);
typedef void (*nmsl_ctx_dispose_fn)(void *);
typedef const char *(*nmsl_buf_start_fn)(void *);
typedef size_t (*nmsl_buf_size_fn)(void *);
typedef void (*nmsl_buf_dispose_fn)(void *);

struct nmsl_api {
	int state; /* 0 not tried, 1 ready, -1 failed */
	char why[256];
	void *compiler;
	nmsl_build_fn build;
	nmsl_ctx_create_fn ctx_create;
	nmsl_ctx_dispose_fn ctx_dispose;
	nmsl_buf_start_fn buf_start;
	nmsl_buf_size_fn buf_size;
	nmsl_buf_dispose_fn buf_dispose;
};

static struct nmsl_api g_nmsl;
static pthread_mutex_t g_nmsl_lock = PTHREAD_MUTEX_INITIALIZER;

/* Call with g_nmsl_lock held. */
static int nmsl_load_locked(void)
{
	if (g_nmsl.state)
		return g_nmsl.state > 0;
	g_nmsl.state = -1;
	const char *gpath = getenv("NEGRONIMETAL_GPUCOMPILER");
	char gerr[200] = "", lerr[200] = "";
	const char *first = gpath ? gpath : NMSL_GPUCOMPILER;
	void *g = dlopen(first, RTLD_NOW | RTLD_LOCAL);
	if (!g) {
		const char *e = dlerror(); /* read once: a second call answers NULL */
		snprintf(gerr, sizeof(gerr), "%s", e ? e : "?");
		if (!gpath) /* dlerror() is read once per failure: keep the first image's text */
			g = dlopen(NMSL_GPUCOMPILER_MAC, RTLD_NOW | RTLD_LOCAL);
	}
	void *l = dlopen(NMSL_LLVM, RTLD_NOW | RTLD_LOCAL);
	if (!l) {
		const char *e = dlerror();
		snprintf(lerr, sizeof(lerr), "%s", e ? e : "?");
		l = g; /* macOS 27: the LLVM C API is exported by GPUCompiler itself */
	}
	if (!g || !l) {
		if (!g)
			snprintf(g_nmsl.why, sizeof(g_nmsl.why), "dlopen %s failed: %s", first, gerr);
		else
			snprintf(g_nmsl.why, sizeof(g_nmsl.why), "dlopen " NMSL_LLVM " failed: %s", lerr);
		return 0;
	}
	nmsl_create_fn create = (nmsl_create_fn)dlsym(g, "MTLGPUCompilerCreate");
	g_nmsl.build = (nmsl_build_fn)dlsym(g, "MTLGPUCompilerBuildFromSourceToBuffer");
	g_nmsl.ctx_create = (nmsl_ctx_create_fn)dlsym(l, "LLVMContextCreate");
	g_nmsl.ctx_dispose = (nmsl_ctx_dispose_fn)dlsym(l, "LLVMContextDispose");
	g_nmsl.buf_start = (nmsl_buf_start_fn)dlsym(l, "LLVMGetBufferStart");
	g_nmsl.buf_size = (nmsl_buf_size_fn)dlsym(l, "LLVMGetBufferSize");
	g_nmsl.buf_dispose = (nmsl_buf_dispose_fn)dlsym(l, "LLVMDisposeMemoryBuffer");
	if (!create || !g_nmsl.build || !g_nmsl.ctx_create || !g_nmsl.ctx_dispose || !g_nmsl.buf_start || !g_nmsl.buf_size ||
	    !g_nmsl.buf_dispose) {
		snprintf(g_nmsl.why, sizeof(g_nmsl.why), "a symbol is missing (MTLGPUCompilerCreate %d, BuildFromSourceToBuffer %d, "
		         "LLVM C API %d)", create != NULL, g_nmsl.build != NULL, g_nmsl.ctx_create && g_nmsl.buf_start);
		return 0;
	}
	g_nmsl.compiler = create(0);
	if (!g_nmsl.compiler) {
		snprintf(g_nmsl.why, sizeof(g_nmsl.why), "MTLGPUCompilerCreate(0) answered NULL");
		return 0;
	}
	g_nmsl.state = 1;
	return 1;
}

/*
 * Compiles MSL source to a metallib. 1 = *out (malloc, caller frees) / *size set; 0 = failed, *log tells why.
 * *log (malloc, caller frees) holds the compiler's diagnostics on both answers when there are any.
 */
static int nmsl_compile(const char *source, const char *options, void **out, size_t *size, char **log)
{
	*out = NULL;
	*size = 0;
	*log = NULL;
	pthread_mutex_lock(&g_nmsl_lock);
	if (!nmsl_load_locked()) {
		*log = strdup(g_nmsl.why);
		pthread_mutex_unlock(&g_nmsl_lock);
		return 0;
	}
	void *ctx = g_nmsl.ctx_create();
	char *diag = NULL;
	void *buffer = NULL;
	int ok = 0;
#ifdef __cplusplus
	/* a C++ exception out of the front end must not leave g_nmsl_lock locked (the frontend is Objective-C++) */
	try {
		ok = ctx && g_nmsl.build(g_nmsl.compiler, ctx, source, NULL, NULL, NULL, options ? options : "", &diag, &buffer);
	} catch (...) {
		ok = 0;
		buffer = NULL;
		if (!diag)
			diag = strdup("the MSL front end threw a C++ exception");
	}
#else
	ok = ctx && g_nmsl.build(g_nmsl.compiler, ctx, source, NULL, NULL, NULL, options ? options : "", &diag, &buffer);
#endif
	if (buffer) {
		size_t n = g_nmsl.buf_size(buffer);
		const char *p = g_nmsl.buf_start(buffer);
		if (n && p && (*out = malloc(n)) != NULL) {
			memcpy(*out, p, n);
			*size = n;
		}
		g_nmsl.buf_dispose(buffer);
	}
	if (ctx)
		g_nmsl.ctx_dispose(ctx);
	pthread_mutex_unlock(&g_nmsl_lock);
	if (diag && diag[0])
		*log = diag;
	else
		free(diag);
	if (!*out) {
		if (!*log)
			*log = strdup(!ctx ? "LLVMContextCreate answered NULL" : ok ? "no output buffer" : "compile failed without diagnostics");
		return 0;
	}
	return 1;
}

/* The front end's own header directory: GPUCompiler.framework/Libraries/lib/clang/<version> with include/metal/metal_stdlib
 * (20H392: 31001.722 [I: the root holds metal_stdlib, root-grep]; macOS 27: 32023). "" when there is none. */
#define NMSL_CLANG_DIR "/System/Library/PrivateFrameworks/GPUCompiler.framework/Libraries/lib/clang"
static const char *nmsl_resource_dir(void)
{
	static char dir[512];
	static int done;
	if (done)
		return dir;
	done = 1;
	const char *env = getenv("NEGRONIMETAL_MSL_RESOURCE_DIR");
	if (env) {
		snprintf(dir, sizeof(dir), "%s", env);
		return dir;
	}
	DIR *d = opendir(NMSL_CLANG_DIR);
	if (!d)
		return dir;
	struct dirent *e;
	while ((e = readdir(d))) {
		if (e->d_name[0] == '.')
			continue;
		char probe[600];
		struct stat st;
		snprintf(probe, sizeof(probe), NMSL_CLANG_DIR "/%s/include/metal/metal_stdlib", e->d_name);
		if (stat(probe, &st) == 0) {
			snprintf(dir, sizeof(dir), NMSL_CLANG_DIR "/%s", e->d_name);
			break;
		}
	}
	closedir(d);
	return dir;
}

/* A log that says the front end compiled the source as C or found no Metal headers: the options lack what the
 * clang driver adds (-x metal, the default header, the include directory). */
static int nmsl_needs_driver_flags(const char *log)
{
	return log && (strstr(log, "not allowed with 'C'") || strstr(log, "'metal_stdlib' file not found") ||
	               strstr(log, "unknown type name 'using'"));
}

/*
 * MSL source -> metallib with the options of the request (MTLCompileOptions as Metal's client writes them:
 * "-std=metal3.0 -ffast-math ..."). The bare options go first, as MTLCompilerService passes them; when the front end
 * answers as above, the call is made again with the driver's flags in front (-x metal -finclude-default-header
 * -internal-isystem DIR/include/metal: what `metal -###` passes to cc1), and later calls start with them.
 * *mode (optional): 0 bare options, 1 driver flags.
 */
static int g_nmsl_driver_flags = -1; /* -1 unknown, 0 bare, 1 driver flags; NEGRONIMETAL_MSL_DRIVER=0|1 forces */
static int nmsl_compile_msl(const char *source, const char *options, void **out, size_t *size, char **log, int *mode)
{
	if (g_nmsl_driver_flags < 0) {
		const char *e = getenv("NEGRONIMETAL_MSL_DRIVER");
		if (e && (e[0] == '0' || e[0] == '1'))
			g_nmsl_driver_flags = e[0] - '0';
	}
	if (g_nmsl_driver_flags != 1) {
		int ok = nmsl_compile(source, options, out, size, log);
		if (ok || g_nmsl_driver_flags == 0 || !nmsl_needs_driver_flags(*log)) {
			if (ok && g_nmsl_driver_flags < 0)
				g_nmsl_driver_flags = 0;
			if (mode)
				*mode = 0;
			return ok;
		}
		free(*log);
		*log = NULL;
	}
	const char *dir = nmsl_resource_dir();
	size_t n = strlen(options ? options : "") + strlen(dir) + 128;
	char *full = (char *)malloc(n);
	if (!full) {
		*log = strdup("out of memory");
		return 0;
	}
	if (dir[0])
		snprintf(full, n, "-x metal -finclude-default-header -internal-isystem %s/include/metal %s", dir, options ? options : "");
	else
		snprintf(full, n, "-x metal -finclude-default-header %s", options ? options : "");
	int ok = nmsl_compile(source, full, out, size, log);
	free(full);
	if (ok)
		g_nmsl_driver_flags = 1;
	if (mode)
		*mode = 1;
	return ok;
}

#endif
