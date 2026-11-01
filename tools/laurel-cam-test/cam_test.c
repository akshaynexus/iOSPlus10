/*
 * Host test of the Mi A3 camera core (patch 2770: bsd/dev/laurel_cam_core.h, taken from the patch by
 * scripts/laurel/cam-test.sh). Checks: the slot tables are usable, the CCI command words match Linux
 * i2c-qcom-cci.c, the read buffer unpacking, the chip-ID match, the TLMM tiles of every camera pin, and (when
 * out/laurel/camera/sensors.txt exists: scripts/laurel/camera-inventory.sh) that every sensor's address and
 * chip ID equal the stock library values.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "laurel_cam_core.h"

static int fails, checks;

#define CHECK(c, ...) do { checks++; if (!(c)) { fails++; printf("FAIL %s:%d: ", __FILE__, __LINE__); \
	printf(__VA_ARGS__); printf("\n"); } } while (0)

static void
test_slots(void)
{
	for (unsigned i = 0; i < LCAM_NSLOTS; i++) {
		const struct lcam_slot *s = &lcam_slots[i];
		CHECK(lcam_slot_ok(s), "slot %u (%s) table not usable", i, s->role);
		for (unsigned p = 0; p < LCAM_NPINS; p++) {
			if (s->pin[p] >= 0) {
				CHECK(lcam_tile((unsigned)s->pin[p]) != 0, "slot %s pin %d has no tile", s->role, s->pin[p]);
			}
		}
		CHECK(lcam_tile(lcam_mclk_pin[s->mclk].gpio) == LCAM_TILE_SOUTH, "MCLK%u pin tile", s->mclk);
	}
	for (unsigned m = 0; m < 2; m++) {
		for (unsigned k = 0; k < 2; k++) {
			CHECK(lcam_tile(lcam_cci_pin[m][k]) != 0, "CCI pin %u no tile", lcam_cci_pin[m][k]);
		}
	}
	/* pinctrl-trinket.c: gpio 37 SOUTH, 38-40 EAST, 14/15 WEST */
	CHECK(lcam_tile(37) == LCAM_TILE_SOUTH && lcam_tile(38) == LCAM_TILE_EAST && lcam_tile(14) == LCAM_TILE_WEST,
	    "tiles of 37/38/14");
	CHECK(lcam_tile(10) == 0, "gpio 10 (Bluetooth) is not a camera pin");
	/* rear and depth must not share a master with another address of the same value */
	CHECK(lcam_slots[0].master == 0 && lcam_slots[1].master == 1 && lcam_slots[2].master == 1 &&
	    lcam_slots[3].master == 1, "CCI masters 0/1/1/1 (DT cci-master)");
	/* the M1 sensors need distinct addresses (all share the bus and VIO) */
	uint8_t seen[128] = { 0 };
	for (unsigned i = 1; i < LCAM_NSLOTS; i++) {
		for (unsigned c = 0; c < LCAM_MAX_CAND && lcam_slots[i].cand[c]; c++) {
			uint8_t a = lcam_slots[i].cand[c]->addr;
			CHECK(!seen[a], "M1 address %#x used twice", a);
			seen[a] = 1;
		}
	}
}

static void
test_cci_words(void)
{
	uint32_t w[3] = { 0 };
	uint8_t a[2], buf[12];
	unsigned n;

	CHECK(lcam_cci_set_param(0x1a) == 0x1a1, "SET_PARAM 0x1a -> %#x", lcam_cci_set_param(0x1a));
	CHECK(lcam_cci_set_param(0x9a) == 0x1a1, "SET_PARAM keeps 7 bits");
	CHECK(lcam_cci_read_cmd(2) == 0x2a, "READ 2 -> %#x", lcam_cci_read_cmd(2));
	CHECK(lcam_cci_report() == 0x108, "REPORT -> %#x", lcam_cci_report());
	n = lcam_reg_addr_bytes(&lcam_imx586, 0x0016, a);
	CHECK(n == 2 && a[0] == 0x00 && a[1] == 0x16, "16-bit address bytes");
	n = lcam_cci_write_words(a, 2, w);
	CHECK(n == 1 && w[0] == 0x00160029u, "WRITE 00 16 -> n %u word %#x", n, w[0]);
	n = lcam_reg_addr_bytes(&lcam_gc2375, 0x00f0, a);
	CHECK(n == 1 && a[0] == 0xf0, "8-bit address byte");
	n = lcam_cci_write_words(a, 1, w);
	CHECK(n == 1 && w[0] == 0x0000f019u, "WRITE f0 -> %#x", w[0]);
	for (unsigned i = 0; i < 12; i++) {
		buf[i] = (uint8_t)(0x10 + i);
	}
	n = lcam_cci_write_words(buf, 11, w);
	CHECK(n == 3 && w[0] == 0x121110b9u && w[2] == 0x1a191817u, "WRITE 11 bytes -> %u %#x %#x", n, w[0], w[2]);
	CHECK(lcam_cci_write_words(buf, 12, w) == 0 && lcam_cci_write_words(buf, 0, w) == 0, "WRITE length limits");
	CHECK(lcam_cci_read_words(2) == 1 && lcam_cci_read_words(3) == 1 && lcam_cci_read_words(4) == 2 &&
	    lcam_cci_read_words(12) == 4, "read buffer words");
}

static void
test_unpack_match(void)
{
	uint8_t b[12];
	/* reg 0x0016 = 0x05 (high byte), 0x0017 = 0x86: the buffer word is echo 0x35, then 0x05, 0x86 */
	uint32_t words[1] = { 0x00860535u };
	uint8_t id582[2] = { 0x05, 0x82 }, idgc[2] = { 0x23, 0x75 }, idov[2] = { 0x25, 0x09 };
	uint8_t idgd1[2] = { 0x08, 0x41 }, id4h7[2] = { 0x48, 0x7b }, swapped[2] = { 0x86, 0x05 };
	uint32_t w12[4] = { 0x030201aau, 0x07060504u, 0x0b0a0908u, 0x000e0d0cu };

	CHECK(lcam_cci_unpack(words, 1, b, 2) == 2 && b[0] == 0x05 && b[1] == 0x86, "unpack 2 bytes");
	CHECK(lcam_match(&lcam_slots[0], 0x1a, b) == &lcam_imx586, "IMX586 by its ID");
	CHECK(lcam_match(&lcam_slots[0], 0x1a, swapped) == NULL, "byte order: 0x8605 is not an IMX586");
	CHECK(lcam_match(&lcam_slots[0], 0x1b, b) == NULL, "right ID at the wrong address");
	CHECK(lcam_match(&lcam_slots[0], 0x1a, id582) == &lcam_imx582, "IMX582 by its ID");
	CHECK(lcam_match(&lcam_slots[1], 0x17, idgc) == &lcam_gc2375, "GC2375H");
	CHECK(lcam_match(&lcam_slots[1], 0x3d, idov) == &lcam_ov02a10, "OV02A10");
	CHECK(lcam_match(&lcam_slots[1], 0x3d, idgc) == NULL, "GC ID at the OV address");
	CHECK(lcam_match(&lcam_slots[2], 0x2d, idgd1) == &lcam_s5kgd1, "S5KGD1");
	CHECK(lcam_match(&lcam_slots[3], 0x10, id4h7) == &lcam_s5k4h7, "S5K4H7");
	CHECK(lcam_match(&lcam_slots[3], 0x2d, idgd1) == NULL, "front sensor is not the ultrawide");
	CHECK(lcam_cci_unpack(w12, 4, b, 12) == 12 && b[0] == 1 && b[2] == 3 && b[3] == 4 && b[11] == 0x0c,
	    "unpack 12 bytes");
}

/* sensors.txt line: "  CCI slave 0x34 (7-bit 0x1a), 1M, 16-bit register addresses, chip ID 0x0586 at 0x0016" */
static void
test_sensors_txt(const char *path)
{
	FILE *f = fopen(path, "r");
	char line[512], name[64] = "";
	unsigned matched = 0;
	const struct lcam_sensor *all[] = { &lcam_imx586, &lcam_imx582, &lcam_gc2375, &lcam_ov02a10, &lcam_s5kgd1,
		                            &lcam_s5k4h7 };

	if (!f) {
		printf("cam-test: %s not there: stock library cross-check skipped\n", path);
		return;
	}
	while (fgets(line, sizeof(line), f)) {
		unsigned a8, a7, id, reg;
		char bits[8];
		if (line[0] != ' ' && sscanf(line, "laurus_%63[a-z0-9]", name) == 1) {
			continue;
		}
		if (sscanf(line, "  CCI slave %x (7-bit %x), %*[^,], %7[0-9]-bit register addresses, chip ID %x at %x",
		    &a8, &a7, bits, &id, &reg) != 5) {
			continue;
		}
		for (unsigned i = 0; i < sizeof(all) / sizeof(all[0]); i++) {
			if (all[i]->id == id) {
				matched++;
				CHECK(all[i]->addr == a7 && all[i]->id_reg == reg && all[i]->reg16 == (strcmp(bits, "16") == 0),
				    "%s: table addr %#x reg %#x vs library %#x %#x", all[i]->name, all[i]->addr, all[i]->id_reg, a7, reg);
			}
		}
	}
	fclose(f);
	CHECK(matched >= 6, "sensors.txt: only %u sensors matched", matched);
	printf("cam-test: %u library entries cross-checked\n", matched);
}

int
main(int argc, char **argv)
{
	test_slots();
	test_cci_words();
	test_unpack_match();
	if (argc > 1) {
		test_sensors_txt(argv[1]);
	}
	printf("cam-test: %d/%d checks passed\n", checks - fails, checks);
	return fails ? 1 : 0;
}
