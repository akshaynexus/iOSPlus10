/* laurel: see surface_formats.h */
#include "surface_formats.h"

#include <math.h>
#include <string.h>

#define FOURCC(s) ((uint32_t)(s)[0] << 24 | (uint32_t)(s)[1] << 16 | (uint32_t)(s)[2] << 8 | (uint32_t)(s)[3])

static const struct lsf_format known[] = {
	{ FOURCC("BGRA"), LSF_BGRA, 1, 1, 1, 4, false, "blue-first bytes" },
	{ FOURCC("RGBA"), LSF_RGBA, 1, 1, 1, 4, false, "red-first bytes" },
	{ FOURCC("w30r"), LSF_XR_BGR10, 1, 1, 1, 3, false, "BGR10_XR words" },
	{ FOURCC("w30R"), LSF_XR_BGR10, 1, 1, 1, 3, false, "BGR10_XR words" },
	{ FOURCC("l10r"), LSF_BGR10A2, 1, 1, 1, 4, false, "BGR10A2 words" },
	{ FOURCC("R10k"), LSF_RGB10A2, 1, 1, 1, 4, false, "RGB10A2 words" },
	{ FOURCC("w40a"), LSF_XR_BGRA16, 1, 1, 1, 4, false, "BGRA10_XR, 16 bits a field" },
	{ FOURCC("w40p"), LSF_XR_BGRA16, 1, 1, 1, 4, false, "BGRA10_XR, 16 bits a field" },
	{ FOURCC("b3a8"), LSF_XR_2P, 1, 1, 1, 4, false, "BGR10_XR words + alpha plane" },
	{ FOURCC("RGhA"), LSF_HALF, 1, 1, 1, 4, false, "half floats" },
	{ FOURCC("RGfA"), LSF_FLOAT, 1, 1, 1, 4, false, "floats" },
	{ FOURCC("L00h"), LSF_HALF, 1, 1, 1, 1, false, "half floats" },
	{ FOURCC("2C0h"), LSF_HALF, 1, 1, 1, 2, false, "half floats" },
	{ FOURCC("L00f"), LSF_FLOAT, 1, 1, 1, 1, false, "floats" },
	{ FOURCC("2C0f"), LSF_FLOAT, 1, 1, 1, 2, false, "floats" },
	{ FOURCC("L565"), LSF_565, 1, 1, 1, 3, false, "5-6-5 words" },
	{ FOURCC("L555"), LSF_555, 1, 1, 1, 3, false, "5-5-5 words" },
	{ FOURCC("4444"), LSF_4444, 1, 1, 1, 4, false, "4-4-4-4 words" },
	{ FOURCC("L008"), LSF_L8, 1, 1, 1, 1, false, "luminance bytes" },
	{ FOURCC("A008"), LSF_A8, 1, 1, 1, 1, false, "alpha bytes" },
	{ FOURCC("LA08"), LSF_LA8, 1, 1, 1, 2, false, "luminance + alpha bytes" },
	{ FOURCC("2C08"), LSF_RG8, 1, 1, 1, 2, false, "two-channel bytes" },
	{ FOURCC("L016"), LSF_L16, 1, 1, 1, 1, false, "16-bit luminance" },
	{ FOURCC("_RB4"), LSF_RGB8_2P, 1, 1, 1, 3, false, "RenderBox RGB8_444_2P: green plane + blue-red plane" },
	{ FOURCC("420f"), LSF_YUV_2P8, 1, 2, 2, 3, false, "Y + CbCr 4:2:0, full range" },
	{ FOURCC("420v"), LSF_YUV_2P8, 0, 2, 2, 3, false, "Y + CbCr 4:2:0, video range" },
	{ FOURCC("422f"), LSF_YUV_2P8, 1, 2, 1, 3, false, "Y + CbCr 4:2:2, full range" },
	{ FOURCC("422v"), LSF_YUV_2P8, 0, 2, 1, 3, false, "Y + CbCr 4:2:2, video range" },
	{ FOURCC("444f"), LSF_YUV_2P8, 1, 1, 1, 3, false, "Y + CbCr 4:4:4, full range" },
	{ FOURCC("444v"), LSF_YUV_2P8, 0, 1, 1, 3, false, "Y + CbCr 4:4:4, video range" },
	{ FOURCC("xf20"), LSF_YUV_2P10, 1, 2, 2, 3, false, "10-bit Y + CbCr 4:2:0, full range" },
	{ FOURCC("x420"), LSF_YUV_2P10, 0, 2, 2, 3, false, "10-bit Y + CbCr 4:2:0, video range" },
	{ FOURCC("xf22"), LSF_YUV_2P10, 1, 2, 1, 3, false, "10-bit Y + CbCr 4:2:2, full range" },
	{ FOURCC("x422"), LSF_YUV_2P10, 0, 2, 1, 3, false, "10-bit Y + CbCr 4:2:2, video range" },
	{ FOURCC("xf44"), LSF_YUV_2P10, 1, 1, 1, 3, false, "10-bit Y + CbCr 4:4:4, full range" },
	{ FOURCC("x444"), LSF_YUV_2P10, 0, 1, 1, 3, false, "10-bit Y + CbCr 4:4:4, video range" },
	{ FOURCC("pf20"), LSF_YUV_2P10P, 1, 2, 2, 3, false, "packed 10-bit Y + CbCr 4:2:0, full range" },
	{ FOURCC("p420"), LSF_YUV_2P10P, 0, 2, 2, 3, false, "packed 10-bit Y + CbCr 4:2:0, video range" },
	{ FOURCC("pf22"), LSF_YUV_2P10P, 1, 2, 1, 3, false, "packed 10-bit Y + CbCr 4:2:2, full range" },
	{ FOURCC("p422"), LSF_YUV_2P10P, 0, 2, 1, 3, false, "packed 10-bit Y + CbCr 4:2:2, video range" },
	{ FOURCC("pf44"), LSF_YUV_2P10P, 1, 1, 1, 3, false, "packed 10-bit Y + CbCr 4:4:4, full range" },
	{ FOURCC("p444"), LSF_YUV_2P10P, 0, 1, 1, 3, false, "packed 10-bit Y + CbCr 4:4:4, video range" },
	{ FOURCC("xf4p"), LSF_YUV_1P10, 1, 1, 1, 3, false, "10-bit YCbCr 4:4:4 words" },
	{ FOURCC("yuvs"), LSF_YUYV, 0, 2, 1, 3, false, "YUYV, video range" },
	{ FOURCC("yuvf"), LSF_YUYV, 1, 2, 1, 3, false, "YUYV, full range" },
	{ FOURCC("2vuy"), LSF_UYVY, 0, 2, 1, 3, false, "UYVY, video range" },
	{ FOURCC("2vuf"), LSF_UYVY, 1, 2, 1, 3, false, "UYVY, full range" },
};

/* What a surface of an unknown OSType is taken for: its layout decides. */
static const struct lsf_format guesses[] = {
	{ 0, LSF_BGRA, 1, 1, 1, 4, true, "one plane, 4 bytes: taken as blue-first bytes" },
	{ 0, LSF_HALF, 1, 1, 1, 4, true, "one plane, 8 bytes: taken as half floats" },
	{ 0, LSF_FLOAT, 1, 1, 1, 4, true, "one plane, 16 bytes: taken as floats" },
	{ 0, LSF_LA8, 1, 1, 1, 2, true, "one plane, 2 bytes: taken as luminance + alpha" },
	{ 0, LSF_L8, 1, 1, 1, 1, true, "one plane, 1 byte: taken as luminance" },
	{ 0, LSF_YUV_2P8, 1, 1, 1, 3, true, "planes of 1 + 2 bytes: taken as Y + CbCr 4:4:4" },
	{ 0, LSF_YUV_2P8, 1, 2, 1, 3, true, "planes of 1 + 2 bytes: taken as Y + CbCr 4:2:2" },
	{ 0, LSF_YUV_2P8, 1, 2, 2, 3, true, "planes of 1 + 2 bytes: taken as Y + CbCr 4:2:0" },
	{ 0, LSF_YUV_2P10, 1, 1, 1, 3, true, "planes of 2 + 4 bytes: taken as 10-bit Y + CbCr" },
	{ 0, LSF_XR_2P, 1, 1, 1, 4, true, "planes of 4 + 1 bytes: taken as BGR10_XR + alpha" },
};

const struct lsf_format *
lsf_find(uint32_t ostype, unsigned planes, const struct lsf_plane *plane)
{
	for (size_t i = 0; i < sizeof(known) / sizeof(known[0]); i++) {
		if (known[i].ostype == ostype) {
			return &known[i];
		}
	}
	if (planes >= 2 && plane[0].bytes == 1 && plane[1].bytes == 2) {
		if (plane[1].height * 2 <= plane[0].height) {
			return &guesses[7];
		}
		return plane[1].width * 2 <= plane[0].width ? &guesses[6] : &guesses[5];
	}
	if (planes >= 2 && plane[0].bytes == 2 && plane[1].bytes == 4) {
		return &guesses[8];
	}
	if (planes >= 2 && plane[0].bytes == 4 && plane[1].bytes == 1) {
		return &guesses[9];
	}
	switch (plane[0].bytes) {
	case 8: return &guesses[1];
	case 16: return &guesses[2];
	case 2: return &guesses[3];
	case 1: return &guesses[4];
	default: return &guesses[0];
	}
}

const struct lsf_format *
lsf_of_metal(uint32_t pixel_format)
{
	uint32_t ostype;

	switch (pixel_format) {
	case 554: case 555: ostype = FOURCC("w30r"); break;     /* BGR10_XR, _sRGB [V RenderBox table 0x1e69456f0] */
	case 552: case 553: ostype = FOURCC("w40a"); break;     /* BGRA10_XR, _sRGB */
	case 94: case 95: ostype = FOURCC("l10r"); break;       /* BGR10A2Unorm */
	case 90: case 91: ostype = FOURCC("R10k"); break;       /* RGB10A2Unorm */
	case 70: case 71: ostype = FOURCC("RGBA"); break;       /* RGBA8Unorm, _sRGB */
	default: return NULL;
	}
	for (size_t i = 0; i < sizeof(known) / sizeof(known[0]); i++) {
		if (known[i].ostype == ostype) {
			return &known[i];
		}
	}
	return NULL;
}

void
lsf_name(uint32_t ostype, char name[5])
{
	for (int i = 0; i < 4; i++) {
		uint8_t c = (uint8_t)(ostype >> (24 - 8 * i));

		name[i] = c >= 32 && c < 127 ? (char)c : '.';
	}
	name[4] = 0;
}

static inline uint8_t
clamp8(int v)
{
	return v < 0 ? 0 : v > 255 ? 255 : (uint8_t)v;
}

/* (code - 384) / 510, clipped, as a byte: Metal's extended-range code, the picture's own non-linear value */
static const uint8_t *
xr_table(void)
{
	static uint8_t table[1024];
	static bool ready;

	if (!ready) {
		for (int c = 0; c < 1024; c++) {
			table[c] = clamp8(((c - 384) * 255 * 2 + 510) / (2 * 510));
		}
		ready = true;
	}
	return table;
}

static float
half_value(uint16_t h)
{
	int e = (h >> 10) & 31, m = h & 1023;
	float v = e == 0 ? (float)m * (1.0f / 16777216.0f) : e == 31 ? 1.0f : ldexpf((float)(m + 1024), e - 25);

	return (h & 0x8000) ? -v : v;
}

static uint8_t
value8(float v, bool linear)
{
	if (!(v > 0.0f)) {
		return 0;
	}
	if (v >= 1.0f) {
		return 255;
	}
	if (linear) {
		v = v <= 0.0031308f ? v * 12.92f : 1.055f * powf(v, 1.0f / 2.4f) - 0.055f;
	}
	return (uint8_t)(v * 255.0f + 0.5f);
}

static inline uint32_t
word_at(const uint8_t *p)
{
	return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

static inline uint16_t
half_at(const uint8_t *p)
{
	return (uint16_t)(p[0] | p[1] << 8);
}

static inline void
put(uint8_t *to, uint8_t r, uint8_t g, uint8_t b, uint8_t a)
{
	to[0] = b;
	to[1] = g;
	to[2] = r;
	to[3] = a;
}

/* Y, Cb, Cr codes of 8 bits to a pixel, through the matrix's coefficients in 16.16 */
struct yuv_rows {
	int y_off, y_scale, c_scale, r_cr, g_cb, g_cr, b_cb;
};

static void
yuv_setup(struct yuv_rows *m, enum lsf_matrix matrix, bool full)
{
	static const float k[3][4] = { { 1.402f, 0.344136f, 0.714136f, 1.772f }, { 1.5748f, 0.1873f, 0.4681f, 1.8556f },
		                       { 1.4746f, 0.16455f, 0.57135f, 1.8814f } };
	const float *c = k[matrix];
	float cs = full ? 1.0f : 255.0f / 224.0f;

	m->y_off = full ? 0 : 16;
	m->y_scale = (int)((full ? 1.0f : 255.0f / 219.0f) * 65536.0f);
	m->c_scale = (int)(cs * 65536.0f);
	m->r_cr = (int)(c[0] * cs * 65536.0f);
	m->g_cb = (int)(c[1] * cs * 65536.0f);
	m->g_cr = (int)(c[2] * cs * 65536.0f);
	m->b_cb = (int)(c[3] * cs * 65536.0f);
}

static inline void
yuv_put(uint8_t *to, const struct yuv_rows *m, int y, int cb, int cr)
{
	int l = (y - m->y_off) * m->y_scale + 32768;

	cb -= 128;
	cr -= 128;
	put(to, clamp8((l + m->r_cr * cr) >> 16), clamp8((l - m->g_cb * cb - m->g_cr * cr) >> 16), clamp8((l + m->b_cb * cb) >> 16), 255);
}

static inline uint32_t
packed_code(const uint8_t *row, uint32_t index)
{
	return (word_at(row + (index / 3) * 4) >> ((index % 3) * 10)) & 1023;
}

/* One row, `y` of the surface. Reads stay inside the planes' width x height (chroma: nearest, clamped to its plane). */
static void
convert_row(const struct lsf_format *f, const struct yuv_rows *m, bool linear, const struct lsf_plane *p, unsigned planes, uint32_t width,
    uint32_t y, uint8_t *to)
{
	const uint8_t *xr = xr_table();
	const uint8_t *r0 = p[0].base + p[0].row * y;
	const uint8_t *r1 = NULL;
	uint32_t cw = 0;

	if (planes >= 2) {
		uint32_t cy = y / f->sub_y;

		cy = cy < p[1].height ? cy : p[1].height - 1;
		r1 = p[1].base + p[1].row * cy;
		cw = p[1].width;
	}
	for (uint32_t x = 0; x < width; x++, to += 4) {
		uint32_t cx = planes >= 2 ? (x / f->sub_x < cw ? x / f->sub_x : cw - 1) : 0, w;

		switch (f->kind) {
		case LSF_BGRA:
			memcpy(to, r0 + x * 4, 4);
			break;
		case LSF_RGBA:
			put(to, r0[x * 4], r0[x * 4 + 1], r0[x * 4 + 2], r0[x * 4 + 3]);
			break;
		case LSF_XR_BGR10:
			w = word_at(r0 + x * 4);
			put(to, xr[(w >> 20) & 1023], xr[(w >> 10) & 1023], xr[w & 1023], 255);
			break;
		case LSF_XR_2P:
			w = word_at(r0 + x * 4);
			put(to, xr[(w >> 20) & 1023], xr[(w >> 10) & 1023], xr[w & 1023], r1 != NULL ? r1[cx] : 255);
			break;
		case LSF_BGR10A2:
			w = word_at(r0 + x * 4);
			put(to, (uint8_t)((w >> 22) & 255), (uint8_t)((w >> 12) & 255), (uint8_t)((w >> 2) & 255), (uint8_t)((w >> 30) * 85));
			break;
		case LSF_RGB10A2:
			w = word_at(r0 + x * 4);
			put(to, (uint8_t)((w >> 2) & 255), (uint8_t)((w >> 12) & 255), (uint8_t)((w >> 22) & 255), (uint8_t)((w >> 30) * 85));
			break;
		case LSF_XR_BGRA16: {
			const uint8_t *q = r0 + x * 8;

			put(to, xr[half_at(q + 4) >> 6], xr[half_at(q + 2) >> 6], xr[half_at(q) >> 6], xr[half_at(q + 6) >> 6]);
			break;
		}
		case LSF_HALF: {
			const uint8_t *q = r0 + x * 2u * f->channels;
			uint8_t v0 = value8(half_value(half_at(q)), linear);

			if (f->channels == 1) {
				put(to, v0, v0, v0, 255);
			} else if (f->channels == 2) {
				put(to, v0, value8(half_value(half_at(q + 2)), linear), 0, 255);
			} else {
				put(to, v0, value8(half_value(half_at(q + 2)), linear), value8(half_value(half_at(q + 4)), linear),
				    value8(half_value(half_at(q + 6)), false));
			}
			break;
		}
		case LSF_FLOAT: {
			float v[4] = { 0, 0, 0, 1 };

			memcpy(v, r0 + x * 4u * f->channels, 4u * f->channels);
			if (f->channels == 1) {
				v[2] = v[1] = v[0];
			}
			put(to, value8(v[0], linear), value8(v[1], linear), value8(v[2], linear), value8(v[3], false));
			break;
		}
		case LSF_565:
			w = half_at(r0 + x * 2);
			put(to, (uint8_t)((w >> 11) * 255 / 31), (uint8_t)(((w >> 5) & 63) * 255 / 63), (uint8_t)((w & 31) * 255 / 31), 255);
			break;
		case LSF_555:
			w = half_at(r0 + x * 2);
			put(to, (uint8_t)(((w >> 10) & 31) * 255 / 31), (uint8_t)(((w >> 5) & 31) * 255 / 31), (uint8_t)((w & 31) * 255 / 31), 255);
			break;
		case LSF_4444:
			w = half_at(r0 + x * 2);
			put(to, (uint8_t)(((w >> 8) & 15) * 17), (uint8_t)(((w >> 4) & 15) * 17), (uint8_t)((w & 15) * 17), (uint8_t)(((w >> 12) & 15) * 17));
			break;
		case LSF_L8:
			put(to, r0[x], r0[x], r0[x], 255);
			break;
		case LSF_A8:
			put(to, 0, 0, 0, r0[x]);
			break;
		case LSF_LA8:
			put(to, r0[x * 2], r0[x * 2], r0[x * 2], r0[x * 2 + 1]);
			break;
		case LSF_RG8:
			put(to, r0[x * 2], r0[x * 2 + 1], 0, 255);
			break;
		case LSF_L16:
			put(to, r0[x * 2 + 1], r0[x * 2 + 1], r0[x * 2 + 1], 255);
			break;
		case LSF_RGB8_2P:
			/* [V metal2vulkan ycbcr_write.rs, Apple M4 probes] Codes: Y the green channel, Cb the blue, Cr the red */
			put(to, r1 != NULL ? r1[cx * 2 + 1] : 0, r0[x], r1 != NULL ? r1[cx * 2] : 0, 255);
			break;
		case LSF_YUV_2P8:
			yuv_put(to, m, r0[x], r1 != NULL ? r1[cx * 2] : 128, r1 != NULL ? r1[cx * 2 + 1] : 128);
			break;
		case LSF_YUV_2P10:
			yuv_put(to, m, r0[x * 2 + 1], r1 != NULL ? r1[cx * 4 + 1] : 128, r1 != NULL ? r1[cx * 4 + 3] : 128);
			break;
		case LSF_YUV_2P10P:
			yuv_put(to, m, (int)(packed_code(r0, x) >> 2), r1 != NULL ? (int)(packed_code(r1, cx * 2) >> 2) : 128,
			    r1 != NULL ? (int)(packed_code(r1, cx * 2 + 1) >> 2) : 128);
			break;
		case LSF_YUV_1P10:
			w = word_at(r0 + x * 4);
			yuv_put(to, m, (int)((w >> 12) & 255), (int)((w >> 2) & 255), (int)((w >> 22) & 255));
			break;
		case LSF_YUYV:
			yuv_put(to, m, r0[x * 2], r0[(x & ~1u) * 2 + 1], r0[(x & ~1u) * 2 + 3]);
			break;
		case LSF_UYVY:
			yuv_put(to, m, r0[x * 2 + 1], r0[(x & ~1u) * 2], r0[(x & ~1u) * 2 + 2]);
			break;
		default:
			put(to, 0, 0, 0, 255);
			break;
		}
	}
}

void
lsf_convert(const struct lsf_format *f, enum lsf_matrix matrix, bool linear, const struct lsf_plane *plane, unsigned planes, uint32_t width,
    uint32_t height, uint8_t *out, size_t out_row, bool invert)
{
	struct yuv_rows m;
	uint32_t use_w = width < plane[0].width ? width : plane[0].width, use_h = height < plane[0].height ? height : plane[0].height;

	if (planes >= 2 && (plane[1].base == NULL || plane[1].width == 0 || plane[1].height == 0)) {
		planes = 1;
	}
	yuv_setup(&m, matrix, f->full_range != 0);
	for (uint32_t y = 0; y < height; y++) {
		uint8_t *to = out + out_row * (invert ? height - 1 - y : y);

		if (y < use_h) {
			convert_row(f, &m, linear, plane, planes, use_w, y, to);
			if (use_w < width) {
				memset(to + use_w * 4, 0, (width - use_w) * 4);
			}
		} else {
			memset(to, 0, width * 4);
		}
	}
}

/* up to 64 places across and down, in the middle of their cells: a widget's text and pictures fall on some of them */
static inline uint32_t
step_of(uint32_t size)
{
	uint32_t step = size / 64;

	return step == 0 ? 1 : step;
}

/* laurel: the mean colour, red green blue: a false colour in a picture shows here (the purple of boot 22:08 has no other trace in a log) */
static void
lsf_mean(struct lsf_contents *c, const uint64_t sum[3])
{
	for (int i = 0; i < 3; i++) {
		c->mean[i] = c->samples != 0 ? (uint8_t)(sum[i] / c->samples) : 0;
	}
}

void
lsf_contents_of_pixels(const struct lsf_format *f, const uint8_t *pixels, size_t row, uint32_t width, uint32_t height, struct lsf_contents *c)
{
	uint32_t sx = step_of(width), sy = step_of(height), first = 0;
	uint64_t sum[3] = { 0, 0, 0 };
	bool alpha = f != NULL && f->kind == LSF_A8;

	memset(c, 0, sizeof(*c));
	for (uint32_t y = sy / 2; y < height; y += sy) {
		for (uint32_t x = sx / 2; x < width; x += sx) {
			uint32_t w = word_at(pixels + row * y + x * 4), colour = alpha ? w : w & 0xffffffu;

			if (c->samples++ == 0) {
				first = colour;
			}
			c->lit += colour != 0;
			c->unlike += colour != first;
			sum[0] += (colour >> 16) & 255;
			sum[1] += (colour >> 8) & 255;
			sum[2] += colour & 255;
		}
	}
	lsf_mean(c, sum);
}

void
lsf_contents_of_words(enum lsf_kind kind, const uint8_t *words, size_t row, uint32_t width, uint32_t height, struct lsf_contents *c)
{
	uint32_t sx = step_of(width), sy = step_of(height), first = 0;
	uint64_t sum[3] = { 0, 0, 0 };
	const uint8_t *xr = xr_table();

	memset(c, 0, sizeof(*c));
	for (uint32_t y = sy / 2; y < height; y += sy) {
		for (uint32_t x = sx / 2; x < width; x += sx) {
			uint32_t w = word_at(words + row * y + x * 4), colour;

			if (kind == LSF_XR_BGR10) {
				colour = (uint32_t)xr[(w >> 20) & 1023] << 16 | (uint32_t)xr[(w >> 10) & 1023] << 8 | xr[w & 1023];
			} else if (kind == LSF_BGR10A2 || kind == LSF_RGB10A2) {
				colour = w & 0x3fffffffu;
			} else {
				colour = w & 0xffffffu; /* blue-first bytes: clear and opaque black both count as not lit */
			}
			if (c->samples++ == 0) {
				first = colour;
			}
			c->lit += colour != 0;
			c->unlike += colour != first;
			sum[0] += (colour >> 16) & 255;
			sum[1] += (colour >> 8) & 255;
			sum[2] += colour & 255;
		}
	}
	lsf_mean(c, sum);
}

/* '_RB4': plane 0 green bytes, plane 1 (blue, red) byte pairs */
void
lsf_contents_of_rb4(const struct lsf_plane *plane, uint32_t width, uint32_t height, struct lsf_contents *c)
{
	uint32_t sx = step_of(width), sy = step_of(height), first = 0;
	uint64_t sum[3] = { 0, 0, 0 };

	memset(c, 0, sizeof(*c));
	for (uint32_t y = sy / 2; y < height; y += sy) {
		for (uint32_t x = sx / 2; x < width; x += sx) {
			const uint8_t *br = plane[1].base + plane[1].row * y + x * 2u;
			uint32_t g = plane[0].base[plane[0].row * y + x], colour = (uint32_t)br[1] << 16 | g << 8 | br[0];

			if (c->samples++ == 0) {
				first = colour;
			}
			c->lit += colour != 0;
			c->unlike += colour != first;
			sum[0] += br[1];
			sum[1] += g;
			sum[2] += br[0];
		}
	}
	lsf_mean(c, sum);
}
