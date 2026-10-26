/*
 * Host test for patch 0267 (NegroniFramebuffer.cpp present()): the clock shift done inside the
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

/* the rectangles present() builds (same code shape) */
static uint32_t
rects(struct rect *r, uint32_t sx, uint32_t sy, uint32_t w, uint32_t h, uint32_t R, uint32_t half, uint32_t n)
{
	uint32_t nr = 0;
	if (h > R) {
		r[nr++] = (struct rect){ sx, sy + R, 0, R, w, h - R };
	}
	r[nr++] = (struct rect){ sx, sy, n, 0, half - n, R };
	r[nr++] = (struct rect){ sx + half - n, sy, 0, 0, n, R };
	if (w > half) {
		r[nr++] = (struct rect){ sx + half, sy, half, 0, w - half, R };
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
	const uint32_t half = PW / 2, R = 120, ns[] = { 1, 100, 200, 539 };
	uint32_t *src = malloc((size_t)SW * SH * 4), *ref = malloc((size_t)PW * PH * 4);
	uint32_t *gpu = malloc((size_t)PW * PH * 4), *cpu = malloc((size_t)PW * PH * 4);
	int fails = 0;

	for (uint32_t i = 0; i < SW * SH; i++) {
		src[i] = i * 2654435761u;
	}
	for (unsigned k = 0; k < sizeof(ns) / sizeof(ns[0]); k++) {
		uint32_t n = ns[k];
		/* reference: plain copy, then the strip's left half rotated right by n */
		for (uint32_t y = 0; y < PH; y++) {
			memcpy(ref + (uint64_t)y * PW, src + (uint64_t)(sy + y) * SW + sx, PW * 4);
		}
		for (uint32_t y = 0; y < R; y++) {
			uint32_t *row = ref + (uint64_t)y * PW, tmp[1080];
			memcpy(tmp, row, half * 4);
			for (uint32_t x = 0; x < half; x++) {
				row[(x + n) % half] = tmp[x];
			}
		}
		/* GPU rectangles */
		struct rect r[4];
		memset(gpu, 0xee, (size_t)PW * PH * 4);
		uint32_t nr = rects(r, sx, sy, PW, PH, R, half, n);
		for (uint32_t i = 0; i < nr; i++) {
			blit(gpu, PW, src, SW, &r[i]);
		}
		/* CPU rows (present(): d + n <- r, d <- r + half - n, d + half <- r + half) */
		memset(cpu, 0xee, (size_t)PW * PH * 4);
		for (uint32_t y = 0; y < PH; y++) {
			uint32_t *d = cpu + (uint64_t)y * PW;
			const uint32_t *s = src + (uint64_t)(sy + y) * SW + sx;
			if (y < R) {
				memcpy(d + n, s, (half - n) * 4);
				memcpy(d, s + half - n, n * 4);
				memcpy(d + half, s + half, (PW - half) * 4);
			} else {
				memcpy(d, s, PW * 4);
			}
		}
		int g = memcmp(gpu, ref, (size_t)PW * PH * 4) != 0, c = memcmp(cpu, ref, (size_t)PW * PH * 4) != 0;
		printf("n %3u: %u rectangles, GPU layout %s, CPU rows %s\n", n, nr, g ? "FAIL" : "ok", c ? "FAIL" : "ok");
		fails += g + c;
	}
	printf("%s\n", fails ? "FAIL" : "PASS");
	return fails != 0;
}
