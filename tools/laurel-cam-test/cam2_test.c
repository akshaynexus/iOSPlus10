/*
 * Host test of the Mi A3 camera RDI path, pure parts (kernel patch 2771: bsd/dev/laurel_cam_lib.h, laurel_cam_rdi.h).
 * Built and run by scripts/laurel/cam-test.sh (headers taken from the patch).
 *   cam2_test                 unit checks (synthetic library, CSID/CSIPHY words, RAW10, AE, read protocol)
 *   cam2_test --dump LIB.so   the tables as scripts/laurel/camera-tables.py prints them (the script diffs both)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "laurel_cam_lib.h"
#include "laurel_cam_rdi.h"

static int fails, checks;
#define CHECK(c, ...) do { checks++; if (!(c)) { fails++; printf("FAIL %s:%d: ", __FILE__, __LINE__); \
	printf(__VA_ARGS__); printf("\n"); } } while (0)

static void
put16(uint8_t *p, uint16_t v)
{
	p[0] = (uint8_t)v;
	p[1] = (uint8_t)(v >> 8);
}

/* a minimal ELF32 with a .data that has the sensor_lib_t layout: 2 modes, init 5 writes, mode 1 3 writes */
static uint8_t *
fake_lib(size_t *len)
{
	size_t dsz = LCAM_LIB_LUT + LCAM_LIB_LUT_STRIDE * LCAM_LIB_MAX_MODES + 64, doff = 0x100;
	size_t shoff = doff + dsz, n = shoff + 3 * 40 + 32;
	uint8_t *f = calloc(1, n), *d = f + doff, *sh = f + shoff;
	const char strtab[] = "\0.data\0.shstrtab";

	memcpy(f, "\x7f" "ELF\x01\x01\x01", 7);
	lcam_put_le32(f + 0x20, (uint32_t)shoff);
	put16(f + 0x2e, 40);
	put16(f + 0x30, 3);
	put16(f + 0x32, 2);
	/* section 1 .data, section 2 .shstrtab (after the headers) */
	lcam_put_le32(sh + 40 + 0, 1);
	lcam_put_le32(sh + 40 + 16, (uint32_t)doff);
	lcam_put_le32(sh + 40 + 20, (uint32_t)dsz);
	lcam_put_le32(sh + 80 + 0, 7);
	lcam_put_le32(sh + 80 + 16, (uint32_t)(shoff + 120));
	lcam_put_le32(sh + 80 + 20, sizeof(strtab));
	memcpy(f + shoff + 120, strtab, sizeof(strtab));
	memcpy(d, "test_sensor", 11);
	lcam_put_le32(d + 0x20, 0x34);
	put16(d + 0x30, 0x0016);
	put16(d + 0x32, 0x0586);
	lcam_put_le32(d + LCAM_LIB_OUTPUT + 12, LCAM_BAYER_RGGB);
	d[LCAM_LIB_CSI] = 4;
	d[LCAM_LIB_CSI + 1] = 0x13;
	lcam_put_le32(d + LCAM_LIB_OUT_INFO, 2);
	for (uint32_t k = 0; k < 2; k++) {
		uint8_t *r = d + LCAM_LIB_OUT_INFO + 8 + k * LCAM_LIB_OUT_REC, *l = d + LCAM_LIB_LUT + k * LCAM_LIB_LUT_STRIDE;
		put16(r, k ? 1280 : 4000);
		put16(r + 2, k ? 720 : 3000);
		put16(r + 4, 5376);
		put16(r + 6, 780 + 3000 * (1 - k));
		lcam_put_le32(r + 12, 392000000);
		lcam_put_le32(r + 0x58, 0xbebc2000u);
		lcam_put_le32(l, 1);
		l[5] = 0x2b;
		l[6] = 2;
	}
	for (uint32_t t = 0; t < 3; t++) {                      /* init, mode 0, mode 1: trailer 2/1 */
		uint32_t o = t == 0 ? LCAM_LIB_INIT : LCAM_LIB_RES + (t - 1) * LCAM_LIB_RES_STRIDE;
		lcam_put_le32(d + o + LCAM_LIB_REGS * 8 + 4, 2);
		lcam_put_le32(d + o + LCAM_LIB_REGS * 8 + 8, 1);
	}
	static const uint16_t init[5][3] = { { 0x0136, 0x18, 0 }, { 0x0137, 0x00, 0 }, { 0x0138, 0x01, 5 },
					     { 0x0139, 0x02, 0 }, { 0x3000, 0x7f, 0 } };
	for (uint32_t i = 0; i < 5; i++) {
		put16(d + LCAM_LIB_INIT + 8 * i, init[i][0]);
		put16(d + LCAM_LIB_INIT + 8 * i + 2, init[i][1]);
		lcam_put_le32(d + LCAM_LIB_INIT + 8 * i + 4, init[i][2]);
	}
	for (uint32_t i = 0; i < 3; i++) {
		uint32_t o = LCAM_LIB_RES + LCAM_LIB_RES_STRIDE + 8 * i;
		put16(d + o, (uint16_t)(0x0340 + i));
		put16(d + o + 2, (uint16_t)(0x10 + i));
	}
	*len = n;
	return f;
}

static void
unit(void)
{
	size_t len;
	uint8_t *f = fake_lib(&len), out[11];
	struct lcam_lib l;
	struct lcam_mode m;
	const char *why = "";
	const uint8_t *e;
	uint32_t n, i, bl, bd;

	CHECK(lcam_lib_parse(f, len, &l, &why) == 0, "fake lib: %s", why);
	CHECK(strcmp(l.name, "test_sensor") == 0 && l.slave8 == 0x34 && l.id == 0x0586 && l.nmodes == 2, "fields");
	CHECK(l.lanes == 4 && l.settle == 0x13 && l.filter == LCAM_BAYER_RGGB, "csi");
	CHECK(lcam_lib_find(&l, 1280, 720) == 1 && lcam_lib_find(&l, 640, 480) == -1, "find");
	CHECK(lcam_lib_mode(&l, 1, &m) == 0 && m.frame == 780 && m.op_pclk == 3200000000ull && m.dt == 0x2b, "mode");
	CHECK(lcam_lib_mode(&l, 2, &m) == 1, "mode past count");
	n = lcam_lib_table(&l, LCAM_LIB_INIT_MODE, &e);
	CHECK(n == 5, "init count %u", n);
	/* bursts: 0x0136..0x0138 (0x0138 has a delay: ends the run), 0x0139, 0x3000 */
	i = lcam_burst(e, n, 0, out, &bl, &bd);
	CHECK(i == 3 && bl == 5 && bd == 5 && out[0] == 0x01 && out[1] == 0x36 && out[2] == 0x18 && out[4] == 0x01,
	    "burst 1: next %u len %u delay %u", i, bl, bd);
	i = lcam_burst(e, n, i, out, &bl, &bd);
	CHECK(i == 4 && bl == 3 && out[1] == 0x39, "burst 2");
	i = lcam_burst(e, n, i, out, &bl, &bd);
	CHECK(i == 5 && bl == 3 && out[0] == 0x30, "burst 3");
	CHECK(lcam_lib_table(&l, 1, &e) == 3 && lcam_lib_table(&l, 2, &e) == 0, "mode tables");
	/* refusals */
	CHECK(lcam_lib_parse(f, 0x40, &l, &why) == 1, "truncated file");
	f[0x100 + LCAM_LIB_CSI] = 7;
	CHECK(lcam_lib_parse(f, len, &l, &why) == 1, "lanes 7");
	f[0x100 + LCAM_LIB_CSI] = 4;
	lcam_put_le32(f + 0x100 + LCAM_LIB_INIT + LCAM_LIB_REGS * 8 + 4, 1);
	CHECK(lcam_lib_parse(f, len, &l, &why) == 1 && strcmp(why, "no init table") == 0, "trailer");
	f[1] = 'X';
	CHECK(lcam_lib_parse(f, len, &l, &why) == 1, "not ELF");
	free(f);

	CHECK(lcam_csid_ctrl0(4, 0x4320) == 0x00032103, "CSID CORE_CTRL_0 %#x", lcam_csid_ctrl0(4, 0x4320));
	CHECK(lcam_csid_ctrl0(1, 0x0001) == 0, "lane 1 is the clock lane");
	CHECK(lcam_csiphy_mask(4) == 0x1f && lcam_csiphy_enable(0x1f) == 0xd5 && lcam_csiphy_enable(0x03) == 0x81, "phy");
	CHECK(lcam_csiphy_lane(1) == 0x700 && lcam_csiphy_lane(4) == 0x600, "lane blocks");
	CHECK(lcam_settle(0x13, 268800000) == 0x13 && lcam_settle(0x13, 200000000) == 14, "settle %u",
	    lcam_settle(0x13, 200000000));

	uint8_t raw[2 * 10];
	uint16_t px[2][8];
	for (uint32_t y = 0; y < 2; y++) {
		for (uint32_t x = 0; x < 8; x++) {
			px[y][x] = (uint16_t)((y * 8 + x) * 61 + 3);
			raw[y * 10 + x / 4 * 5 + (x & 3)] = (uint8_t)(px[y][x] >> 2);
		}
		for (uint32_t g = 0; g < 2; g++) {
			uint8_t lo = 0;
			for (uint32_t k = 0; k < 4; k++) {
				lo |= (uint8_t)((px[y][g * 4 + k] & 3) << (2 * k));
			}
			raw[y * 10 + g * 5 + 4] = lo;
		}
	}
	bool ok = true;
	uint32_t sum = 0;
	for (uint32_t y = 0; y < 2; y++) {
		for (uint32_t x = 0; x < 8; x++) {
			ok &= lcam_raw10_px(raw, 10, x, y) == px[y][x];
			sum += px[y][x];
		}
	}
	CHECK(ok, "RAW10 unpack");
	CHECK(lcam_raw10_stride(1280) == 1600, "stride");
	CHECK(lcam_raw10_mean(raw, 8, 2, 2) == sum / 16, "mean %u vs %u", lcam_raw10_mean(raw, 8, 2, 2), sum / 16);

	CHECK(lcam_gain_code(1024) == 0 && lcam_gain_code(2048) == 512 && lcam_gain_code(16384) == 960 &&
	    lcam_gain_code(99999) == 960, "gain codes");
	/* a scene that gives mean = black + 0.02 * exposure (lines x gain/1024): converges into the band */
	struct lcam_ae ae = { 732, 732, 1147 };
	uint32_t mean = 0, steps;
	for (steps = 0; steps < 20; steps++) {
		mean = LCAM_AE_BLACK + (uint32_t)((uint64_t)ae.lines * ae.gain / 1024 / 50);
		if (mean > 1023) {
			mean = 1023;
		}
		if (!lcam_ae_step(&ae, mean)) {
			break;
		}
	}
	CHECK(steps < 20 && mean > LCAM_AE_BLACK + LCAM_AE_TARGET * 7 / 8 && ae.lines == 732, "AE dark scene: mean %u lines %u"
	    " gain %u steps %u", mean, ae.lines, ae.gain, steps);
	ae = (struct lcam_ae){ 732, 732, 4096 };
	CHECK(lcam_ae_step(&ae, 1023) && ae.lines == 732 && ae.gain == 2048, "AE bright: halves (gain goes down first)");
	ae = (struct lcam_ae){ 732, 732, 1024 };
	CHECK(lcam_ae_step(&ae, 1023) && ae.lines == 366 && ae.gain == 1024, "AE bright at 1x: exposure halves");

	CHECK(lcam_fps10(94, 0, 1000000000ull) == 930 && lcam_fps10(1, 0, 5) == 0, "fps");
	uint8_t h[16];
	lcam_read_hdr(h, 7, 1400, 1400);
	CHECK(memcmp(h, "LCF1\x07\0\0\0\x78\x05\0\0\x78\x05\0\0", 16) == 0, "read header");
	uint32_t g, o;
	CHECK(lcam_parse_read(" 3 1151400", &g, &o) && g == 3 && o == 1151400, "camread parse");
	CHECK(!lcam_parse_read(" 3", &g, &o) && !lcam_parse_read(" 3 4x", &g, &o) && !lcam_parse_read(" 99999999999 0", &g, &o),
	    "camread refusals");
}

static void
dump_table(const struct lcam_lib *l, int t)
{
	const uint8_t *e;
	uint32_t n = lcam_lib_table(l, t, &e), writes = 0, i = 0, bl, bd;
	uint8_t out[11];

	if (t < 0) {
		printf("init %u\n", n);
	} else {
		printf("res %d %u\n", t, n);
	}
	for (uint32_t k = 0; k < n; k++) {
		uint16_t a;
		uint8_t v;
		uint32_t d;
		lcam_lib_entry(e, k, &a, &v, &d);
		printf("0x%04x 0x%02x %u\n", a, v, d);
	}
	while (i < n) {
		i = lcam_burst(e, n, i, out, &bl, &bd);
		writes++;
	}
	fprintf(stderr, "cam2_test: %s table %d: %u registers in %u CCI writes\n", l->name, t, n, writes);
}

static int
dump(const char *path)
{
	FILE *fp = fopen(path, "rb");
	static uint8_t buf[4 << 20];
	struct lcam_lib l;
	struct lcam_mode m;
	const char *why = "";
	size_t len;
	int want;

	if (!fp) {
		perror(path);
		return 1;
	}
	len = fread(buf, 1, sizeof(buf), fp);
	fclose(fp);
	if (lcam_lib_parse(buf, len, &l, &why) != 0) {
		printf("%s: %s\n", path, why);
		return 1;
	}
	printf("lib %s slave 0x%02x id 0x%04x@0x%04x modes %u lanes %u settle 0x%02x 3phase %u filter %u\n", l.name,
	    l.slave8, l.id, l.id_reg, l.nmodes, l.lanes, l.settle, l.three_phase, l.filter);
	for (uint32_t k = 0; k < l.nmodes; k++) {
		if (lcam_lib_mode(&l, k, &m) != 0) {
			printf("mode %u unusable\n", k);
			return 1;
		}
		printf("mode %u %ux%u line %u frame %u vt %u op %llu dt 0x%02x decode %u\n", k, m.w, m.h, m.line, m.frame,
		    m.vt_pclk, (unsigned long long)m.op_pclk, m.dt, m.decode);
	}
	want = lcam_lib_find(&l, 1280, 720);
	dump_table(&l, LCAM_LIB_INIT_MODE);
	if (want >= 0) {
		dump_table(&l, want);
	}
	return 0;
}

int
main(int argc, char **argv)
{
	if (argc == 3 && strcmp(argv[1], "--dump") == 0) {
		return dump(argv[2]);
	}
	unit();
	printf("cam2_test: %d checks, %d failed\n", checks, fails);
	return fails != 0;
}
