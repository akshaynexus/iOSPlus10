/*
 * Host test of the camera's speed work (docs/laurel_sprout/camera.md section 13), the real userland/camera/camera_fast.c + camera_isp.c:
 *  - the fast preview = the old path's picture, on colour bars and a soft scene, lens shading, tuning matrix, zoom, turned, every Bayer order, video range
 *  - times of each stage against the old path, one thread, printed (a host, not the phone)
 *  - AE at the cap: dark frames never ask for a frame over the shortest; the cap's picture gets gain, then digital
 *  - the step rule: half cells over 24 ms for a second, back after 5 s under 5 ms
 */
#ifndef __has_feature
#define __has_feature(x) 0
#endif
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "camera_isp_int.h"
#include "camera_fast.h"

#define W 1920u
#define H 1440u
#define STRIDE (W * 5 / 4)
#define PW 1504u
#define PH 1128u

static void
put(uint8_t *raw, uint32_t x, uint32_t y, uint32_t v)
{
	uint8_t *g = raw + (size_t)y * STRIDE + (size_t)(x / 4) * 5;
	unsigned i = x & 3;

	g[i] = (uint8_t)(v >> 2);
	g[4] = (uint8_t)((g[4] & ~(3u << (i * 2))) | (v & 3) << (i * 2));
}

/* a scene: left half soft colour wedges by column, right half colour bars by row; levels with the black level in them */
static void
scene(uint8_t *raw, uint32_t bayer)
{
	static const int red[4] = { 0, 1, 2, 3 }, blue[4] = { 3, 2, 1, 0 };

	for (uint32_t cy = 0; cy < H / 2; cy++) {
		for (uint32_t cx = 0; cx < W / 2; cx++) {
			double u = (double)cx / (W / 2), v = (double)cy / (H / 2), r, g, b;

			if (u < 0.5) {
				r = 0.2 + 0.6 * u;
				g = 0.1 + 0.5 * v;
				b = 0.5 - 0.4 * u;
			} else {
				unsigned bar = (unsigned)(v * 6);

				r = bar & 1 ? 0.8 : 0.1;
				g = bar & 2 ? 0.6 : 0.05;
				b = bar & 4 ? 0.7 : 0.1;
			}
			for (int p = 0; p < 4; p++) {
				double level = p == red[bayer] ? r : p == blue[bayer] ? b : g;

				put(raw, cx * 2 + (p & 1), cy * 2 + (p >> 1), 64 + (uint32_t)(level * 900));
			}
		}
	}
}

static double
now_ms(void)
{
	struct timespec t;

	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec * 1e3 + t.tv_nsec / 1e6;
}

static struct isp_fast fast;
static double t_cells, t_sharp, t_scale, t_old;

static void
render_fast(const struct isp *isp, const struct negronicam_frame *f, const uint8_t *raw, uint8_t *y, uint8_t *uv, bool video, uint32_t step, float gain)
{
	double a = now_ms(), b, c;

	assert(isp_fast_begin(&fast, isp, f, PW, PH, step));
	isp_fast_cells(&fast, isp, f, raw, 0, fast.ch, video);
	b = now_ms();
	isp_fast_sharpen(&fast, 0, fast.ch, gain);
	c = now_ms();
	isp_fast_scale(&fast, y, PW, uv, PW, PW, PH, 0, PH, gain);
	t_cells += b - a;
	t_sharp += c - b;
	t_scale += now_ms() - c;
}

static void
render_old(const struct isp *isp, const struct negronicam_frame *f, const uint8_t *raw, uint8_t *y, uint8_t *uv, bool video, float gain)
{
	static uint8_t *cells;
	uint32_t cw, ch;
	double a = now_ms();

	isp_cells_size(isp, f, PW, PH, &cw, &ch);
	if (cells == NULL) {
		cells = malloc((size_t)(W / 2) * (H / 2) * 3);
	}
	isp_render_cells(isp, f, raw, cells, cw, ch, 0, ch);
	isp_scale_nv12(cells, cw, ch, y, PW, uv, PW, PW, PH, 0, PH, video);
	isp_finish_rows(y, PW, uv, PW, PW, PH, 0, PH, gain, false);
	t_old += now_ms() - a;
}

/* mean absolute difference of the planes, away from the edges and the bars' steps: the same picture within a few steps of 255 */
static void
compare(const char *what, const uint8_t *y0, const uint8_t *y1, const uint8_t *uv0, const uint8_t *uv1, double most)
{
	double dy = 0, dc = 0;
	size_t ny = 0, nc = 0;

	for (uint32_t r = 8; r + 8 < PH; r++) {
		for (uint32_t x = 8; x + 8 < PW / 2; x++) {
			dy += abs(y0[(size_t)r * PW + x] - y1[(size_t)r * PW + x]);
			ny++;
		}
	}
	for (uint32_t r = 4; r + 4 < PH / 2; r++) {
		for (uint32_t x = 8; x + 8 < PW / 2; x++) {
			dc += abs(uv0[(size_t)r * PW + x] - uv1[(size_t)r * PW + x]);
			nc++;
		}
	}
	dy /= (double)ny;
	dc /= (double)nc;
	printf("cam9: %-28s Y differs %.2f, chroma %.2f (of 255; most %.1f)\n", what, dy, dc, most);
	assert(dy <= most && dc <= most);
}

int
main(void)
{
	uint8_t *raw = calloc(STRIDE, H), *y0 = malloc(PW * PH), *y1 = malloc(PW * PH), *uv0 = malloc(PW * PH / 2 + PW), *uv1 = malloc(PW * PH / 2 + PW);
	static struct isp isp;
	struct negronicam_frame f;

	memset(&f, 0, sizeof(f));
	f.width = W;
	f.height = H;
	f.stride = STRIDE;
	f.format = 1;
	f.black = 64;
	f.sequence = 1;
	f.exposure_lines = 2556;
	f.line_ns = 12800;
	f.gain = 256;
	f.gain_unity = 256;
	f.gain_max = 4096;
	f.frame_lines = 2604;
	f.frame_lines_min = 2604;
	f.frame_lines_max = 10416;
	f.margin = 48;
	f.sensor_w = 7680;
	f.sensor_h = 5760;
	isp_init(&isp);
	isp.lsc_u = 0.96f;
	isp.lsc_v = 0.96f;

	/* each Bayer order */
	for (uint32_t bayer = 0; bayer < 4; bayer++) {
		char what[40];

		f.bayer = bayer;
		memset(raw, 0, (size_t)STRIDE * H);
		scene(raw, bayer);
		fast.sequence = 0;
		render_fast(&isp, &f, raw, y0, uv0, false, 1, 1);
		render_old(&isp, &f, raw, y1, uv1, false, 1);
		snprintf(what, sizeof(what), "Bayer order %u", bayer);
		compare(what, y0, y1, uv0, uv1, 2.5);
	}
	f.bayer = 0;
	memset(raw, 0, (size_t)STRIDE * H);
	scene(raw, 0);

	/* video range */
	render_fast(&isp, &f, raw, y0, uv0, true, 1, 1);
	render_old(&isp, &f, raw, y1, uv1, true, 1);
	compare("video range", y0, y1, uv0, uv1, 2.5);

	/* lens shading, a colour matrix, white balance, digital gain */
	isp.lsc.on = true;
	for (int c = 0; c < 3; c++) {
		for (int gy = 0; gy < LSC_H; gy++) {
			for (int gx = 0; gx < LSC_W; gx++) {
				float dx = (gx - 8) / 8.0f, dy = (gy - 6) / 6.0f;

				isp.lsc.gain[c][gy][gx] = 1 + (dx * dx + dy * dy) * (1.0f + 0.2f * c);
			}
		}
	}
	const float ccm[9] = { 1.6f, -0.4f, -0.2f, -0.3f, 1.5f, -0.2f, -0.1f, -0.5f, 1.6f };

	isp_set_ccm(&isp, ccm);
	isp.wb[0] = 1.8f;
	isp.wb[2] = 1.4f;
	isp.digital = 1.5f;
	t_cells = t_sharp = t_scale = t_old = 0;
	for (int i = 0; i < 5; i++) {
		render_fast(&isp, &f, raw, y0, uv0, false, 1, 1);
		render_old(&isp, &f, raw, y1, uv1, false, 1);
	}
	compare("shading, matrix, gains", y0, y1, uv0, uv1, 3.5);
	printf("cam9: one thread on this host, ms a frame: old path %.1f; new cells %.1f + sharpen %.1f + scale %.1f = %.1f (%.1f x faster)\n", t_old / 5, t_cells / 5, t_sharp / 5, t_scale / 5,
	    (t_cells + t_sharp + t_scale) / 5, t_old / (t_cells + t_sharp + t_scale));
#if !defined(__SANITIZE_ADDRESS__) && !__has_feature(address_sanitizer)
	assert(t_old > 2.5 * (t_cells + t_sharp + t_scale));
#endif

	/* a zoom and a sensor mounted the other way: the same picture, and the half-cell step close to it */
	isp.zoom = 1.4f;
	render_fast(&isp, &f, raw, y0, uv0, false, 1, 1);
	render_old(&isp, &f, raw, y1, uv1, false, 1);
	compare("zoom 1.4", y0, y1, uv0, uv1, 3.5);
	isp.zoom = 1;
	isp.turned = true;
	render_fast(&isp, &f, raw, y0, uv0, false, 1, 1);
	render_old(&isp, &f, raw, y1, uv1, false, 1);
	compare("turned", y0, y1, uv0, uv1, 3.5);
	isp.turned = false;
	render_fast(&isp, &f, raw, y0, uv0, false, 2, 1);
	render_old(&isp, &f, raw, y1, uv1, false, 1);
	compare("every second cell", y0, y1, uv0, uv1, 5);
	assert(fast.cw == 480 && fast.ch == 360);

	/* a high gain: the noisy path runs */
	render_fast(&isp, &f, raw, y0, uv0, false, 1, 16);
	render_old(&isp, &f, raw, y1, uv1, false, 16);
	compare("gain 16x", y0, y1, uv0, uv1, 4);

	/* not a magnified picture: the old path */
	assert(!isp_fast_begin(&fast, &isp, &f, 800, 600, 1));

	/* AE at the cap: the worker gives max_frame_lines = the shortest frame; a dark frame goes to 16x, then digital, and the frame stays */
	{
		struct isp_stats st;
		struct negronicam_command c;
		struct isp a;

		isp_init(&a);
		a.max_frame_lines = f.frame_lines_min;
		memset(&st, 0, sizeof(st));
		st.mean[1] = 3;
		st.bright = 12;
		st.top = 60;
		f.exposure_lines = 2556;
		f.gain = 4096;
		f.frame_lines = 2604;
		for (int i = 0; i < 20; i++) {
			if (isp_ae(&a, &f, &st, &c)) {
				assert(c.c <= f.frame_lines_min && c.a <= f.frame_lines_min - f.margin);
				f.exposure_lines = c.a;
				f.gain = c.b;
				if (c.c) {
					f.frame_lines = c.c;
				}
			}
		}
		printf("cam9: AE in the dark, capped: %u lines of a frame of %u (%.1f fps), gain %.1fx, digital %.2f\n", f.exposure_lines, f.frame_lines,
		    1e9 / (f.frame_lines * (double)f.line_ns), (double)f.gain / 256, a.digital);
		assert(f.frame_lines == f.frame_lines_min && a.digital > 1);
	}

	/* the step rule */
	{
		struct speed s;

		memset(&s, 0, sizeof(s));
		assert(speed_next_step(&s, 20000, 30) == 1);
		assert(speed_next_step(&s, 30000, 0) == 1);     /* (no pictures: no opinion) */
		assert(speed_next_step(&s, 30000, 30) == 2);
		for (int i = 0; i < 4; i++) {
			assert(speed_next_step(&s, 3000, 30) == 2);
		}
		assert(speed_next_step(&s, 6000, 30) == 2);     /* (the count starts again) */
		for (int i = 0; i < 4; i++) {
			assert(speed_next_step(&s, 3000, 30) == 2);
		}
		assert(speed_next_step(&s, 3000, 30) == 1);
	}
	printf("cam9: OK\n");
	return 0;
}
