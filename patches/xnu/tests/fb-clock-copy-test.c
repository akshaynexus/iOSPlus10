/*
 * Host test for patches 0267 and 0391 (NegroniFramebuffer.cpp present()): the clock shift done inside the
 * copy must give the same picture as "copy, then rotate the strip's left half by n" (the 0267
 * fill: the n pixels pushed out at the middle go to the left edge), for the GPU's four
 * rectangles and for the CPU's three memcpys per strip row. Rows below the strip and the right
 * half must be a plain copy.
 *
 *   cc -O2 -Wall -o /tmp/fbcc patches/xnu/tests/fb-clock-copy-test.c && /tmp/fbcc
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct rect { uint32_t sx, sy, dx, dy, w, h; };

/* the rectangles present() builds (same code shape; 0391: the band rows T..R, T = 0 is the 0267 strip) */
#define BOX_A 50
#define BOX_B 228
static int
boxok(uint32_t box, uint32_t w, uint32_t n)
{
	return box && n <= BOX_B - BOX_A && BOX_B + n <= w / 2;
}

static uint32_t
rects(struct rect *r, uint32_t sx, uint32_t sy, uint32_t w, uint32_t h, uint32_t T, uint32_t R, uint32_t half, uint32_t n,
    uint32_t box)
{
	uint32_t nr = 0, B = R - T;
	if (T > 0) {
		r[nr++] = (struct rect){ sx, sy, 0, 0, w, T };
	}
	if (h > R) {
		r[nr++] = (struct rect){ sx, sy + R, 0, R, w, h - R };
	}
	if (boxok(box, w, n)) {
		r[nr++] = (struct rect){ sx, sy + T, 0, T, BOX_A, B };
		r[nr++] = (struct rect){ sx + BOX_A, sy + T, BOX_A + n, T, BOX_B - BOX_A, B };
		r[nr++] = (struct rect){ sx + BOX_B, sy + T, BOX_A, T, n, B };
		r[nr++] = (struct rect){ sx + BOX_B + n, sy + T, BOX_B + n, T, w - BOX_B - n, B };
		return nr;
	}
	r[nr++] = (struct rect){ sx, sy + T, n, T, half - n, B };
	r[nr++] = (struct rect){ sx + half - n, sy + T, 0, T, n, B };
	if (w > half) {
		r[nr++] = (struct rect){ sx + half, sy + T, half, T, w - half, B };
	}
	return nr;
}

static void
blit(uint32_t *dst, uint32_t dp, const uint32_t *src, uint32_t sp, const struct rect *r)
{
	for (uint32_t y = 0; y < r->h; y++) {
		memcpy(dst + (uint64_t)(r->dy + y) * dp + r->dx, src + (uint64_t)(r->sy + y) * sp + r->sx, r->w * 4);
	}
}

int
main(void)
{
	const uint32_t SW = 1125, SH = 2436, PW = 1080, PH = 2412, sx = 22, sy = 12;
	const uint32_t half = PW / 2, ns[] = { 1, 100, 200, 539 };
	const uint32_t bands[3][3] = { { 0, 120, 0 }, { 34, 80, 0 }, { 34, 80, 1 } };   /* 0267 strip, band, 0391 band + box */
	uint32_t *src = malloc((size_t)SW * SH * 4), *ref = malloc((size_t)PW * PH * 4);
	uint32_t *gpu = malloc((size_t)PW * PH * 4), *cpu = malloc((size_t)PW * PH * 4);
	int fails = 0;

	for (uint32_t i = 0; i < SW * SH; i++) {
		src[i] = i * 2654435761u;
	}
	for (unsigned q = 0; q < 12; q++) {
		uint32_t n = ns[q % 4], T = bands[q / 4][0], R = bands[q / 4][1], box = bands[q / 4][2];
		/* reference: plain copy, then the strip's left half rotated right by n */
		for (uint32_t y = 0; y < PH; y++) {
			memcpy(ref + (uint64_t)y * PW, src + (uint64_t)(sy + y) * SW + sx, PW * 4);
		}
		for (uint32_t y = T; y < R; y++) {
			uint32_t *row = ref + (uint64_t)y * PW, tmp[1080];
			memcpy(tmp, row, PW * 4);
			if (boxok(box, PW, n)) {
				/* reference for the box: [A, B) to [A + n, B + n), [B, B + n) to [A, A + n) */
				for (uint32_t x = BOX_A; x < BOX_B; x++) {
					row[x + n] = tmp[x];
				}
				for (uint32_t x = 0; x < n; x++) {
					row[BOX_A + x] = tmp[BOX_B + x];
				}
				continue;
			}
			for (uint32_t x = 0; x < half; x++) {
				row[(x + n) % half] = tmp[x];
			}
		}
		/* GPU rectangles */
		struct rect r[6];
		memset(gpu, 0xee, (size_t)PW * PH * 4);
		uint32_t nr = rects(r, sx, sy, PW, PH, T, R, half, n, box);
		for (uint32_t i = 0; i < nr; i++) {
			blit(gpu, PW, src, SW, &r[i]);
		}
		/* CPU rows (present(): d + n <- r, d <- r + half - n, d + half <- r + half) */
		memset(cpu, 0xee, (size_t)PW * PH * 4);
		for (uint32_t y = 0; y < PH; y++) {
			uint32_t *d = cpu + (uint64_t)y * PW;
			const uint32_t *s = src + (uint64_t)(sy + y) * SW + sx;
			if (y >= T && y < R && boxok(box, PW, n)) {
				memcpy(d, s, PW * 4);
				memcpy(d + BOX_A + n, s + BOX_A, (BOX_B - BOX_A) * 4);
				memcpy(d + BOX_A, s + BOX_B, n * 4);
			} else if (y >= T && y < R) {
				memcpy(d + n, s, (half - n) * 4);
				memcpy(d, s + half - n, n * 4);
				memcpy(d + half, s + half, (PW - half) * 4);
			} else {
				memcpy(d, s, PW * 4);
			}
		}
		int g = memcmp(gpu, ref, (size_t)PW * PH * 4) != 0, c = memcmp(cpu, ref, (size_t)PW * PH * 4) != 0;
		printf("rows %3u..%3u box %u n %3u: %u rectangles, GPU layout %s, CPU rows %s\n", T, R, boxok(box, PW, n), n, nr, g ? "FAIL" : "ok", c ? "FAIL" : "ok");
		fails += g + c;
	}
	printf("%s\n", fails ? "FAIL" : "PASS");
	return fails != 0;
}
