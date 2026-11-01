/*
 * Host test (laurel): the picture checks of boot 20:02 and the filter thumbnails. No Apple code runs here.
 *  - noise cut at black: the old sharpness (steps over mean squared) is 0.26..0.34 at any sigma of 1..8 (sigma 2: 0.28, the log's); the new one is about 0
 *  - a real edge survives; the "no light" rule against dark and dim frames; "1 % over" no longer reads 8 for a black frame
 *  - thumbnails: one place per filter, each the middle of the frame, chroma in step, other formats refused
 * Run by scripts/laurel/cam-leak-test.sh (it has the mock of CoreVideo).
 */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "camera_isp.h"
#include "camera_isp_int.h"
#include "cam5_mock.h"

extern bool negronicam_thumbnails_fill(CVImageBufferRef picture, CVPixelBufferRef out, unsigned count);
long failed;
void mock_derived_finalize(struct mock_obj *o) { (void)o; }     /* (no derived objects here) */
#define CHECK(c, ...) do { if (!(c)) { failed++; printf("FAILED line %d: ", __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

enum { W = 1920, H = 1440, STRIDE = W / 4 * 5 };
static uint8_t raw[(size_t)STRIDE * H];

static void
put(uint32_t x, uint32_t y, int v)
{
	uint8_t *g = raw + (size_t)y * STRIDE + (x / 4) * 5;

	v = v < 0 ? 0 : v > 1023 ? 1023 : v;
	g[x & 3] = (uint8_t)(v >> 2);
	g[4] = (uint8_t)((g[4] & ~(3u << (2 * (x & 3)))) | (v & 3) << (2 * (x & 3)));
}

static double
gauss(void)
{
	double u = (rand() + 1.0) / (RAND_MAX + 2.0), v = (rand() + 1.0) / (RAND_MAX + 2.0);

	return sqrt(-2 * log(u)) * cos(2 * M_PI * v);
}

/* the frame: black 64 + base + checks of 64 cells of `edge` + noise of sigma */
static void
paint(double sigma, int base, int edge)
{
	for (uint32_t y = 0; y < H; y++) {
		for (uint32_t x = 0; x < W; x++) {
			put(x, y, (int)lround(64 + base + (((x >> 6) ^ (y >> 6)) & 1 ? edge : 0) + sigma * gauss()));
		}
	}
}

/* the old value (2773): the same blocks, no noise term; this repeats the log's measure */
static double
old_sharpness(const struct negronicam_frame *f)
{
	enum { B = 4 };
	uint32_t cw = f->width / 2, ch = f->height / 2, x0 = cw * 3 / 10, y0 = ch * 3 / 10, nx = (cw * 4 / 10) / B, ny = (ch * 4 / 10) / B;
	static double m[512][512];
	double steps = 0, sum = 0;

	for (uint32_t by = 0; by < ny; by++) {
		for (uint32_t bx = 0; bx < nx; bx++) {
			uint32_t g = 0;

			for (uint32_t cy = y0 + by * B; cy < y0 + by * B + B; cy++) {
				for (uint32_t cx = x0 + bx * B; cx < x0 + bx * B + B; cx++) {
					/* RGGB: the greens are x odd on the even line, x even on the odd line */
					const uint8_t *a = raw + (size_t)cy * 2 * STRIDE + (cx >> 1) * 5, *c = a + STRIDE;
					unsigned o = (cx & 1) * 2;
					int v1 = (a[o + 1] << 2 | (a[4] >> (o * 2 + 2) & 3)) - 64, v2 = (c[o] << 2 | (c[4] >> (o * 2) & 3)) - 64;

					g += (uint32_t)(v1 < 0 ? 0 : v1) + (uint32_t)(v2 < 0 ? 0 : v2);
				}
			}
			m[by][bx] = g / 32.0;
			sum += m[by][bx];
			steps += bx ? (m[by][bx] - m[by][bx - 1]) * (m[by][bx] - m[by][bx - 1]) : 0;
			steps += by ? (m[by][bx] - m[by - 1][bx]) * (m[by][bx] - m[by - 1][bx]) : 0;
		}
	}
	double mean = sum / (nx * ny);

	return steps / (nx * ny) / (mean * mean);
}

static void
picture_checks(void)
{
	struct negronicam_frame f;
	struct isp_stats st;
	float level, sharp;

	memset(&f, 0, sizeof(f));
	f.width = W;
	f.height = H;
	f.stride = STRIDE;
	f.black = 64;
	f.bayer = 0;
	f.exposure_lines = 10368;
	f.line_ns = 12800;
	f.gain = 4096;
	f.gain_unity = 256;
	for (double sigma = 1.0; sigma <= 8; sigma *= 2) {
		paint(sigma, 0, 0);
		sharp = isp_sharpness(&f, raw, 0.3f, 0.3f, 0.7f, 0.7f, &level);
		double old = old_sharpness(&f);

		printf("cam6: noise sigma %.0f: old sharpness %.3f (log: 0.28), new %.4f, green %.1f\n", sigma, old, sharp, level);
		CHECK(old > 0.25 && old < 0.36, "old value %.3f is not the noise's", old);
		CHECK(sharp < 0.02, "noise is left in the sharpness: %.4f", sharp);
	}
	paint(1.3, 0, 0);
	isp_measure(NULL, &f, raw, &st);
	printf("cam6: no light: green %.2f, 1%% over %.0f, top %u, no light %d\n", st.mean[1], st.bright, st.top, isp_no_light(&f, &st));
	CHECK(isp_no_light(&f, &st), "a dark frame is not called dark");
	CHECK(st.bright < 8, "1%% over reads %.0f on a black frame", st.bright);
	/* a real picture at the same settings, in and out of focus: edges tell, noise does not */
	paint(6, 144, 60);
	float sharp_in = isp_sharpness(&f, raw, 0.3f, 0.3f, 0.7f, 0.7f, &level);

	isp_measure(NULL, &f, raw, &st);
	CHECK(!isp_no_light(&f, &st), "a lit frame is called dark");
	CHECK(st.bright > 100, "1%% over reads %.0f on a lit frame", st.bright);
	paint(6, 144, 15);
	float sharp_out = isp_sharpness(&f, raw, 0.3f, 0.3f, 0.7f, 0.7f, &level);

	printf("cam6: picture: sharp edge %.5f, soft edge %.5f\n", sharp_in, sharp_out);
	CHECK(sharp_in > 4 * sharp_out && sharp_out > 0, "edges do not tell: %.5f, %.5f", sharp_in, sharp_out);
	/* dim, not dark: short exposure at low gain is never "no light" */
	paint(1.3, 0, 0);
	f.exposure_lines = 1000;
	f.gain = 256;
	isp_measure(NULL, &f, raw, &st);
	CHECK(!isp_no_light(&f, &st), "13 ms at 1x is called no light");
}

static void
thumbnail_checks(void)
{
	mock_cv_init();
	CFDictionaryRef ip = mock_pool(640, 480, 0x34323066), op = mock_pool(120, 3 * 90, 0x34323066), bgra = mock_pool(120, 270, 0x42475241);
	CVPixelBufferRef in, out, wrong;

	CVPixelBufferPoolCreatePixelBuffer(NULL, (CVPixelBufferPoolRef)ip, &in);
	CVPixelBufferPoolCreatePixelBuffer(NULL, (CVPixelBufferPoolRef)op, &out);
	CVPixelBufferPoolCreatePixelBuffer(NULL, (CVPixelBufferPoolRef)bgra, &wrong);
	uint8_t *y = CVPixelBufferGetBaseAddressOfPlane(in, 0), *uv = CVPixelBufferGetBaseAddressOfPlane(in, 1);

	for (int r = 0; r < 480; r++) {
		for (int x = 0; x < 640; x++) {
			y[r * 640 + x] = (uint8_t)(x * 255 / 639);
		}
	}
	for (int r = 0; r < 240; r++) {
		for (int x = 0; x < 640; x += 2) {
			uv[r * 640 + x] = (uint8_t)(r);
			uv[r * 640 + x + 1] = 200;
		}
	}
	CHECK(negronicam_thumbnails_fill(in, out, 3), "not filled");
	CHECK(!negronicam_thumbnails_fill(in, wrong, 3), "BGRA taken");
	CHECK(!negronicam_thumbnails_fill(wrong, out, 3), "BGRA taken as the picture");
	CHECK(!negronicam_thumbnails_fill(in, out, 0), "no filters taken");
	const uint8_t *oy = CVPixelBufferGetBaseAddressOfPlane(out, 0), *ouv = CVPixelBufferGetBaseAddressOfPlane(out, 1);

	for (int t = 0; t < 3; t++) {
		CHECK(oy[t * 90 * 120] == 0 && oy[t * 90 * 120 + 119] > 245, "place %d: luma %u..%u", t, oy[t * 90 * 120], oy[t * 90 * 120 + 119]);
		CHECK(memcmp(oy, oy + t * 90 * 120, 90 * 120) == 0, "place %d is not the first one", t);
		CHECK(ouv[(t * 90 / 2) * 120 + 1] == 200, "place %d: chroma", t);
		CHECK(ouv[(t * 90 / 2) * 120] < 3 && ouv[((t * 90 + 88) / 2) * 120] > 230, "place %d: chroma rows %u..%u", t, ouv[(t * 90 / 2) * 120],
		    ouv[((t * 90 + 88) / 2) * 120]);
	}
	CVPixelBufferRelease(in);
	CVPixelBufferRelease(out);
	CVPixelBufferRelease(wrong);
	CFRelease(ip);
	CFRelease(op);
	CFRelease(bgra);
	printf("cam6: thumbnails: 3 places of 120x90 from 640x480: OK\n");
}

int
main(void)
{
	picture_checks();
	thumbnail_checks();
	printf("cam6: %s\n", failed ? "FAILED" : "OK");
	return failed ? 1 : 0;
}
