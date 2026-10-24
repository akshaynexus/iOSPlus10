/*
 * Host test for the A730 2D copy stream of patch 0231 (bsd/dev/negroni_gpu_blit.c).
 *
 *   cc -std=c11 -Wall -Wextra -I <worktree>/bsd/dev \
 *      patches/xnu/tests/gpu-blit-ib-test.c <worktree>/bsd/dev/negroni_gpu_blit.c -o /tmp/blit-test
 *
 * It decodes the PM4 packets (type 4 register writes with their parity bits, type 7 with
 * theirs), keeps a register file, and at each CP_BLIT applies the 2D engine's addressing
 * (destination: base + y * pitch + x * 4 inside DST_TL..DST_BR; source: base + v * pitch +
 * u * 4, u/v from SRC_TL + the offset into the destination rectangle) to a model of the
 * memory. Then every destination pixel must hold the source pixel it should, nothing
 * outside the rectangle may change, and the alignment rules of a6xx.xml must hold.
 */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "negroni_gpu_blit.h"

static uint32_t regs[0x10000];
static int failures;

#define CHECK(c, ...) do { if (!(c)) { failures++; printf("FAIL: " __VA_ARGS__); printf("\n"); } } while (0)

static uint32_t
odd_parity(uint32_t v)
{
	return (0x9669 >> (0xf & (v ^ v >> 4 ^ v >> 8 ^ v >> 12 ^ v >> 16 ^ v >> 20 ^ v >> 24 ^ v >> 28))) & 1;
}

/* memory model: one byte array for the source and one for the panel */
#define SRC_VA  0x100000000ull
#define DST_VA  0x200000000ull
static uint8_t *src_mem, *dst_mem;
static size_t src_len, dst_len;

static void
blit(void)
{
	uint32_t info = regs[0xb2c0], size = regs[0xb2c1], spitch = regs[0xb2c4] >> 3;
	uint64_t sbase = regs[0xb2c2] | (uint64_t)regs[0xb2c3] << 32;
	uint32_t dinfo = regs[0x8c17], dpitch = (regs[0x8c1a] & 0xffff) << 6;
	uint64_t dbase = regs[0x8c18] | (uint64_t)regs[0x8c19] << 32;
	uint32_t tl = regs[0x8405], br = regs[0x8406];
	uint32_t x0 = tl & 0x3fff, y0 = tl >> 16 & 0x3fff, x1 = br & 0x3fff, y1 = br >> 16 & 0x3fff;
	uint32_t u0 = regs[0x8401] >> 8, v0 = regs[0x8403] >> 8, u1 = regs[0x8402] >> 8, v1 = regs[0x8404] >> 8;
	uint32_t width = size & 0x7fff, height = size >> 15 & 0x7fff;

	CHECK((info & 0xff) == 0x30 && (dinfo & 0xff) == 0x30, "formats %#x %#x", info, dinfo);
	CHECK(((info >> 10) & 3) == ((dinfo >> 10) & 3), "source and destination swap differ");
	CHECK((info & (1u << 16)) == 0, "filter on in a 1:1 copy");
	CHECK((dbase & 63) == 0, "RB_2D_DST %#llx not 64-byte aligned", (unsigned long long)dbase);
	CHECK((sbase & 15) == 0, "SP_PS_2D_SRC %#llx not 16-byte aligned", (unsigned long long)sbase);
	CHECK((spitch & 127) == 0, "source pitch %u: bits 3..9 of SP_PS_2D_SRC_PITCH not zero", spitch);
	CHECK(x1 - x0 == u1 - u0 && y1 - y0 == v1 - v0, "1:1 rectangles differ");
	CHECK(u1 < width && v1 < height, "source rectangle outside the texture %ux%u", width, height);
	CHECK((x1 + 1) * 4 <= dpitch, "destination row overruns its pitch");
	CHECK(regs[0x8c00] == regs[0x8400], "RB and GRAS 2D_BLIT_CNTL differ");
	CHECK(regs[0x8c00] == (0x30u << 8 | 0xfu << 20 | 0x10u << 24), "BLIT_CNTL %#x", regs[0x8c00]);
	CHECK(regs[0xa9bf] == (0x30u << 3 | 0xfu << 12), "SP_2D_DST_FORMAT (A7XX 0xa9bf) %#x", regs[0xa9bf]);
	CHECK(regs[0xb2d2] == 1u << 29, "TPL1_2D_SRC_CNTL %#x", regs[0xb2d2]);
	for (uint32_t y = y0; y <= y1; y++) {
		for (uint32_t x = x0; x <= x1; x++) {
			uint64_t d = dbase + (uint64_t)y * dpitch + x * 4ull - DST_VA;
			uint64_t s = sbase + (uint64_t)(v0 + y - y0) * spitch + (u0 + x - x0) * 4ull - SRC_VA;
			if (d + 4 > dst_len || s + 4 > src_len) {
				CHECK(0, "access outside memory: dst %#llx src %#llx", (unsigned long long)d, (unsigned long long)s);
				return;
			}
			memcpy(dst_mem + d, src_mem + s, 4);
		}
	}
}

static uint32_t
run(const uint32_t *ib, uint32_t n)
{
	uint32_t blits = 0;
	memset(regs, 0, sizeof(regs));
	for (uint32_t i = 0; i < n;) {
		uint32_t h = ib[i++];
		if (h >> 28 == 4) {
			uint32_t cnt = h & 0x7f, reg = h >> 8 & 0x3ffff;
			CHECK(((h >> 7) & 1) == odd_parity(cnt) && ((h >> 27) & 1) == odd_parity(reg), "pkt4 parity at %u", i - 1);
			for (uint32_t k = 0; k < cnt; k++) {
				regs[(reg + k) & 0xffff] = ib[i++];
			}
		} else if (h >> 28 == 7) {
			uint32_t cnt = h & 0x3fff, op = h >> 16 & 0x7f;
			CHECK(((h >> 15) & 1) == odd_parity(cnt) && ((h >> 23) & 1) == odd_parity(op), "pkt7 parity at %u", i - 1);
			if (op == 0x2c) {
				CHECK(cnt == 1 && ib[i] == 3, "CP_BLIT not BLIT_OP_SCALE");
				blit();
				blits++;
			}
			i += cnt;
		} else {
			CHECK(0, "unknown packet %#x at %u", h, i - 1);
			return blits;
		}
	}
	return blits;
}

static void
one(uint32_t sw, uint32_t sh, uint32_t spitch, uint32_t dw, uint32_t dh, uint32_t dpitch,
    uint32_t sx, uint32_t sy, uint32_t dx, uint32_t dy, uint32_t w, uint32_t h)
{
	static uint32_t ib[NEGRONI_GPU_COPY_WORDS];
	struct negroni_gpu_copy c = { SRC_VA, spitch, DST_VA, dpitch, sx, sy, dx, dy, w, h };
	(void)sw;
	(void)dw;
	src_len = (size_t)spitch * sh + 8192;
	dst_len = (size_t)dpitch * dh + 8192;
	src_mem = malloc(src_len);
	dst_mem = malloc(dst_len);
	for (size_t i = 0; i < src_len; i++) {
		src_mem[i] = (uint8_t)(i * 2654435761u >> 13);
	}
	memset(dst_mem, 0xee, dst_len);
	uint32_t n = negroni_gpu_copy_ib(&c, ib, NEGRONI_GPU_COPY_WORDS);
	CHECK(n != 0, "no stream for %ux%u", w, h);
	uint32_t blits = run(ib, n);
	CHECK(blits == (h > 1 ? 2u : 1u), "%u blits", blits);
	for (uint32_t y = 0; y < dh; y++) {
		for (uint32_t x = 0; x < dpitch / 4; x++) {
			const uint8_t *p = dst_mem + (size_t)y * dpitch + x * 4;
			bool in = x >= dx && x < dx + w && y >= dy && y < dy + h;
			uint8_t want[4];
			if (in) {
				memcpy(want, src_mem + (size_t)(sy + y - dy) * spitch + (sx + x - dx) * 4, 4);
			} else {
				memset(want, 0xee, 4);
			}
			if (memcmp(p, want, 4) != 0) {
				CHECK(0, "pixel %u,%u %s", x, y, in ? "wrong" : "written outside the rectangle");
				goto done;
			}
		}
	}
done:
	printf("copy %ux%u from %u,%u (pitch %u) to %u,%u (pitch %u): %u words, %u blits\n", w, h, sx, sy, spitch,
	    dx, dy, dpitch, n, blits);
	free(src_mem);
	free(dst_mem);
}

int
main(void)
{
	/* backboardd's 1125x2436 frame (rows 4544) onto the 1080x2412 panel (rows 4320): centred crop */
	one(1125, 2436, 4544, 1080, 2412, 4320, 22, 12, 0, 0, 1080, 2412);
	/* the native size, a partial rectangle, an odd height, an odd start row */
	one(1080, 2412, 4352, 1080, 2412, 4320, 0, 0, 0, 0, 1080, 2412);
	one(400, 300, 1600, 1080, 2412, 4320, 3, 5, 101, 777, 333, 201);
	one(64, 2, 256, 1080, 2412, 4320, 0, 0, 0, 1, 64, 1);
	/* refused: unaligned source pitch, unaligned base, destination pitch not a multiple of 32 */
	uint32_t ib[NEGRONI_GPU_COPY_WORDS];
	struct negroni_gpu_copy bad1 = { SRC_VA, 4500, DST_VA, 4320, 0, 0, 0, 0, 1080, 2412 };
	struct negroni_gpu_copy bad2 = { SRC_VA + 16, 4544, DST_VA, 4320, 0, 0, 0, 0, 1080, 2412 };
	struct negroni_gpu_copy bad3 = { SRC_VA, 4544, DST_VA, 4324, 0, 0, 0, 0, 1080, 2412 };
	struct negroni_gpu_copy bad4 = { SRC_VA, 4544, DST_VA, 4320, 0, 0, 10, 0, 1080, 2412 };
	CHECK(negroni_gpu_copy_ib(&bad1, ib, NEGRONI_GPU_COPY_WORDS) == 0, "pitch 4500 taken");
	CHECK(negroni_gpu_copy_ib(&bad2, ib, NEGRONI_GPU_COPY_WORDS) == 0, "unaligned source taken");
	CHECK(negroni_gpu_copy_ib(&bad3, ib, NEGRONI_GPU_COPY_WORDS) == 0, "pitch 4324 taken");
	CHECK(negroni_gpu_copy_ib(&bad4, ib, NEGRONI_GPU_COPY_WORDS) == 0, "rectangle past the row taken");
	CHECK(negroni_gpu_copy_ib(&bad1, ib, 10) == 0, "short buffer taken");
	printf("%s (%d failures)\n", failures ? "FAILED" : "all good", failures);
	return failures != 0;
}
