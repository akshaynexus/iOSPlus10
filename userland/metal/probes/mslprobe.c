/*
 * mslprobe: Apple's MSL front end in this process (userland/metal/plugin/negroni_msl.h), no Metal device, no XPC.
 *   mslprobe [-o OUT.metallib] [-O "OPTIONS"] FILE.metal     (FILE "-" or none: a built-in WebGPU-style shader)
 * Prints the metallib size, the time and the compiler log. Exit 0 = a metallib came back.
 * Runs on the phone (20H392 libGPUCompiler 31001.722) and on macOS (GPUCompiler.framework) for host tests.
 */
#include "../plugin/negroni_msl.h"
#include <time.h>

static const char kBuiltin[] =
	"#include <metal_stdlib>\n"
	"using namespace metal;\n"
	"struct VOut { float4 position [[position]]; float4 color; };\n"
	"struct Uniforms { float4x4 mvp; float4 tint; };\n"
	"vertex VOut vmain(uint vid [[vertex_id]], constant float4 *pos [[buffer(0)]], constant Uniforms &u [[buffer(1)]]) {\n"
	"  VOut o; o.position = u.mvp * pos[vid]; o.color = u.tint; return o; }\n"
	"fragment float4 fmain(VOut in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {\n"
	"  return in.color * t.sample(s, in.position.xy * 0.01); }\n"
	"kernel void kmain(device float *out [[buffer(0)]], uint i [[thread_position_in_grid]]) { out[i] = float(i) * 2.0f; }\n";

int main(int argc, char **argv)
{
	const char *outPath = NULL, *opts = "", *in = NULL;
	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "-o") && i + 1 < argc)
			outPath = argv[++i];
		else if (!strcmp(argv[i], "-O") && i + 1 < argc)
			opts = argv[++i];
		else
			in = argv[i];
	}
	char *src = NULL;
	if (!in || !strcmp(in, "-")) {
		src = strdup(kBuiltin);
	} else {
		FILE *f = fopen(in, "rb");
		if (!f) {
			perror(in);
			return 2;
		}
		fseek(f, 0, SEEK_END);
		long n = ftell(f);
		fseek(f, 0, SEEK_SET);
		if (n < 0) {
			perror("ftell");
			return 2;
		}
		src = calloc(1, (size_t)n + 1);
		if (!src) {
			fprintf(stderr, "out of memory\n");
			return 2;
		}
		if (fread(src, 1, (size_t)n, f) != (size_t)n) {
			perror("read");
			return 2;
		}
		fclose(f);
	}
	struct timespec a, b;
	clock_gettime(CLOCK_MONOTONIC, &a);
	void *lib = NULL;
	size_t size = 0;
	char *log = NULL;
	int mode = -1;
	int ok = nmsl_compile_msl(src, opts, &lib, &size, &log, &mode);
	clock_gettime(CLOCK_MONOTONIC, &b);
	long ms = (b.tv_sec - a.tv_sec) * 1000 + (b.tv_nsec - a.tv_nsec) / 1000000;
	if (log)
		fprintf(stderr, "log:\n%s\n", log);
	if (!ok) {
		printf("mslprobe: FAIL in %ld ms\n", ms);
		return 1;
	}
	const unsigned char *h = lib;
	if (size >= 4)
		printf("mslprobe: OK %zu bytes (%02x%02x%02x%02x %s) in %ld ms (options \"%s\", %s)\n", size, h[0], h[1], h[2], h[3],
		       !memcmp(h, "MTLB", 4) ? "metallib" : "not a metallib", ms, opts, mode ? "driver flags added" : "bare options");
	else
		printf("mslprobe: OK %zu bytes (too short for a metallib) in %ld ms (options \"%s\")\n", size, ms, opts);
	if (outPath) {
		FILE *o = fopen(outPath, "wb");
		if (!o || fwrite(lib, 1, size, o) != size) {
			perror(outPath);
			return 2;
		}
		fclose(o);
	}
	/* a second compile in the same process (the frontend compiles many shaders per process) */
	clock_gettime(CLOCK_MONOTONIC, &a);
	void *lib2 = NULL;
	size_t size2 = 0;
	char *log2 = NULL;
	int ok2 = nmsl_compile_msl(src, opts, &lib2, &size2, &log2, NULL);
	clock_gettime(CLOCK_MONOTONIC, &b);
	printf("mslprobe: second compile %s %zu bytes in %ld ms\n", ok2 ? "OK" : "FAIL", size2,
	       (long)((b.tv_sec - a.tv_sec) * 1000 + (b.tv_nsec - a.tv_nsec) / 1000000));
	free(lib2);
	free(log2);
	free(lib);
	free(log);
	free(src);
	return 0;
}
