/*
 * NegroniCamera (iOSPlus10, Mi A3 camera quality, laurel 2773): the photograph's demosaic and the finish of a picture. MIT License, as
 * the rest of the ISP (userland/camera/LICENSE.HakiOS).
 *
 * A line of the sensor: the black level off, the lens shading of its colour on each site (the shading is a property of the raw
 * values: done before the colours are made, the 5x5 filter does not see a slope), then the Malvar, He and Cutler linear demosaic
 * ("High-quality linear interpolation for demosaicing of Bayer-patterned color images", ICASSP 2004): a colour a site lacks is the
 * mean of its neighbours corrected by the second difference of the site's own colour. It keeps about 5.5 dB of PSNR on bilinear [the
 * paper] at the same order of cost: the soft edges and colour fringes of the 3x3 mean go. The filter is integer weights over 8.
 */
#include <stdlib.h>
#include <string.h>
#include "camera_isp.h"
#include "camera_isp_int.h"

/* sensor line y into l (w floats, above black, lens shaded); y clamped into the frame by reflection, keeping the Bayer phase */
static void
load_line(const struct isp *isp, const struct negronicam_frame *f, const uint8_t *raw, int y, float *l, const int colour[4])
{
	const uint8_t *line = raw + (size_t)y * f->stride;
	int w = (int)f->width;
	float v_pos = f->height > 1 ? (float)y / (f->height - 1) : 0, gains[3] = { 1, 1, 1 };

	for (int x = 0; x < w; x += 4) {
		const uint8_t *g = line + (x >> 2) * 5;

		/* the gains of a group of 4: they change slowly */
		if (isp->lsc.on) {
			lsc_at(isp, w > 1 ? (float)x / (w - 1) : 0, v_pos, gains);
		}
		for (int i = 0; i < 4 && x + i < w; i++) {
			int v = (g[i] << 2 | (g[4] >> (i * 2) & 3)) - (int)f->black;

			l[x + i] = (v < 0 ? 0 : (float)v) * gains[colour[(y & 1) * 2 + ((x + i) & 1)]];
		}
	}
}

/* the 2x2 cell's colours: 0 R, 1 G, 2 B (position y * 2 + x; order: negronicam.h) */
static void
colours(uint32_t bayer, int colour[4])
{
	static const int red[4] = { 0, 1, 2, 3 }, blue[4] = { 3, 2, 1, 0 };

	for (int i = 0; i < 4; i++) {
		colour[i] = i == red[bayer & 3] ? 0 : i == blue[bayer & 3] ? 2 : 1;
	}
}

void
isp_mhc_row(const struct isp *isp, const struct negronicam_frame *f, const uint8_t *raw, uint32_t row, float *lines[5], int32_t tags[5],
    uint8_t *rgb)
{
	int colour[4], w = (int)f->width, h = (int)f->height;
	const float *l[5];
	struct pipe p;

	colours(f->bayer, colour);
	pipe_init(isp, &p);
	for (int i = 0; i < 5; i++) {
		int y = (int)row + i - 2;

		/* (outside the frame: the nearest line of the same Bayer phase) */
		y = y < 0 ? y & 1 : y >= h ? h - 2 + (y & 1) : y;
		int slot = y % 5;

		if (tags[slot] != y) {
			load_line(isp, f, raw, y, lines[slot], colour);
			tags[slot] = y;
		}
		l[i] = lines[slot];
	}
	const float *a = l[0], *b = l[1], *c = l[2], *d = l[3], *e = l[4];   /* the lines from 2 above to 2 below */
	int here_y = (int)row & 1;

	for (int x = 0; x < w; x++) {
		/* (the two columns each side, the same Bayer phase at the edges) */
		int xm1 = x >= 1 ? x - 1 : 1, xp1 = x + 1 < w ? x + 1 : w - 2, xm2 = x >= 2 ? x - 2 : x, xp2 = x + 2 < w ? x + 2 : x;
		float cc = c[x], n = b[x], s = d[x], we = c[xm1], ea = c[xp1], nn = a[x], ss = e[x], ww = c[xm2], ee = c[xp2];
		float nw = b[xm1], ne = b[xp1], sw = d[xm1], se = d[xp1];
		int site = colour[here_y * 2 + (x & 1)];
		float r, g, bl;

		if (site == 1) {
			float across = (5 * cc + 4 * (we + ea) - (nw + ne + sw + se) - (ww + ee) + 0.5f * (nn + ss)) / 8;
			float along = (5 * cc + 4 * (n + s) - (nw + ne + sw + se) - (nn + ss) + 0.5f * (ww + ee)) / 8;
			bool red_row = colour[here_y * 2 + ((x + 1) & 1)] == 0;

			g = cc;
			r = red_row ? across : along;
			bl = red_row ? along : across;
		} else {
			float gg = (4 * cc + 2 * (n + s + we + ea) - (nn + ss + ww + ee)) / 8;
			float other = (6 * cc + 2 * (nw + ne + sw + se) - 1.5f * (nn + ss + ww + ee)) / 8;

			g = gg;
			r = site == 0 ? cc : other;
			bl = site == 2 ? cc : other;
		}
		pixel(isp, &p, r < 0 ? 0 : r, g < 0 ? 0 : g, bl < 0 ? 0 : bl, rgb + 3 * x);
	}
}

void
isp_finish_rows(uint8_t *y, size_t y_stride, uint8_t *uv, size_t uv_stride, uint32_t width, uint32_t height, uint32_t first_row,
    uint32_t end_row, float gain, bool still)
{
	/*
	 * Luma: y + amount x (y - the mean of its 4 neighbours), the difference cut by the coring so that the sensor's noise is not
	 * sharpened with the edges. A photograph has one pixel of the sensor to a pixel: 3/4; the preview is magnified: 1/2.
	 */
	int amount = gain > 8 ? 1 : gain > 3 ? 2 : still ? 3 : 2;       /* in quarters */
	int core = gain > 8 ? 6 : gain > 3 ? 4 : 2;
	static __thread uint8_t *prev;
	static __thread uint32_t have;

	if (width > have) {
		free(prev);
		prev = malloc((size_t)width * 2);
		have = prev != NULL ? width : 0;
	}
	if (prev == NULL || width < 3 || height < 3) {
		return;
	}
	uint32_t r0 = first_row == 0 ? 1 : first_row, r1 = end_row >= height ? height - 1 : end_row;

	memcpy(prev, y + (size_t)(r0 - 1) * y_stride, width);
	for (uint32_t r = r0; r < r1; r++) {
		uint8_t *o = y + (size_t)r * y_stride;
		const uint8_t *below = o + y_stride;
		int left = o[0];

		memcpy(prev + width, o, width);
		for (uint32_t x = 1; x + 1 < width; x++) {
			int v = o[x], diff = 4 * v - left - o[x + 1] - prev[x] - below[x], out;

			diff = diff > core * 4 ? diff - core * 4 : diff < -core * 4 ? diff + core * 4 : 0;
			out = v + diff * amount / 16;
			left = v;
			o[x] = (uint8_t)(out < 0 ? 0 : out > 255 ? 255 : out);
		}
		memcpy(prev, prev + width, width);
	}
	/* Chroma (half height, half width): [1 2 1] each way, a second time at high gain; a preview at low gain skips it (its cells are binned) */
	if (!still && gain <= 8) {
		return;
	}
	int passes = gain > 8 ? 2 : 1;
	uint32_t c0 = first_row / 2, c1 = end_row / 2 >= height / 2 ? height / 2 : end_row / 2, cw = width & ~1u;

	if (c0 == 0) {
		c0 = 1;
	}
	if (c1 >= height / 2) {
		c1 = height / 2 - 1;
	}
	for (int pass = 0; pass < passes; pass++) {
		memcpy(prev, uv + (size_t)(c0 - 1) * uv_stride, cw);
		for (uint32_t r = c0; r < c1; r++) {
			uint8_t *o = uv + (size_t)r * uv_stride;
			const uint8_t *below = o + uv_stride;
			int l[2] = { o[0], o[1] };

			memcpy(prev + width, o, cw);
			for (uint32_t x = 2; x + 3 < cw; x += 2) {
				for (int k = 0; k < 2; k++) {
					int v = o[x + (uint32_t)k];

					o[x + (uint32_t)k] = (uint8_t)((4 * v + 2 * (l[k] + o[x + (uint32_t)k + 2] + prev[x + (uint32_t)k] + below[x + (uint32_t)k]) + 6) / 12);
					l[k] = v;
				}
			}
			memcpy(prev, prev + width, cw);
		}
	}
}
