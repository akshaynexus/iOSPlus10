/*
 * Host unit test of the boot log checks of patch 0367 (bsd/dev/negroni_bootlog_core.h, taken from the
 * patch by scripts/kernel/test-bootlog-core.sh): the write gate (partition bounds + log window), the
 * HFS+ end / area start check, the ctl number parser and the CRC-32 (against zlib).
 */
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <zlib.h>
#include "negroni_bootlog_core.h"

static int fails, checks;
#define CHECK(c) do { checks++; if (!(c)) { fails++; printf("FAIL line %d: %s\n", __LINE__, #c); } } while (0)

static void
vh(uint8_t *b, uint16_t sig, uint32_t bsize, uint32_t nblk)
{
	memset(b, 0, 512);
	b[0] = sig >> 8; b[1] = sig & 0xff;
	for (int i = 0; i < 4; i++) {
		b[40 + i] = (uint8_t)(bsize >> (24 - 8 * i));
		b[44 + i] = (uint8_t)(nblk >> (24 - 8 * i));
	}
}

int
main(void)
{
	/* NE2211 userdata: first LBA of the partition, N = 58672399 */
	const uint64_t first = 0x1000, N = 58672399, MAXC = 256;
	const uint64_t lo = first + N - NBL_CORE_FROM_END, hi = lo + NBL_CORE_AREA_BLOCKS;

	/* partition bounds */
	CHECK(nbl_core_in_partition(first, N, first, 1, MAXC));
	CHECK(nbl_core_in_partition(first, N, first + N - 1, 1, MAXC));
	CHECK(!nbl_core_in_partition(first, N, first + N - 1, 2, MAXC));
	CHECK(!nbl_core_in_partition(first, N, first - 1, 1, MAXC));
	CHECK(!nbl_core_in_partition(first, N, first + N, 1, MAXC));
	CHECK(!nbl_core_in_partition(first, N, first, 0, MAXC));
	CHECK(!nbl_core_in_partition(first, N, first, MAXC + 1, MAXC));
	CHECK(!nbl_core_in_partition(first, 0, first, 1, MAXC));
	CHECK(!nbl_core_in_partition(0xfffffff0ull, 0x100, 0xfffffffeull, 4, MAXC));   /* 32-bit LBA end */
	CHECK(!nbl_core_in_partition(first, N, UINT64_MAX - 1, 4, MAXC));

	/* log window */
	CHECK(lo == first + 58643726ull && hi == first + 58652942ull);    /* hi = WLAN area start */
	CHECK(nbl_core_in_window(lo, hi, lo, 1));
	CHECK(nbl_core_in_window(lo, hi, hi - 1, 1));
	CHECK(nbl_core_in_window(lo, hi, lo, 256));
	CHECK(!nbl_core_in_window(lo, hi, hi - 1, 2));                    /* into the WLAN area */
	CHECK(!nbl_core_in_window(lo, hi, hi, 1));
	CHECK(!nbl_core_in_window(lo, hi, lo - 1, 1));                    /* below the area */
	CHECK(!nbl_core_in_window(lo, hi, lo - 1, 2));
	CHECK(!nbl_core_in_window(lo, hi, lo, 0));
	CHECK(!nbl_core_in_window(0, 0, 0, 1));                           /* closed */
	CHECK(!nbl_core_in_window(0, 0, lo, 1));
	CHECK(!nbl_core_in_window(hi, lo, lo, 1));                        /* inverted */
	CHECK(!nbl_core_in_window(lo, hi, UINT64_MAX, 1));
	CHECK(!nbl_core_in_window(lo, hi, lo, UINT32_MAX));
	/* every slot block and the superblock are in the window; slot 7 ends below hi */
	for (uint32_t i = 0; i < 8; i++) {
		CHECK(nbl_core_in_window(lo, hi, lo + 1 + i * 1025ull, 1));
		CHECK(nbl_core_in_window(lo, hi, lo + 2 + i * 1025ull + 768, 256));
	}

	/* HFS+ end and the area start */
	uint8_t b[512];
	uint64_t end = 0, rel = 0;
	vh(b, 0x482b, 4096, 4194304);                                     /* today's 16 GiB root */
	CHECK(nbl_core_hfs_end(b, &end) == 0 && end == 4194304);
	CHECK(nbl_core_area_rel(N, end, &rel) == 0 && rel == 58643726);
	vh(b, 0x4858, 8192, 3);                                           /* HFSX, 8 KiB blocks */
	CHECK(nbl_core_hfs_end(b, &end) == 0 && end == 6);
	vh(b, 0x482b, 512, 9);                                            /* rounds up */
	CHECK(nbl_core_hfs_end(b, &end) == 0 && end == 2);
	vh(b, 0x482b, 4096, (uint32_t)(N - 28673));                       /* ends exactly at the area */
	CHECK(nbl_core_hfs_end(b, &end) == 0 && nbl_core_area_rel(N, end, &rel) == 0);
	vh(b, 0x482b, 4096, (uint32_t)(N - 28673 + 1));                   /* one block into the area */
	CHECK(nbl_core_hfs_end(b, &end) == 0 && nbl_core_area_rel(N, end, &rel) == -2);
	vh(b, 0x482b, 4096, 0xffffffffu);                                 /* larger than the partition */
	CHECK(nbl_core_hfs_end(b, &end) == 0 && nbl_core_area_rel(N, end, &rel) == -2);
	vh(b, 0x4244, 4096, 100);                                         /* "BD" HFS wrapper: refused */
	CHECK(nbl_core_hfs_end(b, &end) == -1);
	vh(b, 0x482b, 4095, 100);
	CHECK(nbl_core_hfs_end(b, &end) == -1);
	vh(b, 0x482b, 256, 100);
	CHECK(nbl_core_hfs_end(b, &end) == -1);
	vh(b, 0x482b, 4096, 0);
	CHECK(nbl_core_hfs_end(b, &end) == -1);
	memset(b, 0, sizeof(b));                                          /* APFS / empty */
	CHECK(nbl_core_hfs_end(b, &end) == -1);
	CHECK(nbl_core_area_rel(28673 + 15, 0, &rel) == -1);
	CHECK(nbl_core_area_rel(28673 + 16, 0, &rel) == 0 && rel == 16);

	/* ctl number parser ("bootlog read A C") */
	const char *q;
	bool ok;
	q = "9215 4"; ok = true;
	CHECK(nbl_core_parse_u32(&q, &ok) == 9215 && ok && *q == ' ');
	q++;
	CHECK(nbl_core_parse_u32(&q, &ok) == 4 && ok && *q == 0);
	q = "0"; ok = true;
	CHECK(nbl_core_parse_u32(&q, &ok) == 0 && ok && *q == 0);
	q = "x1"; ok = true;
	(void)nbl_core_parse_u32(&q, &ok);
	CHECK(!ok);
	q = ""; ok = true;
	(void)nbl_core_parse_u32(&q, &ok);
	CHECK(!ok);
	q = "999999999"; ok = true;
	CHECK(nbl_core_parse_u32(&q, &ok) == 999999999u && ok);
	q = "4294967296"; ok = true;                                      /* 10 digits: refused, no wrap */
	(void)nbl_core_parse_u32(&q, &ok);
	CHECK(!ok);
	q = "-1"; ok = true;
	(void)nbl_core_parse_u32(&q, &ok);
	CHECK(!ok);

	/* CRC-32 = zlib */
	const char *s = "123456789";
	CHECK(nbl_core_crc32(s, 9) == 0xcbf43926u);
	uint8_t big[1928];
	for (size_t i = 0; i < sizeof(big); i++) {
		big[i] = (uint8_t)(i * 7 + 3);
	}
	CHECK(nbl_core_crc32(big, sizeof(big)) == (uint32_t)crc32(0, big, sizeof(big)));
	CHECK(nbl_core_crc32(big, 0) == 0);

	printf("bootlog-core-test: %d checks, %d failed\n", checks, fails);
	return fails ? 1 : 0;
}
