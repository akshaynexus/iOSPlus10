/*
 * laurel 2950: Mi A3 dual boot. The iOS root is the GPT partition `iosroot` on LUN 0 (docs/laurel_sprout/dual-boot.md). This file holds only rules on bytes: no I/O, no
 * allocation. It builds in the kernel (bsd/dev/sweet_ufs.c) and in the host test (tools/laurel-dualboot/test). tools/op10tool/src/gpt.rs writes the same layout.
 *
 * The rules are general, not the numbers of one phone, except the slot list around the new entry: 32 slots, 16 used, without a hole; slot 14 = metadata, 15 = userdata,
 * 16 = iosroot; each partition follows the one before it with no overlap; iosroot starts on 2 MiB and ends at the last usable block; both copies valid and equal.
 */
#ifndef LAUREL_DUALBOOT_H
#define LAUREL_DUALBOOT_H

#define LDB_BLOCK           4096u
#define LDB_ROOT_NAME       "iosroot"
#define LDB_GPT_SLOTS       32u
#define LDB_GPT_ESZ         128u
#define LDB_GPT_USED        16u
#define LDB_ALIGN_BLOCKS    512u                /* 2 MiB */
#define LDB_LOG_BLOCKS      1025u               /* SWEET_LOG_BLOCKS: the console log takes the end of the partition */
/* Patch 2950 is in this kernel. uefi-image.sh and android-guard.sh search a kernel and a boot image for this exact text: a kernel without it takes userdata as its root. */
#define LDB_KERNEL_MARKER   "LAUREL-2950-IOSROOT-FENCE-V3"

static inline uint32_t
ldb_crc32(const uint8_t *d, uint32_t len, uint32_t skip_at)
{
	uint32_t c = 0xffffffffu;
	for (uint32_t i = 0; i < len; i++) {
		/* skip_at: the 4 bytes of a header's own CRC count as zero */
		c ^= (i >= skip_at && i < skip_at + 4) ? 0 : d[i];
		for (unsigned k = 0; k < 8; k++) {
			c = (c >> 1) ^ (0xedb88320u & (0u - (c & 1)));
		}
	}
	return ~c;
}
static inline uint32_t
ldb_le32(const uint8_t *p)
{
	return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}
static inline uint64_t
ldb_le64(const uint8_t *p)
{
	return (uint64_t)ldb_le32(p) | (uint64_t)ldb_le32(p + 4) << 32;
}
/* The name of a GPT entry against an ASCII name. */
static inline bool
ldb_name_is(const uint8_t *e, const char *name)
{
	unsigned i = 0;
	for (; name[i]; i++) {
		if (e[56 + 2 * i] != (uint8_t)name[i] || e[57 + 2 * i] != 0) {
			return false;
		}
	}
	return i < 36 && e[56 + 2 * i] == 0 && e[57 + 2 * i] == 0;
}
static inline bool
ldb_slot_empty(const uint8_t *e)
{
	for (unsigned i = 0; i < LDB_GPT_ESZ; i++) {
		if (e[i]) {
			return false;
		}
	}
	return true;
}
/* One header with its entries. Returns NULL or the reason. */
static inline const char *
ldb_gpt_copy_check(const uint8_t *h, const uint8_t *entries, uint64_t lba)
{
	static const char sig[9] = "EFI PART";
	for (unsigned i = 0; i < 8; i++) {
		if (h[i] != (uint8_t)sig[i]) {
			return "a GPT copy has no signature";
		}
	}
	if (ldb_le32(h + 12) != 92 || ldb_crc32(h, 92, 16) != ldb_le32(h + 16)) {
		return "a GPT header has a wrong size or CRC";
	}
	if (ldb_le64(h + 24) != lba) {
		return "a GPT header is not at the block it names";
	}
	if (ldb_le32(h + 80) != LDB_GPT_SLOTS || ldb_le32(h + 84) != LDB_GPT_ESZ) {
		return "the GPT has an unexpected entry count";
	}
	if (ldb_crc32(entries, LDB_GPT_SLOTS * LDB_GPT_ESZ, 0xffffffffu) != ldb_le32(h + 88)) {
		return "a GPT entry array has a wrong CRC";
	}
	return NULL;
}
/*
 * Both copies of the GPT of LUN 0 against the expected layout. ph, pe: primary header (at LBA 1) and entries; bh, be: backup header and entries. Returns NULL or the reason;
 * first, blocks: where iosroot lies. Attributes of slot partitions change at each slot switch (HAL, ABL): they are not compared with a number, but the two copies must agree.
 */
static inline const char *
ldb_gpt_layout_check(const uint8_t *ph, const uint8_t *pe, const uint8_t *bh, const uint8_t *be, uint64_t *first, uint64_t *blocks)
{
	const char *why = ldb_gpt_copy_check(ph, pe, 1);
	if (why != NULL) {
		return why;
	}
	uint64_t alt = ldb_le64(ph + 32);
	why = ldb_gpt_copy_check(bh, be, alt);
	if (why != NULL) {
		return why;
	}
	if (ldb_le64(bh + 32) != 1) {
		return "the backup GPT header does not name the primary";
	}
	for (unsigned i = 0; i < LDB_GPT_SLOTS * LDB_GPT_ESZ; i++) {
		if (pe[i] != be[i]) {
			return "the two GPT copies differ";
		}
	}
	uint64_t f_use = ldb_le64(ph + 40), l_use = ldb_le64(ph + 48), prev = f_use - 1;
	if (ldb_le64(bh + 40) != f_use || ldb_le64(bh + 48) != l_use || l_use >= alt || f_use < 2) {
		return "the usable range of the GPT is wrong";
	}
	for (unsigned i = 0; i < LDB_GPT_SLOTS; i++) {
		const uint8_t *e = pe + i * LDB_GPT_ESZ;
		if (i >= LDB_GPT_USED) {
			if (!ldb_slot_empty(e)) {
				return "the GPT has more entries than expected";
			}
			continue;
		}
		if (ldb_slot_empty(e)) {
			return "the GPT has fewer entries than expected";
		}
		uint64_t a = ldb_le64(e + 32), b = ldb_le64(e + 40);
		if (a != prev + 1 || b < a || b > l_use) {
			return "the GPT entries are not one after the other";
		}
		prev = b;
	}
	const uint8_t *m = pe + 13 * LDB_GPT_ESZ, *u = pe + 14 * LDB_GPT_ESZ, *r = pe + 15 * LDB_GPT_ESZ;
	if (!ldb_name_is(m, "metadata") || !ldb_name_is(u, "userdata") || !ldb_name_is(r, LDB_ROOT_NAME)) {
		return "slots 14, 15, 16 of the GPT are not metadata, userdata, " LDB_ROOT_NAME;
	}
	for (unsigned i = 0; i < 13; i++) {
		if (ldb_name_is(pe + i * LDB_GPT_ESZ, LDB_ROOT_NAME)) {
			return "the GPT has a second " LDB_ROOT_NAME;
		}
	}
	uint64_t a = ldb_le64(r + 32), b = ldb_le64(r + 40);
	if (a % LDB_ALIGN_BLOCKS != 0 || b != l_use || ldb_le64(r + 48) != 0) {
		return LDB_ROOT_NAME " is not on 2 MiB, does not end at the last usable block, or has attributes";
	}
	*first = a;
	*blocks = b - a + 1;
	return NULL;
}
/* HFS+ or HFSX volume header at byte 1024 of a block: volume bytes, or 0 when it is not one. Big endian on disk. */
static inline uint64_t
ldb_hfs_volume_bytes(const uint8_t *block)
{
	const uint8_t *h = block + 1024;
	uint32_t ver = (uint32_t)h[2] << 8 | h[3];
	uint32_t bs = (uint32_t)h[40] << 24 | (uint32_t)h[41] << 16 | (uint32_t)h[42] << 8 | h[43];
	uint32_t tb = (uint32_t)h[44] << 24 | (uint32_t)h[45] << 16 | (uint32_t)h[46] << 8 | h[47];

	if (!((h[0] == 'H' && h[1] == '+' && ver == 4) || (h[0] == 'H' && h[1] == 'X' && ver == 5))) {
		return 0;
	}
	if (bs < 512 || bs > (1u << 16) || (bs & (bs - 1)) != 0 || tb == 0) {
		return 0;
	}
	return (uint64_t)bs * tb;
}

#endif /* LAUREL_DUALBOOT_H */
