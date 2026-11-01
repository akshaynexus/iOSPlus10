/* The memory guard's rule (userland/camera/camera_mem_guard.h): lines by step, one limit, lift by a new session only under 3/4 of the limit. */
#include <assert.h>
#include <stdio.h>
#include "camera_mem_guard.h"

int
main(void)
{
	struct memguard g;

	memguard_init(&g, MEMGUARD_LIMIT_MB);
	assert(memguard_sample(&g, 100) == MEMGUARD_NONE);
	assert(memguard_sample(&g, 256) == MEMGUARD_LINE);
	assert(memguard_sample(&g, 300) == MEMGUARD_NONE);                      /* no line twice in one step */
	assert(memguard_sample(&g, 700) == MEMGUARD_LINE);                      /* a jump over steps: one line */
	assert(memguard_sample(&g, 767) == MEMGUARD_NONE);
	assert(memguard_session(&g, 767) == MEMGUARD_NONE);                     /* not over: nothing to lift */
	assert(memguard_sample(&g, 768) == MEMGUARD_LIMIT && g.over);
	assert(memguard_sample(&g, 770) == MEMGUARD_NONE);                      /* the limit once */
	assert(memguard_sample(&g, 1024) == MEMGUARD_LINE);                     /* still growing: named */
	assert(memguard_sample(&g, 2600) == MEMGUARD_LINE);
	assert(memguard_session(&g, 600) == MEMGUARD_STILL_OVER && g.over);     /* over 3/4 of 768 = 576 */
	assert(memguard_session(&g, 575) == MEMGUARD_LIFTED && !g.over);
	assert(memguard_sample(&g, 575) == MEMGUARD_NONE);                      /* its step, not a line from 256 up */
	assert(memguard_sample(&g, 800) == MEMGUARD_LIMIT);                     /* a later session can stop again */
	printf("cam7: memory guard rule OK\n");
	return 0;
/*
 * Host test of the signal self-check (laurel 2784, laurel_cam_light.h) and the plug-in's isp_raw_measure.
 *  - raw statistics of a synthetic black frame: the numbers of boot 20:02 give "no signal"; a lit frame gives "signal"; a wrong shift and a wrong
 *    group alignment show in the numbers; kernel and plug-in say the same
 *  - colour bars: each Bayer order is found, a flat frame and noise are not bars, a frame with shifted lines is not bars
 *  - "1 % over" reads the real level on a black frame (it read 8)
 *  - with the stock libraries: register values after tables + window, pedestal 64 and white 1023 in .data, the test pattern table
 */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "laurel_cam_light.h"
#include "camera_isp.h"

static long failed, checks;
#define CHECK(c, ...) do { checks++; if (!(c)) { failed++; printf("FAILED line %d: ", __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

enum { W = 1920, H = 1440, STRIDE = W / 4 * 5 };
static uint8_t raw[(size_t)STRIDE * H];

static void
put(uint32_t x, uint32_t y, int v)
{
	uint8_t *g = raw + (size_t)y * STRIDE + (x / 4) * 5;

	v = v < 0 ? 0 : v > 1023 ? 1023 : v;
	g[x & 3] = (uint8_t)(v >> 2);
	g[4] = (uint8_t)((g[4] & ~(3u << (2 * (x & 3)))) | (unsigned)(v & 3) << (2 * (x & 3)));
}

static double
gauss(void)
{
	double u = (rand() + 1.0) / (RAND_MAX + 2.0), v = (rand() + 1.0) / (RAND_MAX + 2.0);

	return sqrt(-2 * log(u)) * cos(2 * M_PI * v);
}

static void
noise_frame(double level, double sigma)
{
	for (uint32_t y = 0; y < H; y++) {
		for (uint32_t x = 0; x < W; x++) {
			put(x, y, (int)lround(level + sigma * gauss()));
		}
	}
}

static void
stat_of(const uint8_t *buf, struct lcam_raw_stat *s)
{
	lcam_raw_stat_init(s);
	for (uint32_t y = 0; y < H; y += LCAM_RAW_YSTEP) {
		lcam_raw_stat_line(s, buf + (size_t)y * STRIDE, W, y);
	}
}

/* the colour bars of a Bayer order (LCAM_BAYER_*), levels low..high */
static void
bars_frame(int order, int low, int high)
{
	static const uint8_t place[4][4] = { { 2, 1, 1, 0 }, { 1, 2, 0, 1 }, { 1, 0, 2, 1 }, { 0, 1, 1, 2 } };        /* 0 R, 1 G, 2 B */
	static const uint8_t m[3] = { LCAM_BAR_R, LCAM_BAR_G, LCAM_BAR_B };

	for (uint32_t y = 0; y < H; y++) {
		for (uint32_t x = 0; x < W; x++) {
			unsigned c = x * 8 / W, p = (y & 1) << 1 | (x & 1);

			put(x, y, (m[place[order][p]] >> (7 - c)) & 1 ? high : low);
		}
	}
}

static void
bars_of(struct lcam_bars *b)
{
	memset(b, 0, sizeof(*b));
	for (uint32_t y = H / 4; y < H * 3 / 4; y += LCAM_RAW_YSTEP) {
		lcam_bars_line(b, raw + (size_t)y * STRIDE, W, y);
	}
	lcam_bars_end(b);
}

static void
test_stats(void)
{
	struct lcam_raw_stat s;
	struct negronicam_frame f;
	struct isp_raw r;
	uint32_t mean, bright, top;

	memset(&f, 0, sizeof(f));
	f.width = W;
	f.height = H;
	f.stride = STRIDE;
	noise_frame(64, 3);             /* 133 ms x 16x of boot 20:02 */
	stat_of(raw, &s);
	CHECK(s.n == 96u * W, "n %u", s.n);
	CHECK(s.max < 64 + LCAM_LIGHT_SIGNAL && s.min > 40, "min %u max %u", s.min, s.max);
	CHECK(lcam_raw_mean10(&s) > 630 && lcam_raw_mean10(&s) < 650, "mean10 %u", lcam_raw_mean10(&s));
	CHECK(s.hist[0] == s.n, "top bits %u of %u in the first bin", s.hist[0], s.n);
	CHECK(strncmp(lcam_raw_says(&s, 64), "no signal", 9) == 0, "%s", lcam_raw_says(&s, 64));
	for (unsigned i = 0; i < 4; i++) {
		CHECK(lcam_raw_byte(&s, i) >= 15 && lcam_raw_byte(&s, i) <= 16, "byte %u = %u", i, lcam_raw_byte(&s, i));
		CHECK(lcam_raw_place10(&s, i) > 630 && lcam_raw_place10(&s, i) < 650, "place %u", i);
	}
	isp_raw_measure(&f, raw, &r);
	CHECK(r.n == s.n && r.min == s.min && r.max == s.max && memcmp(r.hist, s.hist, sizeof(r.hist)) == 0, "the plug-in and the kernel differ on noise");
	for (unsigned i = 0; i < 5; i++) {
		CHECK(r.byte[i] == lcam_raw_byte(&s, i), "byte %u: plug-in %u kernel %u", i, r.byte[i], lcam_raw_byte(&s, i));
	}
	lcam_raw10_levels(raw, W, H, 8, 64, &mean, &bright, &top);
	CHECK(bright >= 5 && bright <= 9 && top >= 8 && top < 25, "1%% over %u top %u: black frame", bright, top);
	noise_frame(64, 0.3);
	lcam_raw10_levels(raw, W, H, 8, 64, &mean, &bright, &top);
	CHECK(bright <= 1 && mean == 0, "1%% over %u, mean %u: it read 8 on a black frame", bright, mean);

	noise_frame(600, 8);            /* a lit room */
	stat_of(raw, &s);
	CHECK(strncmp(lcam_raw_says(&s, 64), "signal", 6) == 0, "%s", lcam_raw_says(&s, 64));
	CHECK(s.hist[4] > s.n / 2 && lcam_raw_byte(&s, 0) >= 148 && lcam_raw_byte(&s, 0) <= 151, "lit: hist4 %u byte0 %u", s.hist[4], lcam_raw_byte(&s, 0));
	isp_raw_measure(&f, raw, &r);
	CHECK(r.min == s.min && r.max == s.max && fabs(r.mean * 10 - lcam_raw_mean10(&s)) < 1.1, "the plug-in and the kernel differ when lit");
	/* a group shifted by one byte: the low-bits byte moves to another place: the bytes' means show it */
	static uint8_t moved[(size_t)STRIDE * H];

	memcpy(moved, raw + 1, sizeof(moved) - 1);
	stat_of(moved, &s);
	CHECK(lcam_raw_byte(&s, 3) + 10 < lcam_raw_byte(&s, 0), "one byte off: byte 3 %u byte 0 %u", lcam_raw_byte(&s, 3), lcam_raw_byte(&s, 0));
	memset(raw, 0x10, sizeof(raw));
	for (uint32_t y = 0; y < H; y++) {
		for (uint32_t x = 0; x < W; x += 4) {
			raw[(size_t)y * STRIDE + x / 4 * 5 + 4] = 0;
		}
	}
	stat_of(raw, &s);
	CHECK(s.min == 64 && s.max == 64 && strncmp(lcam_raw_says(&s, 64), "one value", 9) == 0, "constant: %s", lcam_raw_says(&s, 64));
}

static void
test_bars(void)
{
	struct lcam_bars b;

	for (int o = 0; o < 4; o++) {
		bars_frame(o, 64, 1023);
		bars_of(&b);
		CHECK(b.bars && b.order == o, "order %d: bars %d found %d masks %#x %#x %#x %#x", o, b.bars, b.order, b.mask[0], b.mask[1], b.mask[2], b.mask[3]);
		CHECK(b.lo == 64 && b.hi == 1023, "levels %u..%u", b.lo, b.hi);
	}
	noise_frame(64, 3);
	bars_of(&b);
	CHECK(!b.bars && b.order < 0, "noise read as bars: %#x %#x, %u..%u", b.mask[0], b.mask[3], b.lo, b.hi);
	noise_frame(500, 3);
	bars_of(&b);
	CHECK(!b.bars, "a flat lit frame read as bars");
	/* lines 37 bytes off (a wrong stride shows like this): no order fits */
	static uint8_t tmp[(size_t)STRIDE * H];

	bars_frame(LCAM_BAYER_RGGB, 64, 1023);
	memcpy(tmp, raw, sizeof(tmp));
	for (uint32_t y = 0; y < H; y++) {
		memcpy(raw + (size_t)y * STRIDE, tmp + (size_t)y * STRIDE + (y * 37u) % (STRIDE / 2), STRIDE / 2);
	}
	bars_of(&b);
	CHECK(b.order != LCAM_BAYER_RGGB, "a wrong stride read as good bars");
}

static void
test_libraries(const char *dir)
{
	static const char *const names[] = { "libmmcamera_laurus_imx586_qtech.so", "libmmcamera_laurus_imx586_sunny.so", "libmmcamera_laurus_imx582_qtech.so" };
	unsigned seen = 0;

	for (unsigned i = 0; i < 3; i++) {
		char path[512];
		FILE *fp;
		static uint8_t file[1 << 21];
		size_t n;
		struct lcam_lib l;
		const char *why = "";
		const uint8_t *e;
		uint8_t v = 0;
		uint16_t a;

		snprintf(path, sizeof(path), "%s/%s", dir, names[i]);
		if ((fp = fopen(path, "rb")) == NULL) {
			continue;
		}
		n = fread(file, 1, sizeof(file), fp);
		fclose(fp);
		seen++;
		CHECK(lcam_lib_parse(file, n, &l, &why) == 0, "%s: %s", names[i], why);
		/* the color level info: white and the four pedestals: this is the black level of the ISP [V] */
		CHECK(lcam_le16(l.data + 0x6050) == 1023, "%s white %u", names[i], lcam_le16(l.data + 0x6050));
		for (unsigned p = 0; p < 4; p++) {
			CHECK(lcam_le16(l.data + 0x6052 + 2 * p) == LCAM_AE_BLACK, "%s pedestal %u = %u", names[i], p, lcam_le16(l.data + 0x6052 + 2 * p));
		}
		/* test_pattern_info: mode 2 = 0x0600 0, 0x0601 2 in the sunny library; the qtech ones hold a template's 0x5e00/0x4320 [V], no Sony register */
		if (i == 1) {
			CHECK(lcam_le16(l.data + 0x88b0) == 2 && lcam_le16(l.data + 0x88b4) == 0x600 && lcam_le16(l.data + 0x88bc) == LCAM_TEST_PATTERN &&
			    l.data[0x88be] == LCAM_TEST_BARS, "%s: test pattern table", names[i]);
		}
		int k = lcam_lib_find(&l, 1920, 1080);
		CHECK(k >= 0, "%s: no 1920x1080", names[i]);
		CHECK(lcam_light_want(&l, k, true, 0x034f, &v) && v == 0xa0, "%s: window height low byte %#x", names[i], v);
		CHECK(lcam_light_want(&l, k, false, 0x034f, &v) && v == 0x38, "%s: stock height low byte %#x", names[i], v);
		CHECK(lcam_light_want(&l, k, true, 0x0136, &v) && v == 0x18, "%s: INCK from the init table %#x", names[i], v);
		CHECK(!lcam_light_want(&l, k, true, 0xfffe, &v), "%s: a register in no table", names[i]);
		/* no test pattern and no standby trap in the tables: 0x0600/1 and 0x0100, 0x0104 are never written by init or mode tables */
		for (int t = -1; t < (int)l.nmodes; t++) {
			uint32_t cnt = lcam_lib_table(&l, t, &e);

			for (uint32_t j = 0; j < cnt; j++) {
				uint32_t d;

				lcam_lib_entry(e, j, &a, &v, &d);
				CHECK(a != 0x0600 && a != 0x0601 && a != 0x0100 && a != 0x0104, "%s table %d writes %#x", names[i], t, a);
			}
		}
	}
	if (seen == 0) {
		printf("cam7: no stock libraries in %s: their checks skipped\n", dir);
	}
}

int
main(int argc, char **argv)
{
	test_stats();
	test_bars();
	test_libraries(argc > 1 ? argv[1] : "out/laurel/camera/lib");
	printf("cam7: %ld checks, %ld failed\n", checks, failed);
	return failed != 0;
}
