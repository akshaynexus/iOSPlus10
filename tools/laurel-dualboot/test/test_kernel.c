/*
 * Host test of the dual boot in the real driver: the patched bsd/dev/sweet_ufs.c is #included, its ufs_scsi is replaced by a RAM disk. Each case boots
 * sweet_ufs_init on a disk image with a GPT, an f2fs-like userdata and a fragmented area. What is proven: the mapping, the fence, the self-checks, and in every
 * failure: not one block of the disk changed. Not proven: anything about the phone.
 */
#include "fake_xnu.h"

/* ---- RAM disk behind a fake SCSI layer ---- */
#define DISK_BLOCKS  260000u
#define PART_FIRST   0x1000u
#define PART_BLOCKS  200000u
#define GPT_ALT      (DISK_BLOCKS - 1)
static uint8_t *disk;
static uint64_t writes, sync_count;
static int fake_scsi(const uint8_t *cdb, uint8_t lun, uint32_t len, bool write, uint8_t *bounce);

#include "sweet_ufs_host.c"

/* The driver calls this one: test-dualboot.sh renames the real ufs_scsi to ufs_scsi_hw and the calls to ufs_scsi_fake. */
static int
ufs_scsi_fake(const uint8_t *cdb, unsigned cdb_len, uint32_t len, bool write)
{
	(void)cdb_len;
	return fake_scsi(cdb, su.lun, len, write, (uint8_t *)(su.dma + DMA_BOUNCE));
}

static int
fake_scsi(const uint8_t *cdb, uint8_t lun, uint32_t len, bool write, uint8_t *bounce)
{
	if (cdb[0] == 0x00) {
		return 0;
	}
	if (cdb[0] == 0x35) {
		sync_count++;
		return 0;
	}
	if (cdb[0] != 0x28 && cdb[0] != 0x2a) {
		printf("fake scsi: unexpected command 0x%02x\n", cdb[0]);
		abort();
	}
	if (lun != 0) {
		return EIO;                     /* the other LUNs have no GPT here */
	}
	uint64_t lba = (uint64_t)cdb[2] << 24 | cdb[3] << 16 | cdb[4] << 8 | cdb[5];
	uint32_t count = (uint32_t)cdb[7] << 8 | cdb[8];
	assert(count * 4096u == len);
	if (lba + count > DISK_BLOCKS) {
		return EIO;
	}
	if (cdb[0] == 0x2a) {
		assert(write);
		memcpy(disk + lba * 4096, bounce, len);
		writes += count;
	} else {
		assert(!write);
		memcpy(bounce, disk + lba * 4096, len);
	}
	return 0;
}

/* ---- the fake machine ---- */
static const void *adt_table;
static unsigned adt_table_size;
static int arg_ufsrw = 1, arg_dualboot = -1;
static int restarts;
static jmp_buf log_out;
static int log_rounds;
pmap_t kernel_pmap;
void *kernel_map;

int SecureDTLookupEntry(void *p, const char *path, DTEntry *e) { (void)p; *e = (void *)path; return 0; }
static uint64_t ufs_reg[2] = { 0x4804000, 0x20000 };
int
SecureDTGetProperty(DTEntry e, const char *name, void const **v, unsigned int *sz)
{
	if (strcmp((const char *)e, "/sweet-ufs") == 0 && strcmp(name, "reg") == 0) {
		*v = ufs_reg;
		*sz = sizeof(ufs_reg);
		return 0;
	}
	if (strcmp((const char *)e, "/chosen") == 0 && strcmp(name, "laurel-dualboot") == 0 && adt_table != NULL) {
		*v = adt_table;
		*sz = adt_table_size;
		return 0;
	}
	return 1;
}
bool
PE_parse_boot_argn(const char *n, void *out, int len)
{
	if (strcmp(n, "ufsrw") == 0) {
		*(uint32_t *)out = (uint32_t)arg_ufsrw;
		return true;
	}
	if (strcmp(n, "laureldualboot") == 0 && arg_dualboot >= 0) {
		*(uint32_t *)out = (uint32_t)arg_dualboot;
		return true;
	}
	(void)len;
	return false;
}
void lck_mtx_lock(int *m) { (void)m; }
void lck_mtx_unlock(int *m) { (void)m; }
static uint32_t regs[0x10000 / 4], gcc[0x1000 / 4];
vm_offset_t
ml_io_map(vm_offset_t pa, vm_size_t size)
{
	(void)size;
	if (pa == 0x01400000 + 0x45000) {
		gcc[1] = 1u << 31;              /* GDSCR powered; clocks on (bit 31 of CBCR clear) */
		return (vm_offset_t)gcc;
	}
	regs[0x34 / 4] = 1;                     /* HCE */
	regs[0x30 / 4] = 3;                     /* DP + UTRLRDY */
	return (vm_offset_t)regs;
}
int
kmem_alloc_contig(void *m, vm_offset_t *a, size_t sz, unsigned long mask, ppnum_t max, int b, int c, int d)
{
	(void)m; (void)mask; (void)max; (void)b; (void)c; (void)d;
	*a = (vm_offset_t)aligned_alloc(4096, (sz + 4095) & ~4095ul);
	memset((void *)*a, 0, sz);
	return 0;
}
ppnum_t pmap_find_phys(pmap_t p, addr64_t va) { (void)p; (void)va; return 1; }
int bdevsw_add(int i, const struct bdevsw *b) { (void)i; (void)b; return 1; }
int cdevsw_add_with_bdev(int i, const struct cdevsw *c, int m) { (void)i; (void)c; (void)m; return 1; }
void *devfs_make_node(dev_t d, int t, int u, int g, int p, const char *f, ...) { (void)d; (void)t; (void)u; (void)g; (void)p; (void)f; return NULL; }
int
tsleep(void *c, int p, const char *w, int t)
{
	(void)c; (void)p; (void)w; (void)t;
	if (log_rounds-- <= 0) {
		longjmp(log_out, 1);
	}
	return 0;
}
int hz = 100;
uint64_t mach_absolute_time(void) { static uint64_t t; return ++t; }
void nanoseconds_to_absolutetime(uint64_t n, uint64_t *o) { *o = n; }
void absolutetime_to_nanoseconds(uint64_t n, uint64_t *o) { *o = n; }
void clock_interval_to_deadline(unsigned a, unsigned long long b, uint64_t *c) { (void)a; (void)b; *c = 0; }
int assert_wait_deadline(void *e, int i, uint64_t d) { (void)e; (void)i; (void)d; return 0; }
int assert_wait_deadline_with_leeway(void *e, int i, int u, uint64_t d, uint64_t l) { (void)e; (void)i; (void)u; (void)d; (void)l; return 0; }
void thread_block(void *c) { (void)c; }
void delay(int d) { (void)d; }
bool ml_get_interrupts_enabled(void) { return true; }
bool ml_at_interrupt_context(void) { return false; }
int get_preemption_level(void) { return 0; }
void flush_dcache64(addr64_t a, unsigned l, int p) { (void)a; (void)l; (void)p; }
void clean_dcache64(addr64_t a, unsigned l, int p) { (void)a; (void)l; (void)p; }
int physio(void (*s)(buf_t), void *b, dev_t d, int f, void *m, struct uio *u, int z) { (void)s; (void)b; (void)d; (void)f; (void)m; (void)u; (void)z; return 0; }
void minphys(void) {}
int kernel_thread_start(thread_continue_t f, void *a, thread_t *t) { (void)f; (void)a; *t = NULL; return 0; }
void thread_deallocate(thread_t t) { (void)t; }
void sweet_sample_start(void) {}
void sweet_keys_init(void) {}
void sweet_touch_init(void) {}
void sweet_usb_probe(void) {}
void laurel_stats_scan(void) {}
void IOSleep(unsigned int ms) { (void)ms; }
int PEHaltRestart(unsigned int t) { assert(t == 1); restarts++; return 0; }

/* ---- the test ---- */
static int fails, passes;
#define CHECK(c, ...) do { if (c) { passes++; } else { fails++; printf("FAIL %s:%d: ", __func__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

static uint64_t rng = 88172645463325252ull;
static uint64_t
rnd(void)
{
	rng ^= rng << 13;
	rng ^= rng >> 7;
	rng ^= rng << 17;
	return rng;
}
static void
wr_be32(uint8_t *p, uint32_t v)
{
	p[0] = (uint8_t)(v >> 24); p[1] = (uint8_t)(v >> 16); p[2] = (uint8_t)(v >> 8); p[3] = (uint8_t)v;
}

/* A fragmented area, like a pinned allocation with neighbours: not sorted by partition block, some splits not 2 MiB aligned for the tests. */
static const struct ldb_extent EXT[] = {
	{ 0,      70000,  512 },
	{ 512,    40000,  3584 },
	{ 4096,   2048,   1 },                  /* a one-block extent */
	{ 4097,   90000,  7903 },
	{ 12000,  30000,  2 },
	{ 12002,  120000, 12000 },
};
#define EXT_N (sizeof(EXT) / sizeof(EXT[0]))
#define AREA_BLOCKS 24002u
static uint64_t table_mem[(sizeof(struct ldb_table) + EXT_N * sizeof(struct ldb_extent)) / 8 + 1];
static struct ldb_table *TB;
static const uint64_t FP[3] = { 0, 512, 1024 };

static void
hash_table(void)
{
	TB->hash = 0;
	TB->hash = ldb_table_hash(table_mem, sizeof(*TB) + TB->count * sizeof(struct ldb_extent));
}
static void
make_table(void)
{
	TB = (struct ldb_table *)table_mem;
	memset(table_mem, 0, sizeof(table_mem));
	memcpy(TB->magic, LDB_TABLE_MAGIC, 8);
	TB->version = LDB_VERSION;
	TB->block_size = LDB_BLOCK;
	TB->count = EXT_N;
	TB->reserved_blocks = LDB_RESERVED_BLOCKS;
	TB->part_first = PART_FIRST;
	TB->part_blocks = PART_BLOCKS;
	TB->area_blocks = AREA_BLOCKS;
	TB->table_id = 0x1234567890abcdefull;
	memcpy((void *)(TB + 1), EXT, sizeof(EXT));
	hash_table();
}
static void
gpt(void)
{
	uint8_t *h = disk + 4096;
	memcpy(h, "EFI PART", 8);
	uint64_t alt = GPT_ALT, ent = 2;
	uint32_t nent = 8, esz = 128;
	memcpy(h + 32, &alt, 8);
	memcpy(h + 72, &ent, 8);
	memcpy(h + 80, &nent, 4);
	memcpy(h + 84, &esz, 4);
	uint8_t *e = disk + 2 * 4096;
	memset(e, 0, 8 * 128);
	const char *name = "userdata";
	for (unsigned i = 0; name[i]; i++) {
		e[56 + 2 * i] = (uint8_t)name[i];
	}
	uint64_t first = PART_FIRST, last = PART_FIRST + PART_BLOCKS - 1;
	memcpy(e + 32, &first, 8);
	memcpy(e + 40, &last, 8);
	memcpy(disk + GPT_ALT * 4096, "EFI PART", 8);
}
/* The state of the phone after an install and a seal. */
static void
fresh_disk(uint32_t hfs_blocks, unsigned state)
{
	for (uint64_t i = 0; i < DISK_BLOCKS * 4096ull / 8; i++) {
		((uint64_t *)disk)[i] = i * 0x9e3779b97f4a7c15ull;      /* "Android's ciphertext": nothing is zero */
	}
	gpt();
	make_table();
	uint64_t lba;
	uint32_t run;
	CHECK(ldb_map(TB, LDB_RESERVED_BLOCKS, 1, &lba, &run) == 0, "map root");
	uint8_t *v = disk + lba * 4096 + 1024;
	memset(v, 0, 512);
	v[0] = 'H'; v[1] = 'X'; v[3] = 5;
	wr_be32(v + 40, 4096);
	wr_be32(v + 44, hfs_blocks);
	struct ldb_header h;
	memset(&h, 0, sizeof(h));
	memcpy(h.magic, LDB_HDR_MAGIC, 8);
	h.version = LDB_VERSION;
	h.state = state;
	h.table_id = TB->table_id;
	h.table_hash = TB->hash;
	h.area_blocks = AREA_BLOCKS;
	h.seal_generation = 1;
	memcpy(h.fp_part_block, FP, sizeof(FP));
	h.hash = ldb_header_hash(&h);
	CHECK(ldb_map(TB, 0, 1, &lba, &run) == 0, "map header");
	memset(disk + lba * 4096, 0, 4096);
	memcpy(disk + lba * 4096, &h, sizeof(h));
}
static void
reset_driver(void)
{
	memset(&su, 0, sizeof(su));
	memset(&ldb, 0, sizeof(ldb));
	laurel_dualboot_on = 0;
	part_cached = 0;
	gpt_alt = 0;
	writes = sync_count = 0;
	restarts = 0;
	arg_ufsrw = 1;
	arg_dualboot = -1;
	adt_table = table_mem;
	adt_table_size = sizeof(*TB) + TB->count * sizeof(struct ldb_extent);
}
static uint64_t
disk_hash(void)
{
	return ldb_hash_add(LDB_HASH_INIT, disk, DISK_BLOCKS * 4096ull);
}

/* Each way the self-check must say no: reason line, error, no write, disk identical, restart asked, nothing registered. */
static void
expect_off(const char *name, const char *reason_part)
{
	uint64_t before = disk_hash();
	dev_t dev = 0;
	int e = sweet_ufs_rootdev(&dev);
	CHECK(e != 0, "%s: rootdev gave a root", name);
	CHECK(writes == 0, "%s: %llu blocks written", name, (unsigned long long)writes);
	CHECK(before == disk_hash(), "%s: the disk changed", name);
	CHECK(!su.ready && !su.writable, "%s: driver ready or writable", name);
	CHECK(laurel_dualboot_on == 0, "%s: sysctl says on", name);
	CHECK(restarts == 1, "%s: %d restarts", name, restarts);
	CHECK(ldb.why != NULL && strstr(ldb.why, reason_part) != NULL, "%s: reason '%s'", name, ldb.why ? ldb.why : "(none)");
	/* the fence is shut also for a direct call: a stray writer gets nothing */
	su.writable = true;
	memset((void *)(su.dma + DMA_BOUNCE), 0xee, 4096);
	CHECK(ufs_write_blocks(PART_FIRST + 70000, 1) == EPERM, "%s: fence open", name);
	su.writable = false;
	CHECK(before == disk_hash(), "%s: stray write", name);
	printf("ok   %s\n", name);
}

static void
test_table_rules(void)
{
	make_table();
	uint64_t len = sizeof(*TB) + TB->count * sizeof(struct ldb_extent);
	CHECK(ldb_table_check(table_mem, len) == NULL, "good table: %s", ldb_table_check(table_mem, len));
	CHECK(ldb_table_check(table_mem, len - 1) != NULL, "short");
	CHECK(ldb_table_check(NULL, len) != NULL, "null");
	/* every byte matters */
	for (uint64_t i = 0; i < len; i++) {
		((uint8_t *)table_mem)[i] ^= 0x10;
		CHECK(ldb_table_check(table_mem, len) != NULL, "byte %llu flipped", (unsigned long long)i);
		((uint8_t *)table_mem)[i] ^= 0x10;
	}
	struct ldb_extent *e = (struct ldb_extent *)(TB + 1);
#define BAD(setup, want) do { make_table(); e = (struct ldb_extent *)(TB + 1); setup; hash_table(); \
	    const char *w = ldb_table_check(table_mem, len); CHECK(w != NULL && strstr(w, want), "%s -> %s", #setup, w ? w : "accepted"); } while (0)
	BAD(e[1].part_block = 70100, "overlap");
	BAD(e[3].part_block = 39000, "overlap");
	BAD(e[5].part_block = PART_BLOCKS - 100, "outside");
	BAD(e[5].part_block = PART_BLOCKS, "outside");
	BAD(e[2].part_block = 100, "outside");
	BAD(e[1].part_block = (uint64_t)-1 - 10, "outside");
	BAD(e[1].blocks = 0, "contiguous");
	BAD(e[2].area_block = 4097, "contiguous");
	BAD(e[5].blocks = 11999, "shorter");
	BAD(e[5].blocks = 12001, "longer");
	BAD(TB->area_blocks = PART_BLOCKS + 1, "area size");
	BAD(TB->area_blocks = LDB_RESERVED_BLOCKS, "area size");
	BAD(TB->part_first = 0, "partition");
	BAD(TB->reserved_blocks = 0, "reserved");
	BAD(TB->block_size = 512, "block size");
	BAD(TB->version = 2, "version");
	BAD(TB->magic[0] = 'X', "magic");
	make_table();
	/* mapping and fence, every block of the area against the plain table */
	for (uint64_t ab = 0; ab < AREA_BLOCKS; ab++) {
		uint64_t lba = 0, want = 0;
		uint32_t run = 0, left = 0;
		for (unsigned i = 0; i < EXT_N; i++) {
			if (ab >= EXT[i].area_block && ab < EXT[i].area_block + EXT[i].blocks) {
				want = PART_FIRST + EXT[i].part_block + (ab - EXT[i].area_block);
				left = (uint32_t)(EXT[i].blocks - (ab - EXT[i].area_block));
			}
		}
		int r = ldb_map(TB, ab, 0xffffffffu, &lba, &run);
		if (r != 0 || lba != want || run != left || !ldb_lba_allowed(TB, lba, run) || ldb_lba_allowed(TB, lba, run + 1)) {
			CHECK(0, "area block %llu", (unsigned long long)ab);
		}
	}
	passes++;
	uint64_t lba;
	uint32_t run;
	CHECK(ldb_map(TB, AREA_BLOCKS, 1, &lba, &run) != 0, "past the end");
	CHECK(ldb_map(TB, 0, 0, &lba, &run) != 0, "zero blocks");
	CHECK(!ldb_lba_allowed(TB, PART_FIRST + 70000 - 1, 1), "before an extent");
	CHECK(!ldb_lba_allowed(TB, PART_FIRST + 70000 + 512, 1), "after an extent");
	CHECK(!ldb_lba_allowed(TB, PART_FIRST + 70000 - 1, 2), "half before");
	CHECK(!ldb_lba_allowed(TB, PART_FIRST + 70000 + 511, 2), "half after");
	CHECK(!ldb_lba_allowed(TB, 0, 1), "LBA 0");
	CHECK(!ldb_lba_allowed(TB, PART_FIRST - 1, 1), "before userdata");
	CHECK(!ldb_lba_allowed(TB, PART_FIRST + PART_BLOCKS, 1), "after userdata");
	CHECK(!ldb_lba_allowed(TB, (uint64_t)-2, 8), "wrap");
	CHECK(!ldb_lba_allowed(TB, PART_FIRST + 70000, 0), "zero");
	printf("ok   table rules, map and fence on every area block\n");
}

static void
test_on(void)
{
	/* volume: all that fits */
	uint32_t hfs = AREA_BLOCKS - LDB_RESERVED_BLOCKS - SWEET_LOG_BLOCKS;
	fresh_disk(hfs, LDB_STATE_FRESH);
	reset_driver();
	uint8_t *shadow = calloc(1, (AREA_BLOCKS - LDB_RESERVED_BLOCKS) * 4096ull);
	uint8_t *before = malloc(DISK_BLOCKS * 4096ull);
	memcpy(before, disk, DISK_BLOCKS * 4096ull);
	dev_t dev = 0;
	CHECK(sweet_ufs_rootdev(&dev) == 0, "first boot: no root: %s", ldb.why ? ldb.why : "");
	if (!ldb.on) {
		return;
	}
	CHECK(su.ready && su.writable && ldb.on && laurel_dualboot_on == 1, "first boot state");
	CHECK(su.nblocks == AREA_BLOCKS - LDB_RESERVED_BLOCKS, "BSD disk size");
	CHECK(restarts == 0, "restart");
	/* the bind: only the header block changed */
	struct ldb_header h;
	uint64_t hdr_lba;
	uint32_t run;
	ldb_map(TB, 0, 1, &hdr_lba, &run);
	memcpy(&h, disk + hdr_lba * 4096, sizeof(h));
	CHECK(h.state == LDB_STATE_BOUND && ldb_header_check(&h, TB) == NULL, "header after bind");
	CHECK(writes == 1, "bind wrote %llu blocks", (unsigned long long)writes);
	for (unsigned i = 0; i < LDB_FP_BLOCKS; i++) {
		CHECK(h.fp_hash[i] == ldb_hash_add(LDB_HASH_INIT, disk + (PART_FIRST + FP[i]) * 4096, 4096), "fingerprint %u", i);
	}
	/* shadow = what the BSD disk must read */
	for (uint64_t b = 0; b < AREA_BLOCKS - LDB_RESERVED_BLOCKS; b++) {
		uint64_t lba;
		ldb_map(TB, b + LDB_RESERVED_BLOCKS, 1, &lba, &run);
		memcpy(shadow + b * 4096, disk + lba * 4096, 4096);
	}
	/* random I/O through the real strategy: 512-byte units, any size, across extents and past the end */
	uint32_t ios = 0, rejected = 0;
	char *data = malloc(4u << 20), *back = malloc(4u << 20);
	for (int i = 0; i < 40000; i++) {
		uint32_t secs = (rnd() % 8 == 0) ? (uint32_t)(rnd() % 8192 + 1) : (uint32_t)(rnd() % 64 + 1);
		uint64_t total_secs = su.nblocks * 8;
		/* near the extent ends more often: those are the hard cases */
		uint64_t at;
		if (rnd() % 2) {
			const struct ldb_extent *x = &EXT[rnd() % EXT_N];
			int64_t c = (int64_t)(x->area_block + x->blocks) - LDB_RESERVED_BLOCKS;
			at = (uint64_t)(c < 1 ? 0 : c * 8 - (int64_t)(rnd() % 32));
		} else {
			at = rnd() % total_secs;
		}
		bool wr = rnd() % 2;
		struct fake_buf b = { .blkno = (int64_t)at, .count = secs * 512, .flags = wr ? B_WRITE : B_READ, .data = wr ? data : back };
		if (wr) {
			for (uint32_t k = 0; k + 8 <= b.count; k += 8) {
				uint64_t v = rnd();
				memcpy(data + k, &v, 8);
			}
		}
		sweet_ufs_strategy(&b);
		CHECK(b.done == 1, "biodone");
		if (at + secs > total_secs) {
			if (b.error != EINVAL) {
				CHECK(0, "I/O past the end: error %d", b.error);
			}
			rejected++;
			continue;
		}
		if (b.error != 0 || b.resid != 0) {
			CHECK(0, "I/O at sector %llu, %u sectors: error %d resid %u", (unsigned long long)at, secs, b.error, b.resid);
			continue;
		}
		if (wr) {
			memcpy(shadow + at * 512, data, b.count);
		} else if (memcmp(back, shadow + at * 512, b.count) != 0) {
			CHECK(0, "read at sector %llu, %u sectors: wrong bytes", (unsigned long long)at, secs);
		}
		ios++;
	}
	/* the console log: real thread body, several flushes, with wrap */
	for (int round = 0; round < 3; round++) {
		char line[4096];
		memset(line, 'a' + round, sizeof(line));
		for (int k = 0; k < 1500; k++) {
			sweet_log_append(line, sizeof(line));
		}
		log_rounds = 2;
		if (setjmp(log_out) == 0) {
			sweet_log_thread(NULL, 0);
		}
	}
	/* the outcome that matters: outside the table not one byte changed; inside it all is as the shadow says */
	uint8_t *mask = calloc(DISK_BLOCKS, 1);
	for (unsigned i = 0; i < EXT_N; i++) {
		memset(mask + PART_FIRST + EXT[i].part_block, 1, EXT[i].blocks);
	}
	uint64_t changed_outside = 0;
	for (uint64_t b = 0; b < DISK_BLOCKS; b++) {
		if (!mask[b] && memcmp(disk + b * 4096, before + b * 4096, 4096) != 0) {
			changed_outside++;
		}
	}
	CHECK(changed_outside == 0, "%llu blocks outside the table changed", (unsigned long long)changed_outside);
	/* the log area lies in the last area blocks; the log header carries its magic */
	uint64_t log_base = su.nblocks - SWEET_LOG_BLOCKS, lba;
	ldb_map(TB, log_base + LDB_RESERVED_BLOCKS, 1, &lba, &run);
	CHECK(memcmp(disk + lba * 4096, "SWEETLOG", 8) == 0, "no log header at the end of the area");
	/* the HFS part reads back identical from the disk */
	uint64_t wrong = 0;
	for (uint64_t b = 0; b < log_base; b++) {
		ldb_map(TB, b + LDB_RESERVED_BLOCKS, 1, &lba, &run);
		if (memcmp(disk + lba * 4096, shadow + b * 4096, 4096) != 0) {
			wrong++;
		}
	}
	CHECK(wrong == 0, "%llu blocks of the disk differ from the shadow", (unsigned long long)wrong);
	printf("ok   on: bind, %u I/Os + %u refused past the end through sweet_ufs_strategy, log thread; 0 blocks outside the table changed\n", ios, rejected);

	/* fence, called directly with every kind of bad address */
	memset((void *)(su.dma + DMA_BOUNCE), 0xee, 8192);
	uint64_t h0 = disk_hash();
	static const struct { uint64_t lba; uint32_t n; const char *what; } bad[] = {
		{ 0, 1, "LBA 0" }, { 1, 1, "GPT header" }, { 2, 1, "GPT entries" }, { PART_FIRST - 1, 1, "before userdata" },
		{ PART_FIRST, 1, "f2fs superblock" }, { PART_FIRST + 512, 1, "f2fs checkpoint" },
		{ PART_FIRST + 70000 - 1, 2, "half before an extent" }, { PART_FIRST + 70000 + 511, 2, "half after an extent" },
		{ PART_FIRST + PART_BLOCKS - 1, 1, "end of userdata, where the log used to go" }, { PART_FIRST + PART_BLOCKS - 1025, 1, "old log block" },
		{ GPT_ALT, 1, "backup GPT" }, { 1ull << 40, 1, "far away" },
	};
	for (unsigned i = 0; i < sizeof(bad) / sizeof(bad[0]); i++) {
		CHECK(ufs_write_blocks(bad[i].lba, bad[i].n) == EPERM, "fence let through: %s", bad[i].what);
	}
	/* good address, wrong LUN */
	su.lun = 1;
	CHECK(ufs_write_blocks(PART_FIRST + 70000, 1) == EPERM, "fence on LUN 1");
	su.lun = 0;
	CHECK(disk_hash() == h0, "fence: the disk changed");
	/* the same blocks inside an extent pass */
	CHECK(ufs_write_blocks(PART_FIRST + 70000 + 511, 1) == 0, "good block refused");
	printf("ok   fence: %zu bad addresses refused directly, wrong LUN refused, a good block passes\n", sizeof(bad) / sizeof(bad[0]));

	/* second boot: BOUND, nothing changed: on, no bind, no write */
	memcpy(&h, disk + hdr_lba * 4096, sizeof(h));
	reset_driver();
	CHECK(sweet_ufs_rootdev(&dev) == 0, "second boot: %s", ldb.why ? ldb.why : "");
	CHECK(ldb.on && writes == 0, "second boot wrote %llu", (unsigned long long)writes);
	printf("ok   second boot: on, no write\n");

	/* Android ran: its checkpoint changed. Each of the three blocks. */
	for (unsigned i = 0; i < 3; i++) {
		uint64_t b = (PART_FIRST + FP[i]) * 4096 + 77;
		disk[b] ^= 1;
		reset_driver();
		char name[64];
		snprintf(name, sizeof(name), "fingerprint block %u changed", i);
		expect_off(name, "Android ran");
		disk[b] ^= 1;
	}
	/* read-only boot of a FRESH area: no bind, no write at all */
	fresh_disk(hfs, LDB_STATE_FRESH);
	reset_driver();
	arg_ufsrw = 0;
	uint64_t d0 = disk_hash();
	CHECK(sweet_ufs_rootdev(&dev) == 0 && ldb.on && !su.writable && writes == 0 && disk_hash() == d0, "ufsrw=0");
	struct fake_buf b = { .blkno = 0, .count = 4096, .flags = B_WRITE, .data = data };
	sweet_ufs_strategy(&b);
	CHECK(b.error == EROFS && disk_hash() == d0, "write in a read-only boot");
	printf("ok   ufsrw=0: on, read-only, no write\n");
	free(shadow); free(before); free(mask); free(data); free(back);
}

static void
test_off(void)
{
	uint32_t hfs = 4096;
#define CASE(name, setup, reason) do { fresh_disk(hfs, LDB_STATE_FRESH); reset_driver(); setup; if (adt_table == table_mem && TB->hash != 0) { adt_table_size = sizeof(*TB) + TB->count * sizeof(struct ldb_extent); } expect_off(name, reason); } while (0)
	uint64_t lba;
	uint32_t run;
	CASE("kill switch laureldualboot=0", arg_dualboot = 0, "laureldualboot=0");
	CASE("table damaged", ((uint8_t *)table_mem)[100] ^= 1, "hash");
	CASE("table with an extent less", TB->count = 5; hash_table(), "shorter");
	CASE("table of another partition first", TB->part_first = PART_FIRST + 8; hash_table(), "GPT");
	CASE("table of another partition size", TB->part_blocks = PART_BLOCKS - 8; hash_table(), "GPT");
	ldb_map(TB, 0, 1, &lba, &run);
	CASE("no header: file never installed", memset(disk + lba * 4096, 0, 4096), "no header");
	CASE("header damaged", disk[lba * 4096 + 40] ^= 1, "damaged");
	CASE("header of another table (file allocated again, old boot image)", TB->table_id ^= 1; hash_table(), "another table");
	CASE("header not sealed", { struct ldb_header h; memcpy(&h, disk + lba * 4096, sizeof(h)); h.state = 7; h.hash = ldb_header_hash(&h); memcpy(disk + lba * 4096, &h, sizeof(h)); }, "not sealed");
	CASE("fingerprint block inside the area", { struct ldb_header h; memcpy(&h, disk + lba * 4096, sizeof(h)); h.fp_part_block[1] = 70000; h.hash = ldb_header_hash(&h); memcpy(disk + lba * 4096, &h, sizeof(h)); }, "fingerprint");
	CASE("fingerprint block outside userdata", { struct ldb_header h; memcpy(&h, disk + lba * 4096, sizeof(h)); h.fp_part_block[2] = PART_BLOCKS; h.hash = ldb_header_hash(&h); memcpy(disk + lba * 4096, &h, sizeof(h)); }, "fingerprint");
	ldb_map(TB, LDB_RESERVED_BLOCKS, 1, &lba, &run);
	CASE("no HFS+ in the area", memset(disk + lba * 4096 + 1024, 0x5a, 512), "HFS+");
	CASE("HFS+ longer than the area", wr_be32(disk + lba * 4096 + 1024 + 44, AREA_BLOCKS), "longer");
	CASE("HFS+ over the console log", wr_be32(disk + lba * 4096 + 1024 + 44, AREA_BLOCKS - LDB_RESERVED_BLOCKS - SWEET_LOG_BLOCKS + 1), "longer");
	fresh_disk(hfs, LDB_STATE_FRESH);
	reset_driver();
	adt_table_size = 10;
	expect_off("table property too short", "size out of range");
	fresh_disk(hfs, LDB_STATE_FRESH);
	reset_driver();
	adt_table_size = 200000;
	expect_off("table property too long", "size out of range");
	/* a boot image without a table on a phone with Android: the old kernel wrote its log into the last 4 MiB of /data here */
	fresh_disk(hfs, LDB_STATE_FRESH);
	reset_driver();
	adt_table = NULL;
	expect_off("no table, no HFS+ at the start of userdata (Android)", "no extent table");

	/* single boot still works: no table, HFS+ at the start of the partition; log at the partition end, writes anywhere in the partition, not outside */
	fresh_disk(hfs, LDB_STATE_FRESH);
	reset_driver();
	adt_table = NULL;
	uint8_t *v = disk + PART_FIRST * 4096ull + 1024;
	v[0] = 'H'; v[1] = '+'; v[2] = 0; v[3] = 4;
	wr_be32(v + 40, 4096);
	wr_be32(v + 44, 1000);
	dev_t dev = 0;
	CHECK(sweet_ufs_rootdev(&dev) == 0 && !ldb.present && !ldb.on, "single boot: %s", ldb.why ? ldb.why : "");
	CHECK(su.first_block == PART_FIRST && su.nblocks == PART_BLOCKS, "single boot geometry");
	CHECK(ufs_write_blocks(PART_FIRST + PART_BLOCKS - 1, 1) == 0, "single boot: last block");
	CHECK(ufs_write_blocks(PART_FIRST + PART_BLOCKS, 1) == EPERM, "single boot: past the partition");
	CHECK(ufs_write_blocks(PART_FIRST - 1, 1) == EPERM, "single boot: before the partition");
	printf("ok   single boot with HFS+ works as before\n");
}

int
main(void)
{
	setvbuf(stdout, NULL, _IONBF, 0);
	disk = malloc(DISK_BLOCKS * 4096ull);
	test_table_rules();
	test_on();
	test_off();
	printf("test_kernel: %d checks passed, %d failed\n", passes, fails);
	return fails ? 1 : 0;
}
