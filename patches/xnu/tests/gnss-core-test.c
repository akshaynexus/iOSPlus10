/*
 * Host test for patch 0397 (bsd/dev/negroni_gnss_core.h, the pure parts of negroni_gnss.c):
 *   - gc_dbl_scaled / gc_flt_scaled (IEEE-754 without the FPU) against the host FPU on 2 million values
 *   - gc_qmi_find on good, short and lying TLV lists
 *   - gc_tftp_path (prefix map, "..", sizes)
 *   - with an image: the FAT16 reader on a copy of modem_a. "IMG PATH" prints the FNV-1a 64 hash and size of
 *     PATH as read through the reader (the script compares it with an independent Python reader).
 * Run it with scripts/kernel/test-gnss-core.sh (takes the header from the patch).
 *
 *   gnss-core-test                 unit tests
 *   gnss-core-test IMG PATH...     hashes of files on the FAT image IMG
 */
#include <fcntl.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include "negroni_gnss_core.h"

static int fails;
#define CHECK(c, ...) do { if (!(c)) { fails++; printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

static uint64_t
rng(void)
{
	static uint64_t x = 0x9e3779b97f4a7c15ull;
	x ^= x << 13;
	x ^= x >> 7;
	x ^= x << 17;
	return x;
}

static void
test_float(void)
{
	static const double fixed[] = { 0.0, -0.0, 1.0, -1.0, 48.8584, 2.2945, -33.8688, 151.2093, 89.9999999, -179.9999999,
		                        0.00000005, -0.00000005, 0.00000015, 1e-300, 123456.789 };
	for (size_t i = 0; i < sizeof(fixed) / sizeof(fixed[0]); i++) {
		uint64_t b;
		memcpy(&b, &fixed[i], 8);
		int64_t got = gc_dbl_scaled(b, 10000000), want = (int64_t)llround(fixed[i] * 1e7);
		/* 5e-8 and 1.5e-7 are just under .5 as doubles: the integer path is exact, the host product rounds up */
		CHECK(llabs(got - want) <= 1, "dbl %.10g: %lld want %lld", fixed[i], (long long)got, (long long)want);
	}
	for (int i = 0; i < 1000000; i++) {
		double d = ((double)(rng() >> 11) / 9007199254740992.0 - 0.5) * 360.0;
		uint64_t b;
		memcpy(&b, &d, 8);
		int64_t got = gc_dbl_scaled(b, 10000000);
		double exact = d * 1e7;
		/* the host product rounds once more than the integer path: allow 1 unit at a .5 tie */
		CHECK(llabs(got - (int64_t)llround(exact)) <= 1, "dbl %.17g: %lld want %lld", d, (long long)got, (long long)llround(exact));
		if (fails > 10) {
			return;
		}
	}
	for (int i = 0; i < 1000000; i++) {
		float f = (float)(((double)(rng() >> 40) / 16777216.0 - 0.5) * 20000.0);
		uint32_t b;
		memcpy(&b, &f, 4);
		int64_t got = gc_flt_scaled(b, 100);
		CHECK(llabs(got - (int64_t)llround((double)f * 100.0)) <= 1, "flt %.9g: %lld", (double)f, (long long)got);
		if (fails > 10) {
			return;
		}
	}
	{
		double la = 48.8584, lo = -151.2093;
		uint64_t b1, b2;
		memcpy(&b1, &la, 8);
		memcpy(&b2, &lo, 8);
		CHECK(gc_dbl_scaled(b1, 10000000) == 488584000 && gc_dbl_scaled(b2, 10000000) == -1512093000, "exact coordinates");
		float h = 12.34f;
		uint32_t hb;
		memcpy(&hb, &h, 4);
		CHECK(gc_flt_scaled(hb, 100) == 1234, "12.34 m");
	}
	uint64_t nan = 0x7ff8000000000000ull, inf = 0x7ff0000000000000ull;
	CHECK(gc_dbl_scaled(nan, 100) == GC_NO && gc_dbl_scaled(inf, 100) == GC_NO, "NaN/Inf");
	double big = 1e300;
	uint64_t bb;
	memcpy(&bb, &big, 8);
	CHECK(gc_dbl_scaled(bb, 100) == GC_NO, "overflow");
	uint32_t fnan = 0x7fc00000u;
	CHECK(gc_flt_scaled(fnan, 100) == GC_NO, "float NaN");
}

static void
test_qmi(void)
{
	/* header: type 4, txn 1, msg 0x24, len 15; TLV 0x01 len 4; TLV 0x10 len 5 (lat would be 8: still found as 5) */
	uint8_t m[] = { 4, 1, 0, 0x24, 0, 15, 0, 0x01, 4, 0, 1, 2, 3, 4, 0x10, 5, 0, 9, 9, 9, 9, 9 };
	uint16_t s = 0;
	const uint8_t *v = gc_qmi_find(m, sizeof(m), 0x01, &s);
	CHECK(v == m + 10 && s == 4, "tlv 1");
	v = gc_qmi_find(m, sizeof(m), 0x10, &s);
	CHECK(v == m + 17 && s == 5, "tlv 0x10");
	CHECK(gc_qmi_find(m, sizeof(m), 0x11, &s) == NULL, "absent");
	CHECK(gc_qmi_find(m, sizeof(m) - 1, 0x10, &s) == NULL, "truncated buffer");
	m[5] = 14;                                      /* header length shorter than the last TLV */
	CHECK(gc_qmi_find(m, sizeof(m), 0x10, &s) == NULL, "header length bound");
	m[5] = 15;
	m[15] = 0xff;                                   /* a TLV that claims more than there is */
	CHECK(gc_qmi_find(m, sizeof(m), 0x10, &s) == NULL, "lying TLV length");
	CHECK(gc_qmi_find(m, 6, 0x01, &s) == NULL, "short header");
}

static void
test_tftp(void)
{
	char out[64];
	CHECK(gc_tftp_path("/readonly/firmware/image/modem_pr/so/665_0_0.mbn", out, sizeof(out)) &&
	    strcmp(out, "image/modem_pr/so/665_0_0.mbn") == 0, "firmware image");
	CHECK(gc_tftp_path("/readonly/vendor/firmware_mnt/image/a.bin", out, sizeof(out)) && strcmp(out, "image/a.bin") == 0, "mnt");
	CHECK(gc_tftp_path("/readonly/vendor/firmware/b.bin", out, sizeof(out)) && strcmp(out, "image/b.bin") == 0, "vendor");
	CHECK(!gc_tftp_path("/readonly/firmware/image/../x", out, sizeof(out)), "dotdot");
	CHECK(!gc_tftp_path("/readwrite/server_check.txt", out, sizeof(out)), "readwrite");
	CHECK(!gc_tftp_path("/readonly/firmware/image/", out, sizeof(out)), "empty");
	CHECK(!gc_tftp_path("/readonly", out, sizeof(out)), "short");
	CHECK(!gc_tftp_path("/readonly/firmware/image/0123456789012345678901234567890123456789012345678901234567", out, sizeof(out)),
	    "too long");
}

static int img_fd = -1;

static int
img_read(void *ctx, uint64_t at, void *dst, uint32_t n)
{
	(void)ctx;
	return pread(img_fd, dst, n, (off_t)at) == (ssize_t)n ? 0 : 5;
}

int
main(int argc, char **argv)
{
	if (argc < 3) {
		test_float();
		test_qmi();
		test_tftp();
		printf("%s (%d failures)\n", fails ? "FAIL" : "PASS", fails);
		return fails != 0;
	}
	struct stat st;
	img_fd = open(argv[1], O_RDONLY);
	if (img_fd < 0 || fstat(img_fd, &st) != 0) {
		perror(argv[1]);
		return 2;
	}
	struct gc_fat v;
	uint8_t bs[512];
	memset(&v, 0, sizeof(v));
	v.read = img_read;
	/* the partition is 300 MiB; a dump may end after the last used cluster: reads past its end fail instead */
	v.size = (uint64_t)st.st_size < (300ull << 20) ? (300ull << 20) : (uint64_t)st.st_size;
	v.dir_max = 256u << 10;
	v.max_read = 1u << 20;
	v.dir = malloc(v.dir_max);
	if (img_read(NULL, 0, bs, 512) != 0 || gc_fat_parse(&v, bs) != 0) {
		printf("FAIL: not FAT16\n");
		return 1;
	}
	uint16_t *fat = malloc(v.fat_bytes);
	img_read(NULL, v.fat_off, fat, v.fat_bytes);
	v.fat = fat;
	for (int i = 2; i < argc; i++) {
		uint32_t c = 0, s = 0;
		if (!gc_fat_lookup(&v, argv[i], &c, &s)) {
			printf("%s missing\n", argv[i]);
			continue;
		}
		uint8_t *buf = malloc(s ? s : 1);
		uint64_t h = 0xcbf29ce484222325ull;
		/* read in odd pieces so that runs, cluster ends and offsets are crossed */
		for (uint32_t at = 0, step = 777; at < s; at += step, step = step * 3 % 1500007 + 1) {
			uint32_t n = s - at < step ? s - at : step;
			if (gc_fat_read(&v, c, s, at, buf + at, n) != 0) {
				printf("FAIL read %s at %u\n", argv[i], at);
				return 1;
			}
		}
		for (uint32_t k = 0; k < s; k++) {
			h = (h ^ buf[k]) * 0x100000001b3ull;
		}
		printf("%s %u %016llx\n", argv[i], s, (unsigned long long)h);
		free(buf);
	}
	return 0;
}
