/*
 * Host test of surface_formats.c (no phone): every layout the docs name, from bytes written by hand.
 *   cc -std=c11 -I.. tests/surface_formats_test.c surface_formats.c -lm -o out && ./out     (scripts/laurel/gpu-surface-test.sh)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "surface_formats.h"

#define FOURCC(s) ((uint32_t)(s)[0] << 24 | (uint32_t)(s)[1] << 16 | (uint32_t)(s)[2] << 8 | (uint32_t)(s)[3])

static int failed;

static void
check(const char *name, const uint8_t *px, int r, int g, int b, int a, int slack)
{
	int dr = abs(px[2] - r), dg = abs(px[1] - g), db = abs(px[0] - b), da = abs(px[3] - a);

	if (dr > slack || dg > slack || db > slack || da > slack) {
		printf("FAIL %s: got RGBA %d %d %d %d, want %d %d %d %d\n", name, px[2], px[1], px[0], px[3], r, g, b, a);
		failed++;
	} else {
		printf("ok   %s\n", name);
	}
}

static void
one(const char *os, const void *p0, size_t row0, unsigned bytes0, const void *p1, size_t row1, unsigned bytes1, unsigned planes, uint8_t *out)
{
	struct lsf_plane plane[2] = { { p0, row0, 2, 2, bytes0 }, { p1, row1, 2, 2, bytes1 } };
	const struct lsf_format *f = lsf_find(FOURCC(os), planes, plane);

	lsf_convert(f, LSF_MATRIX_601, false, plane, planes ? planes : 1, 2, 2, out, 8, false);
}

int
main(void)
{
	uint8_t out[16];

	{	/* the owner's Earth: BGR10_XR black = code 384, white = 894, bits 31-30 ones (metal2vulkan extended_range.rs) */
		uint32_t w[4] = { 0xC0000000u | 384u << 20 | 384u << 10 | 384u, 0xC0000000u | 894u << 20 | 894u << 10 | 894u,
			          0xC0000000u | 639u << 20 | 384u << 10 | 894u, 0xC0000000u };
		one("w30r", w, 8, 4, NULL, 0, 0, 0, out);
		check("w30r black", out, 0, 0, 0, 255, 0);
		check("w30r white", out + 4, 255, 255, 255, 255, 0);
		check("w30r half red, full blue", out + 8, 128, 0, 255, 255, 1);
		check("w30r code 0 clips to black", out + 12, 0, 0, 0, 255, 0);
		/* read as BGRA that black is blue 128, red 6: what the photo shows */
		const uint8_t *as_bgra = (const uint8_t *)w;
		check("w30r black read as BGRA (the bug)", as_bgra, 6, 1, 128, 0xD8, 0);
	}
	{	/* _RB4: 2 x 2, green plane + (blue, red) pairs: rows 4 and 8 bytes apart */
		uint8_t g[8] = { 10, 20, 0, 0, 30, 40, 0, 0 }, br[16] = { 1, 2, 3, 4, 0, 0, 0, 0, 5, 6, 7, 8, 0, 0, 0, 0 };
		one("_RB4", g, 4, 1, br, 8, 2, 2, out);
		check("_RB4 0,0", out, 2, 10, 1, 255, 0);
		check("_RB4 1,0", out + 4, 4, 20, 3, 255, 0);
		check("_RB4 0,1", out + 8, 6, 30, 5, 255, 0);
		check("_RB4 1,1", out + 12, 8, 40, 7, 255, 0);
	}
	{	/* 420f BT.601: gray, and Cr 255 = red up */
		uint8_t y[4] = { 128, 128, 128, 128 }, c[2] = { 128, 128 };
		struct lsf_plane plane[2] = { { y, 2, 2, 2, 1 }, { c, 2, 1, 1, 2 } };
		lsf_convert(lsf_find(FOURCC("420f"), 2, plane), LSF_MATRIX_601, false, plane, 2, 2, 2, out, 8, false);
		check("420f gray", out, 128, 128, 128, 255, 0);
		uint8_t v[4] = { 16, 16, 235, 235 };
		plane[0].base = v;
		lsf_convert(lsf_find(FOURCC("420v"), 2, plane), LSF_MATRIX_601, false, plane, 2, 2, 2, out, 8, false);
		check("420v black", out, 0, 0, 0, 255, 0);
		check("420v white", out + 8, 255, 255, 255, 255, 0);
	}
	{	/* RGhA: 1.0 red, 0.5 green, -1 blue clipped, alpha 1 */
		uint16_t h[16 * 2] = { 0x3C00, 0x3800, 0xBC00, 0x3C00 };
		one("RGhA", h, 16, 8, NULL, 0, 0, 0, out);
		check("RGhA", out, 255, 128, 0, 255, 1);
	}
	{	/* w40a: B G R A 16-bit fields, code in the top 10 bits */
		uint16_t h[16] = { 894 << 6, 384 << 6, 639 << 6, 894 << 6 };
		one("w40a", h, 16, 8, NULL, 0, 0, 0, out);
		check("w40a", out, 128, 0, 255, 255, 1);
	}
	{	/* l10r, R10k */
		uint32_t w[8] = { 3u << 30 | 1023u << 20, 0, 0, 0, 3u << 30 | 1023u };
		one("l10r", w, 8, 4, NULL, 0, 0, 0, out);
		check("l10r red", out, 255, 0, 0, 255, 0);
		one("R10k", w + 4, 8, 4, NULL, 0, 0, 0, out);
		check("R10k red", out, 255, 0, 0, 255, 0);
	}
	{	/* A8 keeps its value in alpha, L8 in colour, LA8 both, b3a8 alpha from plane 1 */
		uint8_t a[4] = { 200, 200, 200, 200 };
		one("A008", a, 2, 1, NULL, 0, 0, 0, out);
		check("A008", out, 0, 0, 0, 200, 0);
		one("L008", a, 2, 1, NULL, 0, 0, 0, out);
		check("L008", out, 200, 200, 200, 255, 0);
		uint32_t w[4] = { 894u << 20 | 894u << 10 | 894u };
		one("b3a8", w, 8, 4, a, 2, 1, 2, out);
		check("b3a8", out, 255, 255, 255, 200, 0);
	}
	{	/* an unknown OSType is never refused: the layout picks */
		uint8_t g[8] = { 128, 128, 0, 0, 128, 128, 0, 0 }, c[16] = { 128, 128, 128, 128, 0, 0, 0, 0, 128, 128, 128, 128 };
		struct lsf_plane plane[2] = { { g, 4, 2, 2, 1 }, { c, 8, 2, 2, 2 } };
		const struct lsf_format *f = lsf_find(FOURCC("?RB?"), 2, plane);
		if (!f->guess || f->kind != LSF_YUV_2P8) {
			printf("FAIL guess of two planes: kind %d guess %d\n", f->kind, f->guess);
			failed++;
		} else {
			printf("ok   guess: %s\n", f->what);
		}
	}
	{	/* laurel 0005: '_RB4' contents: the planes' means, red green blue */
		static uint8_t green[64 * 64], bluered[64 * 64 * 2];
		struct lsf_plane plane[2] = { { green, 64, 64, 64, 1 }, { bluered, 128, 64, 64, 2 } };
		struct lsf_contents c;

		memset(green, 100, sizeof(green));
		for (size_t i = 0; i < sizeof(bluered); i += 2) {
			bluered[i] = 50;
			bluered[i + 1] = 200;
		}
		lsf_contents_of_rb4(plane, 64, 64, &c);
		printf("%s contents rb4: %u samples, %u lit, mean %u %u %u\n", c.lit == c.samples && c.mean[0] == 200 && c.mean[1] == 100 && c.mean[2] == 50 ? "ok  " : "FAIL",
		    c.samples, c.lit, c.mean[0], c.mean[1], c.mean[2]);
		failed += !(c.lit == c.samples && c.mean[0] == 200 && c.mean[1] == 100 && c.mean[2] == 50);
	}
	{	/* contents: an empty picture says 0 lit; a picture with one lit cell says so */
		enum { W = 128, H = 128 };
		static uint8_t pixels[W * H * 4];
		struct lsf_contents c;
		lsf_contents_of_pixels(lsf_find(FOURCC("_RB4"), 0, (struct lsf_plane[1]){ { pixels, W * 4, W, H, 4 } }), pixels, W * 4, W, H, &c);
		printf("%s contents empty: %u samples, %u lit\n", c.lit == 0 && c.samples == 64 * 64 ? "ok  " : "FAIL", c.samples, c.lit);
		failed += !(c.lit == 0 && c.samples == 64 * 64);
		pixels[(3 + 1 * W) * 4] = 9;
		lsf_contents_of_pixels(NULL, pixels, W * 4, W, H, &c);
		printf("%s contents one lit: %u lit %u unlike\n", c.lit == 1 && c.unlike == 1 ? "ok  " : "FAIL", c.lit, c.unlike);
		failed += !(c.lit == 1 && c.unlike == 1);
	}
	{	/* laurel 0006: the list behind LAUREL BLANK */
		static struct lsf_blanks b;
		struct lsf_blank out;
		struct lsf_blank *n = lsf_blank_note(&b, 7, FOURCC("BGRA"), 720, 1560, 100);
		int bad = n == NULL || lsf_blank_note(&b, 7, FOURCC("BGRA"), 720, 1560, 150) != NULL || b.count != 1 || b.seen != 2;

		bad |= lsf_blank_take(&b, 1000, 2000, &out);    /* too young */
		bad |= !lsf_blank_filled(&b, 7, 400) || b.count != 0 || b.filled != 1 || b.filled_ms != 300 || lsf_blank_filled(&b, 7, 500);
		(void)lsf_blank_note(&b, 8, 0, 1, 1, 0);
		bad |= !lsf_blank_take(&b, 5000, 2000, &out) || out.surface != 8 || b.count != 0;
		for (uint32_t i = 0; i < LSF_BLANKS + 3; i++) {
			(void)lsf_blank_note(&b, 100 + i, 0, 1, 1, i);
		}
		bad |= b.count != LSF_BLANKS || b.lost != 3;
		printf("%s LAUREL BLANK list\n", bad ? "FAIL" : "ok  ");
		failed += bad;
	}
	printf(failed ? "%d FAILED\n" : "all good\n", failed);
	return failed != 0;
}
