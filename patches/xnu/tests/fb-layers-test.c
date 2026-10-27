/*
 * Host test for patch 0398 (NegroniFramebuffer.cpp layersMerge(), compose(), negroni_over()): the IOMFB layer
 * state across swaps and the composition of several layers, with the swap sequence QuartzCore 20H392 sends while
 * it detaches Maps' map layer (IOMFBDisplay::finish_update / detach_layer / delete_detached_layer):
 *   1. normal: framebuffer on layer 0, layers 1 and 2 set to NULL (mask 0x7, off 0x6)
 *   2. detach: map drawable on layer 0, framebuffer (clear hole over the map) on layer 1, layer 2 NULL
 *   3. only the UI changed: layer 1 alone (mask 0x2)        <- before 0398 the panel showed the hole (black)
 *   4. only the map changed: layer 0 alone (mask 0x1)       <- before 0398 the panel showed the map without the UI
 *   5. detach ends: framebuffer on layer 0, layers 1 and 2 NULL
 * Same code shape as the kernel (record offsets +0x54 ids, +0x104 changed layers, +0x108 of them turned off), and
 * the row classes of compose() (clear / opaque runs of the upper layer go to the GPU, mixed rows to the CPU).
 *
 *   cc -O2 -Wall -o /tmp/fblayers patches/xnu/tests/fb-layers-test.c && /tmp/fblayers
 */
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define LAYERS 4
static uint32_t lyr[LAYERS];        /* fLyrId */
static int fails;

/* layersMerge(): the ids part */
static uint32_t
merge(uint32_t mask, uint32_t off, const uint32_t *ids, uint32_t *out)
{
	uint32_t all = 0;
	mask &= (1u << LAYERS) - 1;
	for (uint32_t l = 0; l < LAYERS; l++) {
		if (mask & (1u << l)) {
			lyr[l] = (off & (1u << l)) ? 0 : ids[l];
		}
		out[l] = lyr[l];
		all |= lyr[l] != 0 ? 1u << l : 0;
	}
	return all;
}

/* the kernel's negroni_over() */
static inline uint32_t
over(uint32_t s, uint32_t d)
{
	uint32_t a = s >> 24, ia, o = 0;
	if (a == 255) {
		return s;
	}
	if (s == 0) {
		return d;
	}
	ia = 255 - a;
	for (uint32_t c = 0; c < 32; c += 8) {
		uint32_t v = ((s >> c) & 0xff) + (((d >> c) & 0xff) * ia + 127) / 255;
		o |= (v > 255 ? 255 : v) << c;
	}
	return o;
}

/* the kernel's negroni_compose_row_kind(): 1 = upper layer all clear (GPU copy of the lower), 2 = all opaque, 0 = CPU */
static uint8_t
row_kind(const uint32_t *p, uint32_t n)
{
	uint64_t ors = 0, ands = ~0ull, v[4];
	uint32_t x = 0;

	for (; x + 8 <= n; x += 8) {
		memcpy(v, p + x, sizeof(v));
		ors |= v[0] | v[1] | v[2] | v[3];
		ands &= v[0] & v[1] & v[2] & v[3];
		if (ors != 0 && (ands & 0xff000000ff000000ull) != 0xff000000ff000000ull) {
			return 0;
		}
	}
	for (; x < n; x++) {
		ors |= p[x];
		ands &= p[x] | 0xffffffff00000000ull;
	}
	if (ors == 0) {
		return 1;
	}
	return (ands & 0xff000000ff000000ull) == 0xff000000ff000000ull ? 2 : 0;
}

static void
expect(const char *what, uint32_t got, uint32_t want)
{
	if (got != want) {
		printf("FAIL %s: 0x%08x, want 0x%08x\n", what, got, want);
		fails++;
	}
}

int
main(void)
{
	enum { FB = 5, FB2 = 6, MAP = 900, MAP2 = 901 };
	uint32_t out[LAYERS], all;

	all = merge(0x7, 0x6, (uint32_t[]){ FB, 0, 0, 0 }, out);
	expect("1 layers", all, 0x1);
	expect("1 layer 0", out[0], FB);
	all = merge(0x7, 0x4, (uint32_t[]){ MAP, FB2, 0, 0 }, out);
	expect("2 layers", all, 0x3);
	all = merge(0x2, 0x0, (uint32_t[]){ 0, FB, 0, 0 }, out);
	expect("3 layers (map kept)", all, 0x3);
	expect("3 layer 0", out[0], MAP);
	expect("3 layer 1", out[1], FB);
	all = merge(0x1, 0x0, (uint32_t[]){ MAP2, 0, 0, 0 }, out);
	expect("4 layers (UI kept)", all, 0x3);
	expect("4 layer 0", out[0], MAP2);
	expect("4 layer 1", out[1], FB);
	all = merge(0x7, 0x6, (uint32_t[]){ FB2, 0, 0, 0 }, out);
	expect("5 layers", all, 0x1);
	expect("5 layer 0", out[0], FB2);

	/* composition: map (opaque) under the framebuffer (premultiplied BGRA) */
	const uint32_t map = 0xff3080c0;
	expect("clear hole shows the map", over(0x00000000, map), map);
	expect("opaque chrome covers it", over(0xfff0f0f0, map), 0xfff0f0f0);
	/* 50 % white (premultiplied 0x80) over the map: 0x80 + c * 127 / 255 */
	uint32_t half = over(0x80808080, map);
	expect("50% white over the map", half,
	    ((0x80u + (0xffu * 127 + 127) / 255) << 24) | ((0x80u + (0x30u * 127 + 127) / 255) << 16) |
	    ((0x80u + (0x80u * 127 + 127) / 255) << 8) | (0x80u + (0xc0u * 127 + 127) / 255));
	/* a non-premultiplied pixel must not carry into the next channel */
	expect("saturates per channel", over(0x10ffffff, 0xffffffff), 0xffffffff);
	expect("over black = the pixel", over(0x80402010, 0), 0x80402010);

	/* row kinds (1080 wide, and an odd tail): clear hole, opaque chrome, mixed (a dot / a shadow) */
	static uint32_t row[1083];
	for (uint32_t w = 1080; w <= 1083; w += 3) {
		memset(row, 0, sizeof(row));
		expect("row all clear", row_kind(row, w), 1);
		for (uint32_t x = 0; x < w; x++) {
			row[x] = 0xff000000u | x;
		}
		expect("row all opaque", row_kind(row, w), 2);
		row[w - 1] = 0x80404040;
		expect("row opaque, last pixel 50%", row_kind(row, w), 0);
		memset(row, 0, sizeof(row));
		row[w - 1] = 0xff102030;
		expect("row clear, last pixel opaque", row_kind(row, w), 0);
		row[w - 1] = 0;
		row[3] = 0x00000001;    /* a non-zero pixel with alpha 0 (additive): not clear */
		expect("row clear but one additive pixel", row_kind(row, w), 0);
	}

	if (fails == 0) {
		printf("fb-layers-test: PASS\n");
	}
	return fails != 0;
}
