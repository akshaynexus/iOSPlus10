/*
 * The Metal work of CMCapture's filter strip, without CMCapture: real metal2vulkan runtime + real bridge (built for this host, scripts/metal/
 * build-bridge.sh linux) on a real Vulkan driver of this host. It shows what these layers keep; it says nothing about ir3, the kernel, the
 * A610, or CMCapture itself. scripts/metal/leak-test.sh runs it; docs/laurel_sprout/metal.md section 12.
 *   mediaserverd-leak LOADER CACHE_DIR [METALFILTER_METALLIB] [FRAMES]
 * What FigColorCubeMetalFilter does, read from 20H392 (MetalFilter.bundle, CMImaging):
 *   prewarm   a 32-byte heap, 1x1 textures with usage 7, each made aliasable at once (-[FigMetalContext prewarmInternalMetalShadersForFormatsList:]);
 *             a 2x2 texture over an 8x8 '420f' surface as a render target (-[FigColorCubeMetalFilter prewarmMetalInternalShader])
 *   pipelines 2 x 2 x 2 x 2 specializations of colorCubeFragment2D/3D, luma and chroma, constants 1-4 bool, 5 int, 7 bool
 *   frames    new textures over the planes of two '420f' surfaces for each frame, two render passes, commit, wait, release
 * Each stage prints the process's resident size; exit 1 when the frame stage keeps growing.
 */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <stdbool.h>
#include <stdint.h>
struct NmbTextureDescriptor;
#include "NativeMetalObjects.h"

/* the bridge imports it (Darwin libSystem; its self-test only, not run here) */
void sys_dcache_flush(void *start, size_t length) { (void)start; (void)length; }

enum {
	FMT_R8 = 10, FMT_RG8 = 30, FMT_RGBA8 = 70, TYPE_2D = 2, TYPE_2D_ARRAY = 3, USAGE_READ = 1, USAGE_WRITE = 2, USAGE_TARGET = 4,
	OPT_SHARED = 0, OPT_PRIVATE = 32, W = 1504, H = 1128, ROW = 1504, SURFACES = 16, CUBE = 64, FILTERS = 9, TRIANGLE_STRIP = 4,
	FOURCC_420F = 0x34323066, DT_BOOL = 53, DT_INT = 29,
};

static long
resident_mb(void)
{
	long pages = 0, ignored = 0;
	FILE *f = fopen("/proc/self/statm", "r");

	if (f != NULL) {
		if (fscanf(f, "%ld %ld", &ignored, &pages) != 2) {
			pages = 0;
		}
		fclose(f);
	}
	return pages * sysconf(_SC_PAGESIZE) >> 20;
}

static void
fail(const char *what)
{
	printf("FAIL %s: %s\n", what, nmb_last_error());
	exit(2);
}

static struct NmbTextureDescriptor
desc(uint64_t type, uint64_t format, uint64_t w, uint64_t h, uint64_t array, uint64_t usage, uint64_t options)
{
	return (struct NmbTextureDescriptor){ type, format, w, h, 1, 1, 1, array, usage, options };
}

struct surface {
	void *bytes;
	size_t size;
	uint64_t uv_offset;
};

static struct surface
surface_new(uint64_t w, uint64_t h, uint64_t row)
{
	struct surface s;
	size_t page = (size_t)sysconf(_SC_PAGESIZE);

	s.uv_offset = (row * h + page - 1) & ~(page - 1);
	s.size = (s.uv_offset + row * ((h + 1) / 2) + page - 1) & ~(page - 1);
	s.bytes = mmap(NULL, s.size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (s.bytes == MAP_FAILED) {
		fail("surface pages");
	}
	memset(s.bytes, 0x80, s.size);
	return s;
}

/* a texture over one plane, as newTextureWithDescriptor:iosurface:plane: makes it */
static NmbTexture *
plane_texture(NmbBuffer *b, const struct surface *s, uint64_t plane, uint64_t format, uint64_t w, uint64_t h, uint64_t row, uint64_t usage)
{
	struct NmbTextureDescriptor d = desc(TYPE_2D, format, plane ? w / 2 : w, plane ? h / 2 : h, 1, usage, OPT_SHARED);

	return nmb_texture_new_on_surface_plane(b, &d, plane ? s->uv_offset : 0, row, true, FOURCC_420F, plane, w, h, s->uv_offset, row);
}

/* the 32-byte heap of the prewarm: returns how many of `count` 1x1 textures were placed; aliasable when asked */
static int
prewarm_heap(NmbDevice *dev, int count, bool aliasable)
{
	NmbHeap *heap = nmb_heap_new(dev, 0, 32, OPT_PRIVATE);
	NmbTexture *held[64] = { NULL };        /* the prewarm's render pass descriptor holds them */
	int placed = 0;

	if (heap == NULL) {
		fail("heap of 32 bytes");
	}
	for (int i = 0; i < count; i++) {
		/* (the prewarm's are 1x1; each takes about 4 KiB on Turnip [I], so 48x48 here shows the limit on every driver) */
		struct NmbTextureDescriptor d = desc(TYPE_2D, FMT_RGBA8, 48, 48, 1, USAGE_READ | USAGE_WRITE | USAGE_TARGET, OPT_PRIVATE);
		NmbTexture *t = nmb_heap_new_texture(heap, &d, UINT64_MAX);

		if (t == NULL) {
			continue;
		}
		placed++;
		if (aliasable && !nmb_texture_make_aliasable(t)) {
			fail("make aliasable");
		}
		held[i] = t;
	}
	for (int i = 0; i < count; i++) {
		if (held[i] != NULL) {
			nmb_texture_release(held[i]);
		}
	}
	nmb_heap_release(heap);
	return placed;
}

static NmbRenderPipeline *
filter_pipeline(NmbDevice *dev, NmbLibrary *lib, NmbFunction *vertex, const char *fragment, uint64_t target, int bits)
{
	uint8_t on[6] = { (uint8_t)(bits & 1), (uint8_t)(bits >> 1 & 1), (uint8_t)(bits >> 2 & 1), (uint8_t)(bits >> 3 & 1), 0, 0 };
	int32_t space = 1;
	struct NmbConstant c[6] = {
		{ DT_BOOL, 1, NULL, &on[0], 1 }, { DT_BOOL, 2, NULL, &on[1], 1 }, { DT_BOOL, 3, NULL, &on[2], 1 },
		{ DT_BOOL, 4, NULL, &on[3], 1 }, { DT_INT, 5, NULL, &space, 4 }, { DT_BOOL, 7, NULL, &on[4], 1 },
	};
	NmbFunction *f = nmb_function_new_specialized(lib, fragment, c, 6);
	struct NmbRenderPipelineDescriptor *p;
	NmbRenderPipeline *made;

	if (f == NULL) {
		printf("  %s bits %d: no function: %s\n", fragment, bits, nmb_last_error());
		return NULL;
	}
	p = calloc(1, sizeof(*p));
	p->vertex = vertex;
	p->fragment = f;
	p->colors[0].format = target;
	p->colors[0].write_mask = 15;
	p->samples = 1;
	p->rasterization = 1;
	p->vertex_inputs = 1;
	p->attributes[0] = (struct NmbVertexAttribute){ 31 /* Float4 */, 0, 29 };
	p->layouts[29] = (struct NmbVertexLayout){ 32, 1, 1 };
	made = nmb_render_pipeline_new(dev, p);
	free(p);
	nmb_function_release(f);
	if (made == NULL) {
		printf("  %s bits %d: no pipeline: %s\n", fragment, bits, nmb_last_error());
	}
	return made;
}

static void
pass(NmbCommandBuffer *cb, NmbRenderPipeline *pipeline, NmbTexture *target, uint64_t w, uint64_t h, NmbTexture *y, NmbTexture *uv, NmbTexture *cube,
    NmbBuffer *quad)
{
	struct NmbRenderPassDescriptor d;
	static const double viewport[6] = { 0, 0, 16, 16, 0, 1 };
	float args[16] = { 0 };
	NmbEncoder *e;

	memset(&d, 0, sizeof(d));
	d.colors[0].texture = target;
	d.colors[0].load = 0;
	d.colors[0].store = 1;
	d.width = w;
	d.height = h;
	d.array_length = 1;
	d.samples = 1;
	if ((e = nmb_render_encoder_new(cb, &d)) == NULL) {
		fail("render encoder");
	}
	(void)viewport;
	nmb_render_set_pipeline(e, pipeline);
	nmb_encoder_set_buffer(e, 1, quad, 0, 29);
	nmb_encoder_set_texture(e, 2, y, 0);
	nmb_encoder_set_texture(e, 2, uv, 4);
	nmb_encoder_set_texture(e, 2, cube, 2);
	nmb_encoder_set_texture(e, 2, cube, 3);
	nmb_encoder_set_bytes(e, 2, args, sizeof(args), 0);
	nmb_encoder_set_bytes(e, 2, args, sizeof(args), 2);
	if (!nmb_render_draw(e, TRIANGLE_STRIP, 0, 4, 1, 0)) {
		fail("draw");
	}
	if (!nmb_encoder_end(e)) {
		fail("end encoding");
	}
}

int
main(int argc, char **argv)
{
	const char *loader = argc > 1 ? argv[1] : "libvulkan.so.1", *cache = argc > 2 ? argv[2] : "/tmp/mdleak-cache", *path = argc > 3 && argv[3][0] ? argv[3] : NULL;
	int frames = argc > 4 ? atoi(argv[4]) : 3000, bad = 0;
	long start, warm = 0, end;
	char name[128] = "";
	NmbDevice *dev;
	NmbQueue *queue;

	mkdir(cache, 0777);
	if ((dev = nmb_device_open(loader, cache)) == NULL) {
		fail("device");
	}
	nmb_device_name(dev, name, sizeof(name));
	start = resident_mb();
	printf("device %s: resident %ld MiB\n", name, start);
	queue = nmb_queue_new(dev);

	/* 1. the prewarm's heap */
	{
		int before = prewarm_heap(dev, 20, false), after = prewarm_heap(dev, 20, true);

		printf("heap of 32 bytes: not aliasable %d of 20 placed, aliasable %d of 20 placed\n", before, after);
		if (after != 20) {
			printf("BAD a heap the prewarm can use must take all 20 once each is aliasable\n");
			bad++;
		}
	}

	/* 2. the prewarm's 2x2 target over an 8x8 '420f' surface, plane 0 */
	{
		struct surface s8 = surface_new(8, 8, 64);
		NmbBuffer *b = nmb_buffer_new_no_copy(dev, s8.bytes, s8.size, OPT_SHARED);
		struct NmbTextureDescriptor d = desc(TYPE_2D, FMT_R8, 2, 2, 1, USAGE_READ | USAGE_WRITE | USAGE_TARGET, OPT_SHARED);
		NmbTexture *t = b != NULL ? nmb_texture_new_on_surface_plane(b, &d, 0, 64, true, FOURCC_420F, 0, 8, 8, s8.uv_offset, 64) : NULL;

		printf("2x2 R8 target over an 8x8 '420f' surface: %s%s\n", t != NULL ? "made" : "refused: ", t != NULL ? "" : nmb_last_error());
		if (t != NULL) {
			nmb_texture_release(t);
		}
		if (b != NULL) {
			nmb_buffer_release(b);
		}
	}

	/* the formats CMCapture's buffers take: both planes of '420f', '420v', 'x420' (10-bit in 16), and BGRA without planes */
	{
		static const struct { const char *name; uint32_t fourcc; uint64_t y, uv, bytes; } kinds[] = {
			{ "420f", 0x34323066, FMT_R8, FMT_RG8, 1 }, { "420v", 0x34323076, FMT_R8, FMT_RG8, 1 }, { "x420", 0x78343230, 20 /* R16Unorm */, 60 /* RG16Unorm */, 2 },
		};

		for (unsigned k = 0; k < sizeof(kinds) / sizeof(kinds[0]); k++) {
			uint64_t row = 64 * kinds[k].bytes * 4;
			struct surface v = surface_new(128, 128, row);
			NmbBuffer *b = nmb_buffer_new_no_copy(dev, v.bytes, v.size, OPT_SHARED);

			for (uint64_t plane = 0; b != NULL && plane < 2; plane++) {
				struct NmbTextureDescriptor d = desc(TYPE_2D, plane ? kinds[k].uv : kinds[k].y, plane ? 64 : 128, plane ? 64 : 128, 1, USAGE_READ | USAGE_TARGET, OPT_SHARED);
				NmbTexture *t = nmb_texture_new_on_surface_plane(b, &d, plane ? v.uv_offset : 0, row, true, kinds[k].fourcc, plane, 128, 128, v.uv_offset, row);

				printf("'%s' plane %d: %s%s\n", kinds[k].name, (int)plane, t != NULL ? "made" : "refused: ", t != NULL ? "" : nmb_last_error());
				if (t != NULL) {
					nmb_texture_release(t);
				} else {
					bad++;
				}
			}
			if (b != NULL) {
				nmb_buffer_release(b);
			}
		}
		struct surface v = surface_new(128, 128, 512);
		NmbBuffer *b = nmb_buffer_new_no_copy(dev, v.bytes, v.size, OPT_SHARED);
		struct NmbTextureDescriptor d = desc(TYPE_2D, 80 /* BGRA8Unorm */, 128, 128, 1, USAGE_READ | USAGE_TARGET, OPT_SHARED);
		NmbTexture *t = b != NULL ? nmb_texture_new_on_buffer(b, &d, 0, 512, true) : NULL;

		printf("'BGRA': %s%s\n", t != NULL ? "made" : "refused: ", t != NULL ? "" : nmb_last_error());
		bad += t == NULL;
		if (t != NULL) {
			nmb_texture_release(t);
		}
		if (b != NULL) {
			nmb_buffer_release(b);
		}
	}

	/* 3. the filter's pipelines */
	NmbRenderPipeline *luma = NULL, *chroma = NULL;
	NmbLibrary *lib = NULL;
	NmbFunction *vertex = NULL;

	if (path != NULL) {
		int fd = open(path, O_RDONLY);
		struct stat st;
		uint8_t *bytes;

		if (fd < 0 || fstat(fd, &st) != 0) {
			fail("metallib");
		}
		bytes = malloc((size_t)st.st_size);
		if (read(fd, bytes, (size_t)st.st_size) != st.st_size) {
			fail("metallib read");
		}
		close(fd);
		if ((lib = nmb_library_new(dev, bytes, (size_t)st.st_size, false)) == NULL) {
			fail("library");
		}
		free(bytes);
		if ((vertex = nmb_function_new(lib, "colorCubeVertex")) == NULL) {
			fail("vertex function");
		}
		int made = 0, asked = 0;
		long before = resident_mb();

		for (int bits = 0; bits < 16; bits++) {
			static const char *const frag[] = { "colorCubeFragment2D", "colorCubeFragment3D" };

			for (int f = 0; f < 2; f++) {
				NmbRenderPipeline *p = filter_pipeline(dev, lib, vertex, frag[f], bits == 5 ? FMT_RG8 : FMT_R8, bits);

				asked++;
				made += p != NULL;
				if (p != NULL && f == 0 && bits == 4) {
					luma = p;
				} else if (p != NULL && f == 0 && bits == 5) {
					chroma = p;
				} else if (p != NULL) {
					nmb_render_pipeline_release(p);
				}
			}
		}
		printf("filter pipelines: %d of %d made; resident %ld -> %ld MiB\n", made, asked, before, resident_mb());
	}

	/* 4. the frames */
	struct surface in[SURFACES], out[SURFACES];
	struct NmbTextureDescriptor cd = desc(TYPE_2D_ARRAY, FMT_RGBA8, CUBE, CUBE * CUBE, FILTERS, USAGE_READ, OPT_SHARED);
	NmbTexture *cube = nmb_texture_new(dev, &cd);
	NmbBuffer *quad = nmb_buffer_new(dev, 4096, OPT_SHARED, NULL);

	if (cube == NULL || quad == NULL) {
		fail("cube or quad");
	}
	for (int i = 0; i < SURFACES; i++) {
		in[i] = surface_new(W, H, ROW);
		out[i] = surface_new(W / 2, H / 2, ROW);
	}
	warm = resident_mb();
	for (int frame = 0; frame < frames; frame++) {
		const struct surface *a = &in[frame % SURFACES], *z = &out[frame % SURFACES];
		NmbBuffer *ab = nmb_buffer_new_no_copy(dev, a->bytes, a->size, OPT_SHARED);
		NmbBuffer *zb = nmb_buffer_new_no_copy(dev, z->bytes, z->size, OPT_SHARED);

		if (ab == NULL || zb == NULL) {
			fail("surface import");
		}
		NmbTexture *y = plane_texture(ab, a, 0, FMT_R8, W, H, ROW, USAGE_READ), *uv = plane_texture(ab, a, 1, FMT_RG8, W, H, ROW, USAGE_READ);
		NmbTexture *oy = plane_texture(zb, z, 0, FMT_R8, W / 2, H / 2, ROW, USAGE_TARGET), *ouv = plane_texture(zb, z, 1, FMT_RG8, W / 2, H / 2, ROW, USAGE_TARGET);

		if (y == NULL || uv == NULL || oy == NULL || ouv == NULL) {
			fail("texture over a plane");
		}
		NmbCommandBuffer *cb = nmb_command_buffer_new(queue);

		if (luma != NULL) {
			pass(cb, luma, oy, W / 2, H / 2, y, uv, cube, quad);
			if (chroma != NULL) {
				pass(cb, chroma, ouv, W / 4, H / 4, y, uv, cube, quad);
			}
		} else {
			struct NmbRenderPassDescriptor d;
			NmbEncoder *e;

			memset(&d, 0, sizeof(d));
			d.colors[0].texture = oy;
			d.colors[0].store = 1;
			d.width = W / 2;
			d.height = H / 2;
			d.array_length = 1;
			d.samples = 1;
			if ((e = nmb_render_encoder_new(cb, &d)) == NULL || !nmb_encoder_end(e)) {
				fail("empty pass");
			}
		}
		if (!nmb_command_buffer_commit(cb) || nmb_command_buffer_wait(cb, 5000) != 0) {
			fail("commit or wait");
		}
		if (nmb_command_buffer_status(cb) != 4) {
			char text[256] = "";

			nmb_command_buffer_error(cb, text, sizeof(text));
			printf("frame %d: command buffer status %llu: %s\n", frame, (unsigned long long)nmb_command_buffer_status(cb), text);
			exit(2);
		}
		nmb_command_buffer_release(cb);
		nmb_texture_release(y);
		nmb_texture_release(uv);
		nmb_texture_release(oy);
		nmb_texture_release(ouv);
		nmb_buffer_release(ab);
		nmb_buffer_release(zb);
		if (frame == frames / 4) {
			warm = resident_mb();
		}
		if ((frame + 1) % 500 == 0) {
			printf("frame %d: resident %ld MiB\n", frame + 1, resident_mb());
			fflush(stdout);
		}
	}
	end = resident_mb();
	printf("frames: %d, resident after the first quarter %ld MiB, at the end %ld MiB: %+.1f KiB a frame\n", frames, warm, end,
	    (double)(end - warm) * 1024 / (frames - frames / 4));
	if (end - warm > 16) {
		printf("BAD the frame stage keeps growing\n");
		bad++;
	}
	nmb_texture_release(cube);
	nmb_buffer_release(quad);
	nmb_queue_release(queue);
	printf(bad ? "FAILED\n" : "PASS\n");
	return bad ? 1 : 0;
}
