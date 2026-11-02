/*
 * CoreAnimation's pipelines through the real metal2vulkan runtime + bridge and the real Turnip + ir3 for the Adreno 610, on the build host, no GPU:
 * scripts/ios26/ir3-check.sh runs it with Turnip built for Linux and Mesa's drm-shim (FD_GPU_ID=610). A pipeline made here has passed AIR -> SPIR-V -> NIR -> ir3 -> A610 code.
 * It says nothing about pixels, speed or the kernel. Output: one line per plan row, "ok" or the refusal text.
 *   ca-pipelines LOADER CACHE_DIR METALLIB PLAN
 * PLAN (text, made by scripts/ios26/ir3-plan.py), one pipeline per line, fields separated by tabs:
 *   K NAME CONSTANTS                  a compute pipeline
 *   D NAME CONSTANTS X,Y[,B][;...]    a compute pipeline and one encoded dispatch per threadgroup size X,Y, with B bytes of threadgroup memory per thread at index 0 (CoreAnimation's APL: 16).
 *                                     0,0: the size CoreAnimation takes from the frontend's answers: threadExecutionWidth, maxTotal / width, with the frontend's rule on maxTotal (laurel_rules.h).
 *                                     Prints the answers, and for each size "dispatch ... ok" or the refusal. No GPU runs: the check is the runtime's bind step.
 *   R LABEL VERTEX FRAGMENT COLORS VERTEXDESC CONSTANTS   a render pipeline
 *   L LABEL VERTEX FRAGMENT COLORS VERTEXDESC FUNCTION LINKNAME METALLIB CONSTANTS   a render pipeline whose fragment stage links FUNCTION of METALLIB under LINKNAME
 *     (MTLFunctionDescriptor.specializedName, RenderBox's custom_fn; LINKNAME "-": under its own name), with depth + stencil format 260 as RenderBox
 * COLORS = comma list of Metal pixel formats; VERTEXDESC = "-" or "attr:format:offset" comma list (buffer 29, stride 256);
 * CONSTANTS = "-" or comma list "i<INDEX>:<METALTYPE>:<v.v.v>" or "n<NAME>:<METALTYPE>:<v.v.v>".
 */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
struct NmbTextureDescriptor;
#include "NativeMetalObjects.h"
#include "../laurel_rules.h"

/* the bridge imports it (Darwin libSystem; its self-test only, not run here) */
void sys_dcache_flush(void *start, size_t length) { (void)start; (void)length; }

static double now_ms(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec * 1e3 + t.tv_nsec / 1e6;
}

static size_t type_size(uint64_t t, unsigned n)
{
	/* MTLDataType: float 3.. half 16.. int 29.. uint 33.. short 37.. ushort 41.. char 45.. uchar 49.. bool 53..; n elements */
	if (t >= 3 && t <= 6) return 4;
	if (t >= 16 && t <= 19) return 2;
	if (t >= 29 && t <= 36) return 4;
	if (t >= 37 && t <= 44) return 2;
	(void)n;
	return 1;
}

/* "i12:53:1" or "nfc_generic:53:1", into constants[] (storage in pool) */
static uint32_t parse_constants(char *s, struct NmbConstant *c, uint32_t max, unsigned char *pool)
{
	uint32_t n = 0;
	size_t used = 0;
	if (!strcmp(s, "-"))
		return 0;
	for (char *e = strtok(s, ","); e && n < max; e = strtok(NULL, ",")) {
		char *a = strchr(e, ':'), *b = a ? strchr(a + 1, ':') : NULL;
		if (!b)
			continue;
		*a = 0;
		*b = 0;
		uint64_t type = strtoull(a + 1, NULL, 10);
		c[n].type = type;
		if (e[0] == 'i') {
			c[n].index = strtoull(e + 1, NULL, 10);
			c[n].name = NULL;
		} else {
			c[n].index = UINT64_MAX;
			c[n].name = e + 1;
		}
		size_t z = type_size(type, 1), start = used;
		for (char *v = b + 1; *v;) {
			char *end;
			double d = strtod(v, &end);
			if (end == v)
				break;
			if (z == 4 && type >= 3 && type <= 6) {
				float f = (float)d;
				memcpy(pool + used, &f, 4);
			} else {
				long long l = (long long)d;
				memcpy(pool + used, &l, z);
			}
			used += z;
			v = *end == '.' ? end + 1 : end;
		}
		c[n].bytes = pool + start;
		c[n].length = used - start;
		n++;
	}
	return n;
}

static void *read_file(const char *path, long *len)
{
	FILE *f = fopen(path, "rb");
	if (!f) {
		perror(path);
		exit(2);
	}
	fseek(f, 0, SEEK_END);
	*len = ftell(f);
	fseek(f, 0, SEEK_SET);
	void *bytes = malloc(*len);
	if (fread(bytes, 1, *len, f) != (size_t)*len)
		exit(2);
	fclose(f);
	return bytes;
}

/* the library of a linked function (RenderBox: the effect's own library, the stage comes from RenderBox's); one path per run */
static NmbLibrary *second_library(NmbDevice *dev, const char *path)
{
	static NmbLibrary *lib;
	if (!lib) {
		long len;
		void *bytes = read_file(path, &len);
		lib = nmb_library_new(dev, bytes, len, false);
	}
	return lib;
}

int main(int argc, char **argv)
{
	if (argc != 5) {
		fprintf(stderr, "usage: ca-pipelines LOADER CACHE_DIR METALLIB PLAN\n");
		return 2;
	}
	mkdir(argv[2], 0755);
	NmbDevice *dev = nmb_device_open(argv[1], argv[2]);
	if (!dev) {
		printf("FAIL device: %s\n", nmb_last_error());
		return 3;
	}
	/* the answers CoreAnimation's new_metal_context reads, from this device */
	static const char *const asked[] = { "supportsRasterOrderGroups", "supportsNativeHardwareFP16", "supportsMemorylessRenderTargets", "supportsSIMDGroup", "supportsTileShaders",
					     "supportsSIMDReduction", "supportsSIMDShuffleAndFill", "supportsYCBCRFormats12", "supportsYCBCRPackedFormats12", "supportsLossyCompression", NULL };
	for (const char *const *q = asked; *q; q++) {
		uint64_t v = 0;
		bool have = nmb_device_answer(dev, *q, 0, &v);
		printf("answer %s = %llu%s\n", *q, (unsigned long long)v, have ? "" : " (no answer of its own)");
	}
	for (uint64_t family = 1001; family <= 1010; family++) {
		uint64_t v = 0;
		bool have = nmb_device_answer(dev, "supportsFamily:", family, &v);
		printf("answer supportsFamily:%llu = %llu%s\n", (unsigned long long)family, (unsigned long long)v, have ? "" : " (none)");
	}
	long len;
	void *bytes = read_file(argv[3], &len);
	NmbLibrary *lib = nmb_library_new(dev, bytes, len, false);
	if (!lib) {
		printf("FAIL library: %s\n", nmb_last_error());
		return 3;
	}
	printf("device open, library %u functions\n", nmb_library_function_count(lib));
	FILE *f = fopen(argv[4], "r");
	if (!f) {
		perror(argv[4]);
		return 2;
	}
	static char line[1 << 16];
	unsigned ok = 0, bad = 0;
	while (fgets(line, sizeof(line), f)) {
		line[strcspn(line, "\n")] = 0;
		if (!line[0])
			continue;
		char *save = NULL, *field[10];
		int nf = 0;
		for (char *p = strtok_r(line, "\t", &save); p && nf < 10; p = strtok_r(NULL, "\t", &save))
			field[nf++] = p;
		static struct NmbConstant cons[128];
		static unsigned char pool[8192];
		double t0 = now_ms();
		const char *why = NULL;
		const char *label = field[1];
		fprintf(stderr, "=== PIPELINE %s\n", label); /* ir3's statistics follow in the same stream: scripts/ios26/ir3-stats.py */
		fflush(stderr);
		if (field[0][0] == 'D' && nf >= 4) {
			uint32_t n = parse_constants(field[2], cons, 128, pool);
			NmbFunction *fn = n ? nmb_function_new_specialized(lib, field[1], cons, n) : nmb_function_new(lib, field[1]);
			NmbComputePipeline *p = fn ? nmb_compute_pipeline_new(dev, fn) : NULL;
			if (!p)
				why = nmb_last_error();
			else {
				uint64_t shared = 0;
				nmb_device_answer(dev, "maxThreadgroupMemoryLength", 0, &shared);
				const unsigned long long runtime_max = nmb_compute_pipeline_max_threads(p), width = nmb_compute_pipeline_execution_width(p);
				const unsigned long long max = laurel_kernel_max_threads(runtime_max, width, shared);
				printf("kernel\t%s\tmax=%llu\tanswer=%llu\twidth=%llu\tshared=%llu\n", label, runtime_max, max, width, (unsigned long long)shared);
				static NmbQueue *queue;
				if (!queue)
					queue = nmb_queue_new(dev);
				for (char *size = strtok(field[3], ";"); size; size = strtok(NULL, ";")) {
					unsigned long long x = 0, y = 0, per_thread = 0;
					sscanf(size, "%llu,%llu,%llu", &x, &y, &per_thread);
					if (!x && width) {
						x = width;
						y = max / width;
					}
					NmbCommandBuffer *cb = nmb_command_buffer_new(queue);
					NmbEncoder *e = cb ? nmb_compute_encoder_new(cb) : NULL;
					const uint64_t groups[3] = { 1, 1, 1 }, per[3] = { x, y, 1 };
					const bool done = e && nmb_compute_set_pipeline(e, p) && (!per_thread || nmb_compute_set_threadgroup_memory(e, (uint32_t)(x * y * per_thread), 0)) &&
							  nmb_compute_dispatch(e, groups, per, false);
					printf("dispatch\t%s\t%llu,%llu,%llu\t%s\n", label, x, y, per_thread, done ? "ok" : nmb_last_error());
					if (e)
						nmb_encoder_discard(e);
				}
				nmb_compute_pipeline_release(p);
			}
			if (fn)
				nmb_function_release(fn);
		} else if (field[0][0] == 'K' && nf >= 3) {
			uint32_t n = parse_constants(field[2], cons, 128, pool);
			NmbFunction *fn = n ? nmb_function_new_specialized(lib, field[1], cons, n) : nmb_function_new(lib, field[1]);
			if (!fn)
				why = nmb_last_error();
			else {
				NmbComputePipeline *p = nmb_compute_pipeline_new(dev, fn);
				if (!p)
					why = nmb_last_error();
				else
					nmb_compute_pipeline_release(p);
				nmb_function_release(fn);
			}
		} else if ((field[0][0] == 'R' && nf >= 7) || (field[0][0] == 'L' && nf >= 10)) {
			const bool linked = field[0][0] == 'L';
			uint32_t n = parse_constants(field[linked ? 9 : 6], cons, 128, pool);
			NmbFunction *vf = NULL, *ff = NULL, *lf = NULL;
			static char desc[1024], colors[128];
retry:
			vf = n ? nmb_function_new_specialized(lib, field[2], cons, n) : nmb_function_new(lib, field[2]);
			ff = n ? nmb_function_new_specialized(lib, field[3], cons, n) : nmb_function_new(lib, field[3]);
			if (linked)
				lf = nmb_function_new_with_descriptor(second_library(dev, field[8]), field[6], strcmp(field[7], "-") ? field[7] : NULL, NULL, 0, false);
			if (!vf || !ff || (linked && !lf))
				why = nmb_last_error();
			else {
				static struct NmbRenderPipelineDescriptor d;
				memset(&d, 0, sizeof(d));
				if (linked) {
					d.fragment_linked.functions = &lf;
					d.fragment_linked.function_count = 1;
					d.depth_format = d.stencil_format = 260;
				}
				/* (strtok below eats its input, and a retry parses again) */
				snprintf(desc, sizeof(desc), "%s", field[5]);
				snprintf(colors, sizeof(colors), "%s", field[4]);
				d.vertex = vf;
				d.fragment = ff;
				d.samples = 1;
				d.topology = 0;      /* MTLPrimitiveTopologyClassUnspecified: CoreAnimation sets none */
				d.rasterization = 1;
				int ci = 0;
				for (char *c = strtok(colors, ","); c && ci < 8; c = strtok(NULL, ","), ci++) {
					d.colors[ci].format = strtoull(c, NULL, 10);
					d.colors[ci].write_mask = 15;
					/* integer formats do not blend (Metal rejects it too) */
					d.colors[ci].blending = ci == 0 && !(d.colors[ci].format == 13 || d.colors[ci].format == 23 || d.colors[ci].format == 53 ||
									     d.colors[ci].format == 54 || d.colors[ci].format == 73 || d.colors[ci].format == 113 ||
									     d.colors[ci].format == 123);
					d.colors[ci].source_rgb = 1;           /* one */
					d.colors[ci].destination_rgb = 5;      /* one minus source alpha */
					d.colors[ci].source_alpha = 1;
					d.colors[ci].destination_alpha = 5;
				}
				if (strcmp(desc, "-")) {
					unsigned buffer = 29, stride = 256;
					char *list = desc, *semi = strchr(desc, ';');
					if (semi) { /* "b1s48;...": CoreAnimation's real layout */
						sscanf(desc, "b%us%u", &buffer, &stride);
						list = semi + 1;
					}
					d.vertex_inputs = 1;
					d.layouts[buffer].stride = stride;
					d.layouts[buffer].step_function = 1;
					d.layouts[buffer].step_rate = 1;
					for (char *a = strtok(list, ","); a; a = strtok(NULL, ",")) {
						unsigned idx = 0, fmt = 0, off = 0;
						if (sscanf(a, "%u:%u:%u", &idx, &fmt, &off) == 3 && idx < 31) {
							d.attributes[idx].format = fmt;
							d.attributes[idx].offset = off;
							d.attributes[idx].buffer = buffer;
						}
					}
				}
				NmbRenderPipeline *p = nmb_render_pipeline_new(dev, &d);
				if (!p) {
					why = nmb_last_error();
					/* a named constant and its stand-in by index: drop the stand-in, the named value stays */
					const char *dup = strstr(why, "DuplicateFunctionConstant { index: ");
					if (dup) {
						uint64_t index = strtoull(dup + 35, NULL, 10);
						for (uint32_t i = 0; i < n; i++) {
							if (cons[i].name == NULL && cons[i].index == index) {
								memmove(&cons[i], &cons[i + 1], (n - i - 1) * sizeof(cons[0]));
								n--;
								nmb_function_release(vf);
								nmb_function_release(ff);
								why = NULL;
								goto retry;
							}
						}
					}
				} else {
					nmb_render_pipeline_release(p);
				}
			}
			if (vf) nmb_function_release(vf);
			if (ff) nmb_function_release(ff);
			if (lf) nmb_function_release(lf);
		} else {
			why = "bad plan line";
		}
		double ms = now_ms() - t0;
		if (why) {
			bad++;
			printf("FAIL\t%s\t%.1f ms\t%s\n", label, ms, why);
		} else {
			ok++;
			printf("ok\t%s\t%.1f ms\n", label, ms);
		}
		fflush(stdout);
	}
	fclose(f);
	/* metal2vulkan compiles on its own threads as well: wait until this process has used no CPU for a second, so ir3 has printed everything */
	for (double last = -1;;) {
		double used = (double)clock() / CLOCKS_PER_SEC;
		if (last >= 0 && used - last < 0.02)
			break;
		last = used;
		struct timespec t = { 1, 0 };
		nanosleep(&t, NULL);
	}
	printf("ca-pipelines: %u made, %u refused\n", ok, bad);
	fflush(stdout);
	_exit(0); /* no teardown: the driver's threads are idle, and the shim has no GPU to wait for */
}
