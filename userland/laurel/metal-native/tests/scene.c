/*
 * One fixed scene through the C ABI of the bridge (NativeMetalObjects.h), with no Objective-C and no phone: the same calls the frontend makes for a CoreAnimation frame.
 * Linked with the default bridge (+ Turnip + Mesa's drm-shim) it gives the reference command stream. Linked with the native stack (+ the fake kernel) it gives ours. scripts/laurel/native/pm4-compare.sh compares them.
 *   scene LOADER CACHE_DIR QUARTZCORE_METALLIB [PLAN_FILE ROW]
 * Scene: a BGRA8 target 720 x 1560 like the framebuffer; clear; one image quad with CA's vertex layout (buffer 1, stride 48), a texture and a sampler; commit, wait.
 * With no plan: std_vert1_lph + luma_boost_lph, source-over blend. With a plan (scripts/ios26/real-plan.py, a key the phone really asked): that row's functions, formats and constants, no blend state, as CA's fetch pipelines, and a memoryless second target when the row asks for one.
 */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
struct NmbTextureDescriptor;
#include "NativeMetalObjects.h"

/* the bridge imports it (Darwin libSystem) */
void sys_dcache_flush(void *start, size_t length) { (void)start; (void)length; }

static size_t type_size(uint64_t t)
{
	if (t >= 3 && t <= 6) return 4;
	if (t >= 16 && t <= 19) return 2;
	if (t >= 29 && t <= 36) return 4;
	if (t >= 37 && t <= 44) return 2;
	return 1;
}

/* the format of userland/laurel/metal/tests/ca-pipelines.c: "i12:53:1" or "nfc_generic:53:1" */
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
		size_t z = type_size(type), start = used;
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

#define FAIL(what) do { printf("FAIL %s: %s\n", what, nmb_last_error()); return 1; } while (0)

static void *read_file(const char *path, size_t *length)
{
	FILE *f = fopen(path, "rb");
	void *p;
	if (f == NULL)
		return NULL;
	fseek(f, 0, SEEK_END);
	*length = (size_t)ftell(f);
	fseek(f, 0, SEEK_SET);
	p = malloc(*length);
	if (p != NULL && fread(p, 1, *length, f) != *length) {
		free(p);
		p = NULL;
	}
	fclose(f);
	return p;
}

int main(int argc, char **argv)
{
	size_t length;
	if (argc != 4 && argc != 6) {
		fprintf(stderr, "usage: scene LOADER CACHE_DIR METALLIB [PLAN ROW]\n");
		return 2;
	}
	char vname[128] = "std_vert1_lph", fname[128] = "luma_boost_lph", colors[64] = "80";
	static unsigned char pool[8192];
	struct NmbConstant cons[128];
	uint32_t ncons = 0;
	bool plan = argc == 6;
	if (plan) {
		static char line[65536];
		FILE *f = fopen(argv[4], "r");
		int want = atoi(argv[5]);
		for (int i = 0; f && fgets(line, sizeof(line), f); i++) {
			if (i != want)
				continue;
			line[strcspn(line, "\n")] = 0;
			char *field[8] = {0};
			int n = 0;
			for (char *t = strtok(line, "\t"); t && n < 8; t = strtok(NULL, "\t"))
				field[n++] = t;
			if (n < 7) {
				printf("FAIL plan row\n");
				return 1;
			}
			snprintf(vname, sizeof(vname), "%s", field[2]);
			snprintf(fname, sizeof(fname), "%s", field[3]);
			snprintf(colors, sizeof(colors), "%s", field[4]);
			ncons = parse_constants(field[6], cons, 128, pool);
			break;
		}
		printf("scene: %s + %s, colors %s, %u constants\n", vname, fname, colors, ncons);
	}
	void *bytes = read_file(argv[3], &length);
	if (bytes == NULL) {
		printf("FAIL no %s\n", argv[3]);
		return 1;
	}
	NmbDevice *dev = nmb_device_open(argv[1], argv[2]);
	if (dev == NULL)
		FAIL("device");
	NmbLibrary *lib = nmb_library_new(dev, bytes, length, false);
	if (lib == NULL)
		FAIL("library");
	NmbFunction *vf = ncons ? nmb_function_new_specialized(lib, vname, cons, ncons) : nmb_function_new(lib, vname);
	NmbFunction *ff = ncons ? nmb_function_new_specialized(lib, fname, cons, ncons) : nmb_function_new(lib, fname);
	if (vf == NULL || ff == NULL)
		FAIL("function");
	struct NmbRenderPipelineDescriptor pd;
	memset(&pd, 0, sizeof(pd));
	pd.vertex = vf;
	pd.fragment = ff;
	uint64_t second = 0;
	{
		char *comma = strchr(colors, ',');
		pd.colors[0].format = strtoull(colors, NULL, 10);
		pd.colors[0].write_mask = 0xf;
		if (comma != NULL) {
			second = strtoull(comma + 1, NULL, 10);
			pd.colors[1].format = second;
			pd.colors[1].write_mask = 0xf;
		}
	}
	if (!plan) {
		pd.colors[0].blending = 1;
		pd.colors[0].source_rgb = 1;    /* one */
		pd.colors[0].destination_rgb = 5;       /* one minus source alpha */
		pd.colors[0].source_alpha = 1;
		pd.colors[0].destination_alpha = 5;
	}
	pd.samples = 1;
	pd.rasterization = 1;
	pd.vertex_inputs = 1;
	static const struct { uint64_t format, offset; } attr[4] = {{31, 0}, {29, 16}, {29, 24}, {27, 32}};
	for (int i = 0; i < 4; i++) {
		pd.attributes[i].format = attr[i].format;
		pd.attributes[i].offset = attr[i].offset;
		pd.attributes[i].buffer = 1;
	}
	pd.layouts[1].stride = 48;
	pd.layouts[1].step_function = 1;
	pd.layouts[1].step_rate = 1;
	NmbRenderPipeline *pipe = nmb_render_pipeline_new(dev, &pd);
	if (pipe == NULL)
		FAIL("render pipeline");

	struct NmbTextureDescriptor td = {.type = 2, .format = 80, .width = 720, .height = 1560, .depth = 1, .levels = 1, .samples = 1, .array_length = 1, .usage = 5, .options = 0};
	NmbTexture *target = nmb_texture_new(dev, &td);
	td.width = td.height = 64;
	td.usage = 1;
	NmbTexture *image = nmb_texture_new(dev, &td);
	if (target == NULL || image == NULL)
		FAIL("texture");
	NmbTexture *memoryless = NULL;
	if (second != 0) {
		/* QuartzCore add_memoryless_textures 0x183f96404: the surface's size, usage 5, storage 3 (memoryless) */
		struct NmbTextureDescriptor md = {.type = 2, .format = second, .width = 720, .height = 1560, .depth = 1, .levels = 1, .samples = 1, .array_length = 1, .usage = 5, .options = 3u << 4};
		memoryless = nmb_texture_new(dev, &md);
		if (memoryless == NULL)
			FAIL("memoryless texture");
	}
	uint32_t texels[64 * 64];
	for (int i = 0; i < 64 * 64; i++)
		texels[i] = 0xff000000u | (uint32_t)(i * 7);
	const uint64_t region[6] = {0, 0, 0, 64, 64, 1};
	if (!nmb_texture_replace(image, region, 0, 0, texels, 64 * 4, 0, sizeof(texels)))
		FAIL("replace");
	struct NmbSamplerDescriptor sd = {.min_filter = 1, .mag_filter = 1, .normalized = 1, .max_anisotropy = 1, .lod_max = 1000.0f};
	NmbSampler *sampler = nmb_sampler_new(dev, &sd);
	if (sampler == NULL)
		FAIL("sampler");
	NmbQueue *queue = nmb_queue_new(dev);
	NmbCommandBuffer *cb = queue ? nmb_command_buffer_new(queue) : NULL;
	if (cb == NULL)
		FAIL("command buffer");
	struct NmbRenderPassDescriptor rp;
	memset(&rp, 0, sizeof(rp));
	rp.colors[0].texture = target;
	rp.colors[0].load = 2;  /* clear */
	rp.colors[0].store = 1;
	rp.colors[0].clear[3] = 1.0;
	if (memoryless != NULL) {
		rp.colors[1].texture = memoryless;
		rp.colors[1].load = 0;  /* dont care */
		rp.colors[1].store = 0;
	}
	rp.width = 720;
	rp.height = 1560;
	rp.array_length = 1;
	rp.samples = 1;
	NmbEncoder *en = nmb_render_encoder_new(cb, &rp);
	if (en == NULL)
		FAIL("render encoder");
	if (!nmb_render_set_pipeline(en, pipe))
		FAIL("set pipeline");
	const double viewport[6] = {0, 0, 720, 1560, 0, 1};
	const uint64_t scissor[4] = {0, 0, 720, 1560};
	nmb_render_set_viewport(en, viewport);
	nmb_render_set_scissor(en, scissor);
	static const float vb[4][12] = {
		{-1, -1, 0, 1, 0, 1, 0, 1, 0x3f80, 0, 0, 0}, {1, -1, 0, 1, 1, 1, 1, 1, 0x3f80, 0, 0, 0},
		{-1, 1, 0, 1, 0, 0, 0, 0, 0x3f80, 0, 0, 0}, {1, 1, 0, 1, 1, 0, 1, 0, 0x3f80, 0, 0, 0},
	};
	static const float uniforms[32];
	if (!nmb_encoder_set_bytes(en, 1, vb, sizeof(vb), 1) || !nmb_encoder_set_bytes(en, 1, uniforms, sizeof(uniforms), 0) || !nmb_encoder_set_bytes(en, 2, uniforms, sizeof(uniforms), 0))
		FAIL("set bytes");
	if (!nmb_encoder_set_texture(en, 2, image, 0) || !nmb_encoder_set_sampler(en, 2, sampler, 0))
		FAIL("set texture");
	static const uint16_t ib_data[6] = {0, 1, 2, 2, 1, 3};
	NmbBuffer *ib = nmb_buffer_new(dev, sizeof(ib_data), 0, ib_data);
	if (ib == NULL)
		FAIL("index buffer");
	if (!nmb_render_draw_indexed(en, 3 /* triangle */, 6, 0 /* uint16 */, ib, 0, 1, 0, 0))
		FAIL("draw");
	if (!nmb_encoder_end(en))
		FAIL("end");
	if (!nmb_command_buffer_commit(cb))
		FAIL("commit");
	int w = nmb_command_buffer_wait(cb, 20000);
	char err[256] = "";
	nmb_command_buffer_error(cb, err, sizeof(err));
	printf("scene: wait %d status %llu error '%s'\n", w, (unsigned long long)nmb_command_buffer_status(cb), err);
	if (w != 0)
		return 1;
	/* blits: the 2D engine's paths, and a readback of the drawn target. On the fake kernel no GPU runs, so the bytes stay zero; on a phone this is the first pixel */
	const uint32_t row = 720 * 4;
	NmbBuffer *readback = nmb_buffer_new(dev, row * 1560, 0, NULL), *copy = nmb_buffer_new(dev, 4096, 0, NULL), *fill = nmb_buffer_new(dev, 4096, 0, NULL);
	NmbCommandBuffer *b2 = nmb_command_buffer_new(queue);
	NmbEncoder *bl = b2 ? nmb_blit_encoder_new(b2) : NULL;
	if (readback == NULL || copy == NULL || fill == NULL || bl == NULL)
		FAIL("blit encoder");
	const uint64_t origin[3] = {0, 0, 0}, full[3] = {720, 1560, 1}, small[3] = {64, 64, 1};
	struct NmbTextureDescriptor md = {.type = 2, .format = 80, .width = 64, .height = 64, .depth = 1, .levels = 7, .samples = 1, .array_length = 1, .usage = 5, .options = 2u << 4};
	NmbTexture *mips = nmb_texture_new(dev, &md);
	if (mips == NULL)
		FAIL("mip texture");
	if (!nmb_blit_fill_buffer(bl, fill, 0, 4096, 0x5a) || !nmb_blit_copy_buffer(bl, fill, 64, copy, 128, 1024))
		FAIL("buffer blit");
	if (!nmb_blit_copy_texture(bl, image, 0, 0, origin, small, mips, 0, 0, origin) || !nmb_blit_generate_mipmaps(bl, mips))
		FAIL("texture blit");
	if (!nmb_blit_texture_to_buffer(bl, target, 0, 0, origin, full, readback, 0, row, 0))
		FAIL("readback blit");
	if (!nmb_encoder_end(bl) || !nmb_command_buffer_commit(b2) || nmb_command_buffer_wait(b2, 20000) != 0)
		FAIL("blit commit");
	const uint32_t *px = nmb_buffer_contents(readback);
	const unsigned char *cp = nmb_buffer_contents(copy);
	printf("scene: pixel (0,0) %08x, (360,780) %08x, (719,1559) %08x; copied byte %02x (a GPU writes 5a)\n", px[0], px[780 * 720 + 360], px[1559 * 720 + 719], cp[128]);
	/* compute: the first kernel of the library that compiles with no arguments bound */
	NmbFunction *kf = nmb_function_new(lib, "compute_apl");
	if (kf == NULL) {
		char name[128];
		for (uint32_t i = 0; kf == NULL && i < nmb_library_function_count(lib); i++) {
			nmb_library_function_name(lib, i, name, sizeof(name));
			if (strstr(name, "kernel") != NULL || strstr(name, "compute") != NULL)
				kf = nmb_function_new(lib, name);
		}
	}
	NmbComputePipeline *kp = kf ? nmb_compute_pipeline_new(dev, kf) : NULL;
	if (kp == NULL) {
		printf("scene: no compute pipeline: %s\n", nmb_last_error());
		return 0;
	}
	NmbCommandBuffer *b3 = nmb_command_buffer_new(queue);
	NmbEncoder *ce = b3 ? nmb_compute_encoder_new(b3) : NULL;
	if (ce == NULL || !nmb_compute_set_pipeline(ce, kp))
		FAIL("compute encoder");
	const uint64_t groups[3] = {4, 4, 1}, per[3] = {32, 32, 1};
	if (!nmb_compute_dispatch(ce, groups, per, false)) {
		printf("scene: compute refused: %s\n", nmb_last_error());
		nmb_encoder_discard(ce);
		return 0;
	}
	if (!nmb_encoder_end(ce) || !nmb_command_buffer_commit(b3) || nmb_command_buffer_wait(b3, 20000) != 0)
		FAIL("compute commit");
	printf("scene: compute: PASS\n");
	return 0;
}
