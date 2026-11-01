/*
 * Host test of the dual boot in the real driver: the patched bsd/dev/sweet_ufs.c is #included, its ufs_scsi is replaced by a RAM disk. Each case runs sweet_ufs_init on a disk
 * image with a GPT in the layout of the plan. What is proven: 0 blocks outside iosroot change under random I/O and the log thread; the fence; each unexpected GPT gives off, no
 * write, a restart. Not proven: anything about the phone.
 */
#include "fake_xnu.h"

/* ---- RAM disk behind a fake SCSI layer ---- */
#define DISK_BLOCKS  260000u
#define GPT_ALT      (DISK_BLOCKS - 1)
#define LAST_USABLE  (DISK_BLOCKS - 6)
#define IOS_FIRST    128000u                 /* 250 x 2 MiB */
#define IOS_BLOCKS   (LAST_USABLE - IOS_FIRST + 1)
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
static void
wr64(uint8_t *p, uint64_t v)
{
	memcpy(p, &v, 8);
}
static void
wr32(uint8_t *p, uint32_t v)
{
	memcpy(p, &v, 4);
}
static uint8_t *
ent(unsigned i)
{
	return disk + 2 * 4096 + i * 128;
}
static uint8_t *
bent(unsigned i)
{
	return disk + (DISK_BLOCKS - 5) * 4096 + i * 128;
}
static uint8_t *
hdr(void)
{
	return disk + 4096;
}
static uint8_t *
bhdr(void)
{
	return disk + GPT_ALT * 4096;
}
static void
set_name(uint8_t *e, const char *n)
{
	memset(e + 56, 0, 72);
	for (unsigned i = 0; n[i]; i++) {
		e[56 + 2 * i] = (uint8_t)n[i];
	}
}
static void
set_ent(unsigned i, const char *n, uint64_t a, uint64_t b)
{
	uint8_t *e = ent(i);
	memset(e, 0, 128);
	memset(e, (int)i + 1, 32);
	set_name(e, n);
	wr64(e + 32, a);
	wr64(e + 40, b);
}
/* the backup entries become a copy of the primary ones; both CRCs and both header CRCs right */
static void
seal_gpt(void)
{
	memcpy(bent(0), ent(0), 32 * 128);
	uint32_t c = ldb_crc32(ent(0), 32 * 128, 0xffffffffu);
	for (unsigned i = 0; i < 2; i++) {
		uint8_t *h = i ? bhdr() : hdr();
		wr32(h + 88, c);
		wr32(h + 16, 0);
		wr32(h + 16, ldb_crc32(h, 92, 16));
	}
}
static void
gpt(void)
{
	for (unsigned i = 0; i < 2; i++) {
		uint8_t *h = i ? bhdr() : hdr();
		memset(h, 0, 4096);
		memcpy(h, "EFI PART", 8);
		wr32(h + 8, 0x10000);
		wr32(h + 12, 92);
		wr64(h + 24, i ? GPT_ALT : 1);
		wr64(h + 32, i ? 1 : GPT_ALT);
		wr64(h + 40, 6);
		wr64(h + 48, LAST_USABLE);
		memset(h + 56, 9, 16);
		wr64(h + 72, i ? DISK_BLOCKS - 5 : 2);
		wr32(h + 80, 32);
		wr32(h + 84, 128);
	}
	memset(ent(0), 0, 4 * 4096);
	memset(bent(0), 0, 4 * 4096);
	uint64_t a = 6;
	char n[8];
	for (unsigned i = 0; i < 13; i++) {
		snprintf(n, sizeof(n), "p%u", i);
		set_ent(i, n, a, a + 99);
		a += 100;
	}
	set_ent(13, "metadata", a, a + 99);
	set_ent(14, "userdata", a + 100, IOS_FIRST - 1);
	set_ent(15, LDB_ROOT_NAME, IOS_FIRST, LAST_USABLE);
	seal_gpt();
}
static void
fresh_disk(uint32_t hfs_blocks)
{
	for (uint64_t i = 0; i < DISK_BLOCKS * 4096ull / 8; i++) {
		((uint64_t *)disk)[i] = i * 0x9e3779b97f4a7c15ull;      /* "Android's ciphertext": nothing is zero */
	}
	gpt();
	uint8_t *v = disk + IOS_FIRST * 4096ull + 1024;
	memset(v, 0, 512);
	v[0] = 'H'; v[1] = 'X'; v[3] = 5;
	wr_be32(v + 40, 4096);
	wr_be32(v + 44, hfs_blocks);
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
}
static uint64_t
disk_hash(void)
{
	uint64_t h = 0xcbf29ce484222325ull;
	for (uint64_t i = 0; i < DISK_BLOCKS * 4096ull / 8; i++) {
		h = (h ^ ((uint64_t *)disk)[i]) * 0x100000001b3ull;
	}
	return h;
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
	CHECK(!su.ready && !su.writable && !ldb.on, "%s: driver ready or writable", name);
	CHECK(laurel_dualboot_on == 0, "%s: sysctl says on", name);
	CHECK(restarts == 1, "%s: %d restarts", name, restarts);
	CHECK(ldb.why != NULL && strstr(ldb.why, reason_part) != NULL, "%s: reason '%s'", name, ldb.why ? ldb.why : "(none)");
	/* the fence is shut also for a direct call: a stray writer gets nothing, in userdata or in iosroot */
	su.writable = true;
	su.first_block = IOS_FIRST;
	su.nblocks = IOS_BLOCKS;
	ldb.first = IOS_FIRST;                  /* not on: also stale numbers open nothing */
	ldb.blocks = IOS_BLOCKS;
	memset((void *)(su.dma + DMA_BOUNCE), 0xee, 4096);
	CHECK(ufs_write_blocks(IOS_FIRST + 100, 1) == EPERM, "%s: fence open", name);
	CHECK(ufs_write_blocks(IOS_FIRST - 100, 1) == EPERM, "%s: fence open for userdata", name);
	su.writable = false;
	CHECK(before == disk_hash(), "%s: stray write", name);
	printf("ok   %s\n", name);
}

static void
test_on(void)
{
	uint32_t hfs = IOS_BLOCKS - SWEET_LOG_BLOCKS;       /* volume: all that fits */
	fresh_disk(hfs);
	reset_driver();
	uint8_t *shadow = malloc(IOS_BLOCKS * 4096ull);
	uint8_t *before = malloc(DISK_BLOCKS * 4096ull);
	memcpy(before, disk, DISK_BLOCKS * 4096ull);
	memcpy(shadow, disk + IOS_FIRST * 4096ull, IOS_BLOCKS * 4096ull);
	dev_t dev = 0;
	CHECK(sweet_ufs_rootdev(&dev) == 0, "boot: no root: %s", ldb.why ? ldb.why : "");
	if (!ldb.on) {
		return;
	}
	CHECK(su.ready && su.writable && laurel_dualboot_on == 1 && su.lun == 0, "boot state");
	CHECK(su.first_block == IOS_FIRST && su.nblocks == IOS_BLOCKS && ldb.first == IOS_FIRST && ldb.blocks == IOS_BLOCKS, "the root is iosroot");
	CHECK(restarts == 0 && writes == 0, "a boot wrote %llu blocks", (unsigned long long)writes);
	/* random I/O through the real strategy: 512-byte units, any size, near both ends often, and past the end */
	uint32_t ios = 0, rejected = 0;
	char *data = malloc(4u << 20), *back = malloc(4u << 20);
	uint64_t total_secs = su.nblocks * 8;
	for (int i = 0; i < 40000; i++) {
		uint32_t secs = (rnd() % 8 == 0) ? (uint32_t)(rnd() % 8192 + 1) : (uint32_t)(rnd() % 64 + 1);
		uint64_t at = rnd() % total_secs;
		if (rnd() % 8 == 0) {
			at = rnd() % 64;
		} else if (rnd() % 8 == 0) {
			at = total_secs - 1 - rnd() % 64;
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
			CHECK(b.error == EINVAL, "I/O past the end: error %d", b.error);
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
	CHECK(memcmp(disk + IOS_FIRST * 4096ull, shadow, IOS_BLOCKS * 4096ull) == 0, "iosroot does not hold what was written");
	/* the log thread, for real: it writes only the last 1025 blocks of iosroot */
	char line[256];
	memset(line, 'L', sizeof(line));
	uint8_t *logb = malloc(SWEET_LOG_BLOCKS * 4096ull);
	memcpy(logb, disk + (IOS_FIRST + IOS_BLOCKS - SWEET_LOG_BLOCKS) * 4096ull, SWEET_LOG_BLOCKS * 4096ull);
	uint8_t *rest = malloc((IOS_BLOCKS - SWEET_LOG_BLOCKS) * 4096ull);
	memcpy(rest, disk + IOS_FIRST * 4096ull, (IOS_BLOCKS - SWEET_LOG_BLOCKS) * 4096ull);
	for (int k = 0; k < 3; k++) {
		for (int j = 0; j < 64; j++) {
			sweet_log_append(line, sizeof(line));
		}
		log_rounds = 2;
		if (setjmp(log_out) == 0) {
			sweet_log_thread(NULL, 0);
		}
	}
	CHECK(memcmp(disk + (IOS_FIRST + IOS_BLOCKS - SWEET_LOG_BLOCKS) * 4096ull, "SWEETLOG", 8) == 0, "no log header at the end of iosroot");
	CHECK(memcmp(disk + IOS_FIRST * 4096ull, rest, (IOS_BLOCKS - SWEET_LOG_BLOCKS) * 4096ull) == 0, "the log thread wrote outside its last 1025 blocks");
	/* outside iosroot: every block as before */
	uint64_t outside = 0;
	for (uint64_t b = 0; b < DISK_BLOCKS; b++) {
		if ((b < IOS_FIRST || b > LAST_USABLE) && memcmp(disk + b * 4096, before + b * 4096, 4096) != 0) {
			outside++;
		}
	}
	CHECK(outside == 0, "%llu blocks outside iosroot changed", (unsigned long long)outside);
	printf("ok   %u random I/Os + the log thread: 0 blocks outside iosroot changed (%u past the end refused)\n", ios, rejected);
	/* fence, called directly with every kind of bad address */
	uint64_t h0 = disk_hash();
	const struct { uint64_t lba; uint32_t n; const char *what; } bad[] = {
		{ 0, 1, "MBR" }, { 1, 1, "primary GPT header" }, { 2, 1, "primary entries" }, { GPT_ALT, 1, "backup header" }, { DISK_BLOCKS - 5, 1, "backup entries" },
		{ IOS_FIRST - 1, 1, "last block of userdata" }, { IOS_FIRST - 1, 2, "from userdata into iosroot" }, { 2000, 1, "inside userdata" },
		{ 5, 1, "p0" }, { LAST_USABLE, 2, "past the last usable block" }, { LAST_USABLE + 1, 1, "behind iosroot" }, { IOS_FIRST, 0, "zero blocks" },
		{ IOS_FIRST, 257, "more than the bounce buffer" }, { 0xffffffffffffff00ull, 512, "wrap" }, { UINT32_MAX + 1ull, 1, "over 32 bits" },
	};
	for (size_t i = 0; i < sizeof(bad) / sizeof(bad[0]); i++) {
		CHECK(ufs_write_blocks(bad[i].lba, bad[i].n) == EPERM, "fence let through: %s", bad[i].what);
	}
	su.lun = 1;
	CHECK(ufs_write_blocks(IOS_FIRST + 7, 1) == EPERM, "fence on LUN 1");
	su.lun = 0;
	CHECK(disk_hash() == h0, "fence: the disk changed");
	/* a stale su must not open the fence: it compares with what the self-check found */
	uint64_t keep = su.first_block, keepn = su.nblocks;
	su.first_block = 100; su.nblocks = IOS_FIRST;
	CHECK(ufs_write_blocks(2000, 1) == EPERM, "fence trusted a changed su");
	su.first_block = keep; su.nblocks = keepn;
	CHECK(ufs_write_blocks(IOS_FIRST + 7, 1) == 0, "good block refused");
	printf("ok   fence: %zu bad addresses refused directly, wrong LUN refused, a changed su refused, a good block passes\n", sizeof(bad) / sizeof(bad[0]));
	/* read-only boot: no write at all, the line says so */
	fresh_disk(hfs);
	reset_driver();
	arg_ufsrw = 0;
	uint64_t d0 = disk_hash();
	CHECK(sweet_ufs_rootdev(&dev) == 0 && ldb.on && !su.writable && writes == 0 && disk_hash() == d0, "ufsrw=0: %s", ldb.why ? ldb.why : "");
	struct fake_buf b = { .blkno = 0, .count = 4096, .flags = B_WRITE, .data = data };
	sweet_ufs_strategy(&b);
	CHECK(b.error == EROFS && disk_hash() == d0, "write in a read-only boot");
	CHECK(ufs_write_blocks(IOS_FIRST + 7, 1) == EPERM && disk_hash() == d0, "fence in a read-only boot");
	printf("ok   ufsrw=0: on, read-only, no write\n");
	free(shadow); free(before); free(data); free(back); free(logb); free(rest);
}

static void
test_off(void)
{
	uint32_t hfs = 4096;
#define CASE(name, setup, reason) do { fresh_disk(hfs); reset_driver(); setup; expect_off(name, reason); } while (0)
	CASE("kill switch laureldualboot=0", arg_dualboot = 0, "laureldualboot=0");
	/* the table as it is today, before the plan: a kernel must take no root from it, also with an HFS+ volume in userdata */
	CASE("no iosroot: the old table", { memset(ent(15), 0, 128); wr64(ent(14) + 40, LAST_USABLE); seal_gpt(); }, "no partition");
	CASE("the name of the root differs", { set_name(ent(15), "iosroot2"); seal_gpt(); }, "no partition");
	CASE("entry count 64", { wr32(hdr() + 80, 64); wr32(bhdr() + 80, 64); seal_gpt(); }, "");
	CASE("entry count 16", { wr32(hdr() + 80, 16); wr32(bhdr() + 80, 16); wr32(hdr() + 16, 0); seal_gpt(); }, "");
	CASE("a 17th entry", { set_ent(16, "x", LAST_USABLE, LAST_USABLE); seal_gpt(); }, "more entries");
	CASE("a hole in the slots", { memset(ent(3), 0, 128); seal_gpt(); }, "fewer entries");
	CASE("iosroot in another slot", { set_ent(14, LDB_ROOT_NAME, 1406, LAST_USABLE); memset(ent(15), 0, 128); seal_gpt(); }, "");
	CASE("a second iosroot", { set_name(ent(2), LDB_ROOT_NAME); seal_gpt(); }, "");
	CASE("userdata has another name", { set_name(ent(14), "data"); seal_gpt(); }, "not metadata");
	CASE("metadata has another name", { set_name(ent(13), "meta"); seal_gpt(); }, "not metadata");
	CASE("userdata overlaps iosroot", { wr64(ent(14) + 40, IOS_FIRST); seal_gpt(); }, "one after the other");
	CASE("a gap before iosroot", { wr64(ent(14) + 40, IOS_FIRST - 2); seal_gpt(); }, "one after the other");
	CASE("iosroot not on 2 MiB", { wr64(ent(14) + 40, IOS_FIRST); wr64(ent(15) + 32, IOS_FIRST + 1); seal_gpt(); }, "2 MiB");
	CASE("iosroot does not reach the last usable block", { wr64(ent(15) + 40, LAST_USABLE - 1); seal_gpt(); }, "last usable");
	CASE("iosroot past the last usable block", { wr64(ent(15) + 40, LAST_USABLE + 1); seal_gpt(); }, "one after the other");
	CASE("iosroot has attributes", { wr64(ent(15) + 48, 1); seal_gpt(); }, "attributes");
	CASE("primary header CRC", hdr()[16] ^= 1, "CRC");
	CASE("primary entries CRC", ent(0)[40] ^= 1, "CRC");
	CASE("backup header CRC", bhdr()[16] ^= 1, "CRC");
	CASE("backup entries CRC", bent(0)[40] ^= 1, "CRC");
	CASE("backup header gone", memset(bhdr(), 0, 92), "signature");
	CASE("the two copies differ", { bent(4)[20] ^= 1; uint32_t c = ldb_crc32(bent(0), 32 * 128, 0xffffffffu); wr32(bhdr() + 88, c); wr32(bhdr() + 16, 0); wr32(bhdr() + 16, ldb_crc32(bhdr(), 92, 16)); }, "differ");
	CASE("usable range differs", { wr64(bhdr() + 48, LAST_USABLE - 1); wr32(bhdr() + 16, 0); wr32(bhdr() + 16, ldb_crc32(bhdr(), 92, 16)); }, "usable");
	CASE("no HFS+ volume in iosroot", disk[IOS_FIRST * 4096ull + 1024] = 0, "no HFS+");
	CASE("the volume takes the log's room", hfs = IOS_BLOCKS - SWEET_LOG_BLOCKS + 1; wr_be32(disk + IOS_FIRST * 4096ull + 1024 + 44, hfs); hfs = 4096, "longer");
	/* no GPT, and a read failure */
	CASE("no GPT at all", memset(hdr(), 0, 4096), "no partition");
#undef CASE
}

int
main(void)
{
	setvbuf(stdout, NULL, _IONBF, 0);
	disk = malloc(DISK_BLOCKS * 4096ull);
	test_on();
	test_off();
	printf("test_kernel: %d checks passed, %d failed\n", passes, fails);
	return fails ? 1 : 0;
}
