/*
 * laurel 2950: Mi A3 dual boot: the iOS root lives in a pinned, preallocated f2fs file of Android's /data, and XNU reaches it
 * by a table of raw extents on the userdata partition. A bug here corrupts Android data, so this file holds only arithmetic on the
 * table: no I/O, no allocation, no f2fs parsing. The same file builds in the kernel (bsd/dev/sweet_ufs.c), in the phone helper
 * (tools/laurel-dualboot/ldbhelper.c) and in the host test (scripts/laurel/test-dualboot.sh). tools/op10tool/src/dualboot.rs writes
 * the same format and has the same rules. docs/laurel_sprout/dual-boot.md.
 *
 * Terms. Device block: 4096 bytes. Partition block: device block counted from the start of userdata (f2fs block address, because
 * f2fs on dm-default-key on userdata has no offset). LBA: device block counted from the start of LUN 0. Area block: block of the
 * mapped file. The first LDB_RESERVED_BLOCKS area blocks hold the header; the BSD disk ufsroot0 starts behind them.
 */
#ifndef LAUREL_DUALBOOT_H
#define LAUREL_DUALBOOT_H

#define LDB_BLOCK           4096u
#define LDB_MAX_EXTENTS     4096u               /* a fresh allocation has far fewer; more = allocate again, not a bigger table */
#define LDB_RESERVED_BLOCKS 256u                /* 1 MiB: header in block 0, the rest stays empty */
#define LDB_MIN_PART_BLOCK  512u                /* f2fs: never the superblock segment (and the area is always in the main area) */
#define LDB_FP_BLOCKS       3u                  /* superblock block + both checkpoint pack heads */
#define LDB_TABLE_MAGIC     "LDBTABL1"
#define LDB_HDR_MAGIC       "LAURELDB"
#define LDB_VERSION         1u                  /* of the table */
#define LDB_HDR_VERSION     2u                  /* of the area header. Version 1 had a state FRESH, which passed against any filesystem. */
/*
 * One state lets the kernel write: BOUND. The fingerprint in it was taken by ldbhelper seal with /data frozen, right after the pin and FIEMAP check, in the
 * same frozen period (docs/laurel_sprout/dual-boot.md, section "The fingerprint"). No other number passes. The kernel never writes this header.
 */
#define LDB_STATE_BOUND     2u
#define LDB_STATE_OFF       3u                  /* written by ldbhelper when a seal fails after its header went out */
/* Patch 2950 is in this kernel. uefi-image.sh and android-guard.sh search a kernel and a boot image for this exact text: a kernel without 2950 ignores the table and writes its log into /data. */
#define LDB_KERNEL_MARKER   "LAUREL-2950-DUALBOOT-FENCE-V2-SEAL-AT-FREEZE"

/* The blob of ADT /chosen laurel-dualboot, little endian: this header + count x struct ldb_extent. */
struct ldb_table {
	char magic[8];
	uint32_t version, block_size, count, reserved_blocks;
	uint64_t part_first;                    /* LBA of userdata on LUN 0 */
	uint64_t part_blocks;                   /* size of userdata */
	uint64_t area_blocks;                   /* size of the mapped file */
	uint64_t table_id;                      /* new for every allocation */
	uint64_t hash;                          /* ldb_hash of the whole blob, this field zero */
};

struct ldb_extent {
	uint64_t area_block, part_block, blocks;
};

/* Area block 0: written raw by the Android helper (seal, wipe). XNU only reads it. Little endian. */
struct ldb_header {
	char magic[8];
	uint32_t version, state;
	uint64_t table_id, table_hash, area_blocks, seal_generation;
	uint64_t fp_part_block[LDB_FP_BLOCKS];  /* where the Android filesystem must not have changed; outside the table */
	uint64_t fp_hash[LDB_FP_BLOCKS];        /* raw bytes (ciphertext), read on a frozen /data */
	uint64_t hash;                          /* ldb_hash of this struct, this field zero */
};

_Static_assert(sizeof(struct ldb_table) == 64, "table header layout");
_Static_assert(sizeof(struct ldb_extent) == 24, "extent layout");
_Static_assert(sizeof(struct ldb_header) == 104, "area header layout");

/* FNV-1a 64: not against an attacker; it finds a stale table, a moved file, a changed block. */
static inline uint64_t
ldb_hash_add(uint64_t h, const void *data, uint64_t len)
{
	const uint8_t *p = (const uint8_t *)data;
	for (uint64_t i = 0; i < len; i++) {
		h = (h ^ p[i]) * 0x100000001b3ull;
	}
	return h;
}
#define LDB_HASH_INIT 0xcbf29ce484222325ull

static inline uint64_t
ldb_hash_zeroing(const void *data, uint64_t len, uint64_t field_off)
{
	static const uint8_t zero[8] = { 0 };
	uint64_t h = ldb_hash_add(LDB_HASH_INIT, data, field_off);
	h = ldb_hash_add(h, zero, 8);
	return ldb_hash_add(h, (const uint8_t *)data + field_off + 8, len - field_off - 8);
}

static inline const struct ldb_extent *
ldb_extents(const struct ldb_table *t)
{
	return (const struct ldb_extent *)(const void *)(t + 1);
}

static inline uint64_t
ldb_table_hash(const void *blob, uint64_t len)
{
	return ldb_hash_zeroing(blob, len, __builtin_offsetof(struct ldb_table, hash));
}

static inline uint64_t
ldb_header_hash(const struct ldb_header *h)
{
	return ldb_hash_zeroing(h, sizeof(*h), __builtin_offsetof(struct ldb_header, hash));
}

/*
 * Every rule a table must pass. Returns NULL or the reason. The blob needs 8-byte alignment.
 * A hole in the area, an overlap, a block outside userdata, a wrong hash: refused.
 */
static inline const char *
ldb_table_check(const void *blob, uint64_t len)
{
	const struct ldb_table *t = (const struct ldb_table *)blob;

	if (blob == NULL || len < sizeof(*t) || ((uintptr_t)blob & 7) != 0) {
		return "table too short or not aligned";
	}
	for (unsigned i = 0; i < 8; i++) {
		if (t->magic[i] != LDB_TABLE_MAGIC[i]) {
			return "table has no magic";
		}
	}
	if (t->version != LDB_VERSION || t->block_size != LDB_BLOCK || t->reserved_blocks != LDB_RESERVED_BLOCKS) {
		return "table version, block size or reserved size is not this kernel's";
	}
	if (t->count == 0 || t->count > LDB_MAX_EXTENTS) {
		return "table extent count out of range";
	}
	if (len != sizeof(*t) + (uint64_t)t->count * sizeof(struct ldb_extent)) {
		return "table length does not match its extent count";
	}
	if (ldb_table_hash(blob, len) != t->hash) {
		return "table hash wrong";
	}
	if (t->part_first == 0 || t->part_blocks == 0 || t->part_first + t->part_blocks < t->part_first) {
		return "table has no valid partition";
	}
	if (t->area_blocks <= LDB_RESERVED_BLOCKS || t->area_blocks > t->part_blocks) {
		return "area size out of range";
	}
	const struct ldb_extent *e = ldb_extents(t);
	uint64_t next = 0;
	for (uint32_t i = 0; i < t->count; i++) {
		if (e[i].blocks == 0 || e[i].area_block != next) {
			return "area is not contiguous from block 0";
		}
		if (e[i].part_block < LDB_MIN_PART_BLOCK || e[i].part_block >= t->part_blocks ||
		    e[i].blocks > t->part_blocks - e[i].part_block) {
			return "extent outside userdata";
		}
		next += e[i].blocks;
		if (next > t->area_blocks) {
			return "extents longer than the area";
		}
		for (uint32_t k = 0; k < i; k++) {
			if (e[i].part_block < e[k].part_block + e[k].blocks && e[k].part_block < e[i].part_block + e[i].blocks) {
				return "two extents overlap on the partition";
			}
		}
	}
	if (next != t->area_blocks) {
		return "extents shorter than the area";
	}
	return NULL;
}

/* Area block -> LBA and how many blocks are contiguous from there, at most want. 0, or -1 = not in the area. */
static inline int
ldb_map(const struct ldb_table *t, uint64_t area_block, uint32_t want, uint64_t *lba, uint32_t *run)
{
	const struct ldb_extent *e = ldb_extents(t);

	if (want == 0) {
		return -1;
	}
	for (uint32_t i = 0; i < t->count; i++) {
		if (area_block >= e[i].area_block && area_block - e[i].area_block < e[i].blocks) {
			uint64_t in = area_block - e[i].area_block, left = e[i].blocks - in;
			*lba = t->part_first + e[i].part_block + in;
			*run = left < want ? (uint32_t)left : want;
			return 0;
		}
	}
	return -1;
}

/* Write fence, separate from ldb_map on purpose: true only when every block of [lba, lba + count) is in one extent of the table. */
static inline bool
ldb_lba_allowed(const struct ldb_table *t, uint64_t lba, uint32_t count)
{
	const struct ldb_extent *e = ldb_extents(t);

	if (count == 0 || lba < t->part_first || lba + count < lba) {
		return false;
	}
	uint64_t pb = lba - t->part_first;
	for (uint32_t i = 0; i < t->count; i++) {
		if (pb >= e[i].part_block && pb - e[i].part_block < e[i].blocks) {
			return count <= e[i].blocks - (pb - e[i].part_block);
		}
	}
	return false;
}

/* Is this partition block inside the table? (the fingerprint blocks must not be) */
static inline bool
ldb_part_block_mapped(const struct ldb_table *t, uint64_t pb)
{
	return pb < (uint64_t)-1 - t->part_first && ldb_lba_allowed(t, t->part_first + pb, 1);
}

/* Reasons a header does not fit this table. State BOUND only. */
static inline const char *
ldb_header_check(const struct ldb_header *h, const struct ldb_table *t)
{
	for (unsigned i = 0; i < 8; i++) {
		if (h->magic[i] != LDB_HDR_MAGIC[i]) {
			return "no header in the mapped area (not installed, or the blocks now hold something else)";
		}
	}
	if (h->version != LDB_HDR_VERSION || ldb_header_hash(h) != h->hash) {
		return "area header damaged";
	}
	if (h->table_id != t->table_id || h->table_hash != t->hash || h->area_blocks != t->area_blocks) {
		return "area header is for another table (rebuild the boot image)";
	}
	if (h->state != LDB_STATE_BOUND) {
		return "area is not sealed";
	}
	for (unsigned i = 0; i < LDB_FP_BLOCKS; i++) {
		if (h->fp_part_block[i] >= t->part_blocks || ldb_part_block_mapped(t, h->fp_part_block[i])) {
			return "fingerprint block outside userdata or inside the area";
		}
	}
	return NULL;
}

/* One piece of a request at byte position pos on the BSD disk (no reserved blocks counted): clamp it to one extent. See sweet_ufs_strategy. */
static inline int
ldb_piece(const struct ldb_table *t, uint64_t disk_block, uint32_t skip, uint32_t *want, uint32_t *blocks, uint64_t *lba)
{
	uint32_t run = 0;

	if (ldb_map(t, disk_block + t->reserved_blocks, *blocks, lba, &run) != 0) {
		return -1;
	}
	if (run < *blocks) {
		*blocks = run;
		*want = run * LDB_BLOCK - skip;
	}
	return 0;
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
