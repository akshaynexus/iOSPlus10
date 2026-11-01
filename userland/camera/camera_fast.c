/*
 * NegroniCamera (iOSPlus10, Mi A3 camera speed; docs/laurel_sprout/camera.md section 13): the moving picture without the float path. The old path took each cell through
 * lsc_at() (3 bilinear gains in float), pixel() (a float matrix) and curve(), then bilinear in R, G, B to 1504x1128, then a sharpen of all those pixels.
 * Here each row of cells goes as whole lines (the compiler's vector loops): RAW10 -> lines of R, G, B -> lens shading from gains made every 32 cells -> matrix ->
 * gamma table -> Y for each cell, Cb and Cr for each 2 cells. Then the sharpen on the cells' Y and bilinear of each plane to the picture (no RGB stage).
 * The numbers of the pipe (white balance, digital gain, colour matrix, gamma) are those of pipe_init(). A step of 2 takes every second cell each way: a quarter of the work.
 */
#include <stdlib.h>
#include <string.h>
#include "camera_fast.h"
#include "camera_isp_int.h"

#define LSC_BLOCK       32u
#define COLS            FAST_MAX_CELLS

static inline uint32_t
scale_pos(uint32_t i, uint32_t cells, uint32_t n)
{
	uint64_t at = ((uint64_t)(2 * i + 1) * cells * 128) / n;

	return at < 128 ? 0 : (uint32_t)(at - 128);
}

static void
scale_table(uint32_t cells, uint32_t n, uint16_t *cx, uint8_t *tx)
{
	for (uint32_t x = 0; x < n; x++) {
		uint32_t at = scale_pos(x, cells, n);

		cx[x] = (uint16_t)(at >> 8 < cells ? at >> 8 : cells - 1);
		tx[x] = (uint8_t)(at & 255);
	}
}

bool
isp_fast_begin(struct isp_fast *z, const struct isp *isp, const struct negronicam_frame *f, uint32_t width, uint32_t height, uint32_t step)
{
	uint32_t cw, ch;
	size_t need;

	isp_cells_size(isp, f, width, height, &cw, &ch);
	if (cw >= width || ch >= height || width > FAST_MAX_WIDTH || cw > FAST_MAX_CELLS * step || (cw / step) < 16 || (ch / step) < 16) {
		return false;
	}
	z->x0 = (f->width / 2 - cw) / 2;
	z->y0 = (f->height / 2 - ch) / 2;
	z->step = step;
	z->cw = cw / step;
	z->ch = ch / step;
	need = (size_t)z->cw * z->ch * 3;
	if (need > z->bytes) {
		free(z->plane);
		z->plane = malloc(need);
		z->bytes = z->plane != NULL ? need : 0;
		if (z->plane == NULL) {
			return false;
		}
	}
	z->y = z->plane;
	z->sharp = z->plane + (size_t)z->cw * z->ch;
	z->cb = z->sharp + (size_t)z->cw * z->ch;
	z->cr = z->cb + (size_t)(z->cw / 2) * z->ch;
	if (z->table_cw != z->cw || z->table_w != width) {
		z->table_cw = z->cw;
		z->table_w = width;
		scale_table(z->cw, width, z->cx, z->tx);
		scale_table(z->cw / 2, width / 2, z->cx2, z->tx2);
	}
	return true;
}

/* The two lines of one row of cells, each place apart, above black and not under 0. An even start, every cell: whole 5-byte groups. */
static void
unpack(const uint8_t *top, size_t stride, uint32_t x0, uint32_t step, uint32_t n, int16_t v[4][COLS])
{
	if (step == 1 && (x0 & 1) == 0) {
		const uint8_t *g0 = top + (size_t)(x0 >> 1) * 5, *g1 = g0 + stride;

		for (uint32_t x = 0; x + 1 < n; x += 2, g0 += 5, g1 += 5) {
			uint32_t l0 = g0[4], l1 = g1[4];

			v[0][x] = (int16_t)(g0[0] << 2 | (l0 & 3));
			v[1][x] = (int16_t)(g0[1] << 2 | (l0 >> 2 & 3));
			v[0][x + 1] = (int16_t)(g0[2] << 2 | (l0 >> 4 & 3));
			v[1][x + 1] = (int16_t)(g0[3] << 2 | l0 >> 6);
			v[2][x] = (int16_t)(g1[0] << 2 | (l1 & 3));
			v[3][x] = (int16_t)(g1[1] << 2 | (l1 >> 2 & 3));
			v[2][x + 1] = (int16_t)(g1[2] << 2 | (l1 >> 4 & 3));
			v[3][x + 1] = (int16_t)(g1[3] << 2 | l1 >> 6);
		}
		if (n & 1) {
			uint32_t x = n - 1;

			v[0][x] = (int16_t)(g0[0] << 2 | (g0[4] & 3));
			v[1][x] = (int16_t)(g0[1] << 2 | (g0[4] >> 2 & 3));
			v[2][x] = (int16_t)(g1[0] << 2 | (g1[4] & 3));
			v[3][x] = (int16_t)(g1[1] << 2 | (g1[4] >> 2 & 3));
		}
	} else {
		for (uint32_t x = 0; x < n; x++) {
			uint32_t cx = x0 + x * step, o = (cx & 1) * 2;
			const uint8_t *g0 = top + (size_t)(cx >> 1) * 5, *g1 = g0 + stride;

			v[0][x] = (int16_t)(g0[o] << 2 | (g0[4] >> (o * 2) & 3));
			v[1][x] = (int16_t)(g0[o + 1] << 2 | (g0[4] >> (o * 2 + 2) & 3));
			v[2][x] = (int16_t)(g1[o] << 2 | (g1[4] >> (o * 2) & 3));
			v[3][x] = (int16_t)(g1[o + 1] << 2 | (g1[4] >> (o * 2 + 2) & 3));
		}
	}
	for (int p = 0; p < 4; p++) {
		int16_t *restrict a = v[p];

		for (uint32_t x = 0; x < n; x++) {
			int16_t s = (int16_t)(a[x] - 64);

			a[x] = s < 0 ? 0 : s;
		}
	}
}

/* the lens shading's gains along a row of cells: exact every LSC_BLOCK cells, a straight line between */
static void
row_gains(const struct isp *isp, const struct isp_fast *z, const struct negronicam_frame *f, uint32_t sy, uint32_t n, float gain[3][COLS])
{
	uint32_t cells_w = f->width / 2, cells_h = f->height / 2;
	float v = cells_h > 1 ? (float)sy / (cells_h - 1) : 0, a[3], b[3];

	for (uint32_t at = 0; at < n; at += LSC_BLOCK) {
		uint32_t end = at + LSC_BLOCK < n ? at + LSC_BLOCK : n;
		float ua = (float)(z->x0 + at * z->step) / (cells_w > 1 ? cells_w - 1 : 1), ub = (float)(z->x0 + (at + LSC_BLOCK) * z->step) / (cells_w > 1 ? cells_w - 1 : 1);

		lsc_at(isp, ua, v, a);
		lsc_at(isp, ub > 1 ? 1 : ub, v, b);
		for (int c = 0; c < 3; c++) {
			float d = (b[c] - a[c]) / LSC_BLOCK, *restrict o = gain[c] + at, s = a[c];

			for (uint32_t i = 0; i < end - at; i++) {
				o[i] = s + d * (float)i;
			}
		}
	}
}

void
isp_fast_cells(const struct isp_fast *z, const struct isp *isp, const struct negronicam_frame *f, const uint8_t *raw, uint32_t first, uint32_t end, bool video_range)
{
	/* (BT.601 in 1/65536ths, as nv12_pair() in camera_isp.c) */
	static const int32_t full[9] = { 19595, 38470, 7471, -11058, -21710, 32768, 32768, -27439, -5329 };
	static const int32_t video[9] = { 16829, 33039, 6416, -9714, -19070, 28784, 28784, -24103, -4681 };
	const int32_t *k = video_range ? video : full;
	const int32_t oy = (video_range ? 16 << 16 : 0) + (1 << 15), oc = (128 << 17) + (1 << 16) - 1;
	struct pipe p;
	uint32_t n = z->cw, half = n / 2;
	int red = (int)(f->bayer & 3), blue = 3 - red;
	int16_t v[4][COLS];
	float gain[3][COLS], line[3][COLS];
	int32_t lut[3][COLS];
	uint8_t rgb[3][COLS];

	pipe_init(isp, &p);
	for (uint32_t row = first; row < end && row < z->ch; row++) {
		uint32_t sy = z->y0 + (isp->turned ? z->ch - 1 - row : row) * z->step;

		unpack(raw + (size_t)sy * 2 * f->stride, f->stride, z->x0, z->step, n, v);
		if (isp->lsc.on) {
			row_gains(isp, z, f, sy, n, gain);
		} else {
			for (uint32_t x = 0; x < n; x++) {
				gain[0][x] = gain[1][x] = gain[2][x] = 1;
			}
		}
		{
			const int16_t *restrict vr = v[red], *restrict vb = v[blue], *restrict g0 = v[red == 0 || red == 3 ? 1 : 0], *restrict g1 = v[red == 0 || red == 3 ? 2 : 3];
			const float *restrict gr = gain[0], *restrict gg = gain[1], *restrict gb = gain[2];
			float *restrict lr = line[0], *restrict lg = line[1], *restrict lb = line[2];

			for (uint32_t x = 0; x < n; x++) {
				lr[x] = (float)vr[x] * gr[x];
				lg[x] = (float)(g0[x] + g1[x]) * 0.5f * gg[x];
				lb[x] = (float)vb[x] * gb[x];
			}
		}
		for (int c = 0; c < 3; c++) {
			const float m0 = p.m[c][0], m1 = p.m[c][1], m2 = p.m[c][2];
			const float *restrict lr = line[0], *restrict lg = line[1], *restrict lb = line[2];
			int32_t *restrict o = lut[c];

			for (uint32_t x = 0; x < n; x++) {
				int32_t i = (int32_t)(m0 * lr[x] + m1 * lg[x] + m2 * lb[x] + 0.5f);

				i = i < 0 ? 0 : i;
				o[x] = i > 4095 ? 4095 : i;
			}
			for (uint32_t x = 0; x < n; x++) {
				rgb[c][x] = isp->gamma[o[x]];
			}
		}
		{
			uint32_t d = row;
			uint8_t *restrict oy_line = z->y + (size_t)d * n, *restrict ob = z->cb + (size_t)d * half, *restrict orr = z->cr + (size_t)d * half;
			const uint8_t *restrict R = rgb[0], *restrict G = rgb[1], *restrict B = rgb[2];

			for (uint32_t x = 0; x < n; x++) {
				oy_line[x] = (uint8_t)((k[0] * R[x] + k[1] * G[x] + k[2] * B[x] + oy) >> 16);
			}
			for (uint32_t x = 0; x < half; x++) {
				int32_t r = R[2 * x] + R[2 * x + 1], g = G[2 * x] + G[2 * x + 1], b = B[2 * x] + B[2 * x + 1];
				int32_t cb = (k[3] * r + k[4] * g + k[5] * b + oc) >> 17, cr = (k[6] * r + k[7] * g + k[8] * b + oc) >> 17;

				ob[x] = (uint8_t)(cb < 0 ? 0 : cb > 255 ? 255 : cb);
				orr[x] = (uint8_t)(cr < 0 ? 0 : cr > 255 ? 255 : cr);
			}
			if (isp->turned) {
				for (uint32_t x = 0; x < n / 2; x++) {
					uint8_t t = oy_line[x];

					oy_line[x] = oy_line[n - 1 - x];
					oy_line[n - 1 - x] = t;
				}
				for (uint32_t x = 0; x < half / 2; x++) {
					uint8_t t = ob[x], u = orr[x];

					ob[x] = ob[half - 1 - x];
					ob[half - 1 - x] = t;
					orr[x] = orr[half - 1 - x];
					orr[half - 1 - x] = u;
				}
			}
		}
	}
}

void
isp_fast_sharpen(const struct isp_fast *z, uint32_t first, uint32_t end, float gain)
{
	const int32_t amount = gain > 8 ? 1 : 2, core = (gain > 8 ? 6 : gain > 3 ? 4 : 2) * 4;
	uint32_t n = z->cw;

	for (uint32_t row = first; row < end && row < z->ch; row++) {
		const uint8_t *restrict in = z->y + (size_t)row * n;
		const uint8_t *restrict up = row > 0 ? in - n : in, *restrict down = row + 1 < z->ch ? in + n : in;
		uint8_t *restrict o = z->sharp + (size_t)row * n;

		o[0] = in[0];
		o[n - 1] = in[n - 1];
		for (uint32_t x = 1; x + 1 < n; x++) {
			int32_t c = in[x], diff = 4 * c - in[x - 1] - in[x + 1] - up[x] - down[x];
			int32_t cut = diff > core ? diff - core : diff < -core ? diff + core : 0;
			int32_t out = c + ((cut * amount) >> 4);

			o[x] = (uint8_t)(out < 0 ? 0 : out > 255 ? 255 : out);
		}
	}
}

/* one plane to a part of the picture: straight between 2 lines, then between 2 places of that line; noisy: 4 lines together (the chroma of a high gain) */
static void
scale_rows(const uint8_t *src, uint32_t sw, uint32_t sh, uint8_t *dst, size_t dst_stride, unsigned pixel, const uint16_t *cx, const uint8_t *tx, uint32_t dw,
    uint32_t dh, uint32_t first, uint32_t end, bool noisy)
{
	uint8_t tmp[COLS + 1];

	for (uint32_t row = first; row < end && row < dh; row++) {
		uint32_t at = scale_pos(row, sh, dh), y0 = at >> 8 < sh ? at >> 8 : sh - 1, y1 = y0 + 1 < sh ? y0 + 1 : y0;
		const uint8_t *restrict t = src + (size_t)y0 * sw, *restrict b = src + (size_t)y1 * sw;
		uint8_t *restrict hold = tmp;
		uint8_t *restrict o = dst + (size_t)row * dst_stride;

		if (noisy) {
			const uint8_t *restrict u = y0 > 0 ? t - sw : t, *restrict d = y1 + 1 < sh ? b + sw : b;

			for (uint32_t x = 0; x < sw; x++) {
				hold[x] = (uint8_t)((u[x] + t[x] + b[x] + d[x] + 2) >> 2);
			}
		} else {
			uint32_t ty = at & 255, ity = 256 - ty;

			for (uint32_t x = 0; x < sw; x++) {
				hold[x] = (uint8_t)((t[x] * ity + b[x] * ty + 128) >> 8);
			}
		}
		tmp[sw] = tmp[sw - 1];
		for (uint32_t x = 0; x < dw; x++) {
			uint32_t i = cx[x], a = tx[x];

			o[(size_t)x * pixel] = (uint8_t)((tmp[i] * (256 - a) + tmp[i + 1] * a + 128) >> 8);
		}
	}
}

void
isp_fast_scale(const struct isp_fast *z, uint8_t *y, size_t y_stride, uint8_t *uv, size_t uv_stride, uint32_t width, uint32_t height, uint32_t first, uint32_t end, float gain)
{
	bool noisy = gain > 8;

	scale_rows(z->sharp, z->cw, z->ch, y, y_stride, 1, z->cx, z->tx, width, height, first, end, false);
	scale_rows(z->cb, z->cw / 2, z->ch, uv, uv_stride, 2, z->cx2, z->tx2, width / 2, height / 2, first / 2, end / 2, noisy);
	scale_rows(z->cr, z->cw / 2, z->ch, uv + 1, uv_stride, 2, z->cx2, z->tx2, width / 2, height / 2, first / 2, end / 2, noisy);
}
