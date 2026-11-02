/*
 * ldbhelper: the Android side of the Mi A3 dual boot (docs/laurel_sprout/dual-boot.md). Runs as root on Lineage (adb root), pushed by scripts/laurel/dual-boot.sh. No libc
 * (raw syscalls): one clang builds it for aarch64 (the phone) and for the host (test).
 *
 *   ldbhelper version                     the hash of this source (dual-boot.sh compares it after each push)
 *   ldbhelper gpt-dump DEV HEAD TAIL      the first and last 1 MiB of DEV to files, read past the page cache: the format of the backup
 *   ldbhelper gpt-write PLAN DEV          the steps of a plan of `op10tool gpt`: each old block must be what the plan says, each write is read back past the cache
 *   ldbhelper root-verify LIST DEV        read-only: DEV over the block ranges of LIST (`op10tool simg-verify-list`), past the page cache, one process, one CRC-32. Prints the result: dual-boot.sh verify-root compares it
 *
 * Why a helper and not sgdisk or dd: docs/laurel_sprout/dual-boot.md section 3. It changes the 4 blocks of the table and zeroes the 2 superblock blocks of userdata, nothing
 * else, and it never asks the kernel to read the table again: the running Android keeps the old table until its reboot.
 * Build: scripts/laurel/test-dualboot.sh (host, -DLDB_TEST_FILE: DEV is a file; and the phone's own code for this host under test/dio_check.c: the O_DIRECT rules of 4.14) and scripts/laurel/dual-boot.sh (phone).
 */
typedef unsigned char uint8_t;
typedef unsigned int uint32_t;
typedef unsigned long uint64_t;
typedef unsigned long uintptr_t;
typedef long int64_t;
typedef _Bool bool;
#define true 1
#define false 0
#define NULL ((void *)0)

#ifndef LDB_HELPER_VERSION
#define LDB_HELPER_VERSION "unversioned"    /* dual-boot.sh gives the hash of this source */
#endif
__attribute__((used)) static const char helper_version[] = "ldbhelper-version " LDB_HELPER_VERSION;

#if defined(__aarch64__)
enum { SYS_ioctl = 29, SYS_flock = 32, SYS_openat = 56, SYS_close = 57, SYS_read = 63, SYS_write = 64, SYS_pread = 67, SYS_pwrite = 68, SYS_lseek = 62, SYS_fsync = 82, SYS_exit = 94, SYS_clock_gettime = 113 };
#define O_DIRECT_ 0x10000
static long
sc(long n, long a, long b, long c, long d)
{
	register long x8 __asm__("x8") = n, x0 __asm__("x0") = a, x1 __asm__("x1") = b, x2 __asm__("x2") = c, x3 __asm__("x3") = d;
	__asm__ volatile ("svc #0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2), "r"(x3) : "memory");
	return x0;
}
__asm__(".globl _start\n_start:\n  mov x0, sp\n  and sp, x0, #-16\n  b start_c\n");
#elif defined(__x86_64__)
enum { SYS_read = 0, SYS_write = 1, SYS_openat = 257, SYS_close = 3, SYS_lseek = 8, SYS_ioctl = 16, SYS_pread = 17, SYS_pwrite = 18, SYS_flock = 73, SYS_fsync = 74, SYS_exit = 231, SYS_clock_gettime = 228 };
#define O_DIRECT_ 0x4000
static long
sc(long n, long a, long b, long c, long d)
{
	long r;
	register long r10 __asm__("r10") = d;
	__asm__ volatile ("syscall" : "=a"(r) : "0"(n), "D"(a), "S"(b), "d"(c), "r"(r10) : "rcx", "r11", "memory");
	return r;
}
__asm__(".globl _start\n_start:\n  mov %rsp, %rdi\n  and $-16, %rsp\n  call start_c\n");
#else
#error "aarch64 (phone) or x86_64 (host test) only"
#endif

#define AT_FDCWD -100
#define O_RDONLY 0
#define O_WRONLY 1
#define O_RDWR 2
#define O_CREAT 0100
#define O_TRUNC 01000
#define O_SYNC 04010000
#define LOCK_EX 2
#define LOCK_NB 4
#define BLK 4096u
#define BLKSSZGET 0x1268ul
#define BLKROGET 0x125eul
#define DUMP_BLOCKS 256u
#define KIND_REPLACE 1u
#define KIND_ZERO 2u
#define MAX_STEP_BLOCKS 2u
#define MAX_STEPS 8u
#define ZERO_BLOCKS 2u                  /* the two f2fs superblock copies */

struct plan_step {
	uint64_t lba;
	uint32_t blocks, kind;
	const uint8_t *oldb, *newb;
};
static uint8_t plan[64 * 1024] __attribute__((aligned(4096)));
/* All device I/O goes through these three. 4.14 fs/block_dev.c:227, :360: O_DIRECT refuses memory, offset or length off the 4096-byte block: the plan's bytes must never be the buffer. */
static uint8_t io[MAX_STEP_BLOCKS * BLK] __attribute__((aligned(4096)));
static uint8_t wr[MAX_STEP_BLOCKS * BLK] __attribute__((aligned(4096)));
static uint8_t dump[DUMP_BLOCKS * BLK] __attribute__((aligned(4096)));
static struct plan_step steps[MAX_STEPS];
/* root-verify: 4 MiB per read, on the block as O_DIRECT needs; the list is a plain file */
#define RV_READ_BLOCKS 1024u
#define RV_LIST_BYTES (64u * 1024u)
#define RV_HEADER 40
#define RV_PROGRESS_BLOCKS (256u * 1024u)       /* one line per GiB */
static uint8_t rv_buf[RV_READ_BLOCKS * BLK] __attribute__((aligned(4096)));
static uint8_t rv_list[RV_LIST_BYTES] __attribute__((aligned(8)));
static uint32_t crc_tab[8][256];
__attribute__((unused)) static char **Envp;

void *
memcpy(void *d, const void *s, unsigned long n)
{
	uint8_t *a = d;
	const uint8_t *b = s;
	while (n--) {
		*a++ = *b++;
	}
	return d;
}
void *
memset(void *d, int c, unsigned long n)
{
	uint8_t *a = d;
	while (n--) {
		*a++ = (uint8_t)c;
	}
	return d;
}
static unsigned long
slen(const char *s)
{
	unsigned long n = 0;
	while (s[n]) {
		n++;
	}
	return n;
}
static int
streq(const char *a, const char *b)
{
	while (*a && *a == *b) {
		a++;
		b++;
	}
	return *a == *b;
}
static void
out(int fd, const char *s)
{
	sc(SYS_write, fd, (long)s, (long)slen(s), 0);
}
static void
num(int fd, uint64_t v)
{
	char t[24];
	int i = 23;
	t[i] = 0;
	do {
		t[--i] = (char)('0' + v % 10);
		v /= 10;
	} while (v);
	out(fd, t + i);
}
static void
die(const char *what, long err)
{
	out(2, "ldbhelper: FAILED: ");
	out(2, what);
	if (err) {
		out(2, " (errno ");
		num(2, (uint64_t)-err);
		out(2, ")");
	}
	out(2, "\n");
	sc(SYS_exit, 1, 0, 0, 0);
	for (;;) {
	}
}
static long
open_or_die(const char *path, long flags, long mode)
{
	long fd = sc(SYS_openat, AT_FDCWD, (long)path, flags, mode);
	if (fd < 0) {
		die(path, fd);
	}
	return fd;
}
#ifdef LDB_TEST_FILE
/* Host test only: LDB_TEST_STOP=N ends this process after step N of a plan, as a power cut does: no read-back, nothing more on the device. */
static long
test_stop(void)
{
	static const char key[] = "LDB_TEST_STOP=";
	for (char **e = Envp; e && *e; e++) {
		const char *v = *e;
		unsigned i = 0;
		while (key[i] && v[i] == key[i]) {
			i++;
		}
		if (!key[i]) {
			return v[i] - '0';
		}
	}
	return -1;
}
#endif
/* The block device, past the page cache: a read must see the flash, not what this process just wrote. */
static long
open_dev(const char *dev, long flags)
{
#ifdef LDB_TEST_FILE
	return open_or_die(dev, flags, 0);
#else
	long fd = open_or_die(dev, flags | O_DIRECT_, 0);
	int ssz = 0, ro = 1;
	long r = sc(SYS_ioctl, fd, BLKSSZGET, (long)&ssz, 0);
	if (r < 0 || ssz != (int)BLK) {
		die("the device has no 4096-byte logical blocks", r < 0 ? r : 0);
	}
	if (flags != O_RDONLY) {
		r = sc(SYS_ioctl, fd, BLKROGET, (long)&ro, 0);
		if (r < 0 || ro) {
			die("the device is read-only", r < 0 ? r : 0);
		}
	}
	return fd;
#endif
}
static void
dev_read(long fd, uint64_t lba, void *p, uint32_t blocks)
{
	long r = sc(SYS_pread, fd, (long)p, (long)(blocks * BLK), (long)(lba * BLK));
	if (r != (long)(blocks * BLK)) {
		die("raw read", r < 0 ? r : 0);
	}
}
static void
dev_write(long fd, uint64_t lba, const void *p, uint32_t blocks)
{
	/* the bytes go through the aligned buffer: a plan holds them at offsets off the block */
	if (blocks > MAX_STEP_BLOCKS) {
		die("a write is larger than its buffer", 0);
	}
	memcpy(wr, p, blocks * BLK);
	/* one pwrite on O_DIRECT is one command for a range this small; LBA 1 and 2 go out together */
	long r = sc(SYS_pwrite, fd, (long)wr, (long)(blocks * BLK), (long)(lba * BLK));
	if (r != (long)(blocks * BLK)) {
		die("raw write", r < 0 ? r : 0);
	}
	r = sc(SYS_fsync, fd, 0, 0, 0);
	if (r < 0) {
		die("fsync of the device", r);
	}
}
static uint64_t
dev_blocks(long fd)
{
	long size = sc(SYS_lseek, fd, 0, 2 /* SEEK_END */, 0);
	if (size < 0 || size % BLK) {
		die("device size", size < 0 ? size : 0);
	}
	return (uint64_t)size / BLK;
}
static void
cmd_dump(const char *dev, const char *head, const char *tail)
{
	long fd = open_dev(dev, O_RDONLY);
	uint64_t n = dev_blocks(fd);
	const char *paths[2] = { head, tail };
	uint64_t at[2] = { 0, n - DUMP_BLOCKS };
	if (n < 2 * DUMP_BLOCKS) {
		die("device too small", 0);
	}
	for (unsigned i = 0; i < 2; i++) {
		dev_read(fd, at[i], dump, DUMP_BLOCKS);
		long o = open_or_die(paths[i], O_WRONLY | O_CREAT | O_TRUNC, 0600);
		long w = sc(SYS_write, o, (long)dump, DUMP_BLOCKS * BLK, 0);
		if (w != (long)(DUMP_BLOCKS * BLK)) {
			die("dump write", w < 0 ? w : 0);
		}
		sc(SYS_close, o, 0, 0, 0);
	}
	out(1, "gpt-dump ok: ");
	num(1, n);
	out(1, " blocks\n");
}
static uint32_t
blk_eq(const uint8_t *a, const uint8_t *b, uint32_t n)
{
	for (uint32_t i = 0; i < n; i++) {
		if (a[i] != b[i]) {
			return 0;
		}
	}
	return 1;
}
static uint32_t
load_plan(const char *path, uint64_t disk)
{
	long fd = open_or_die(path, O_RDONLY, 0);
	long n = sc(SYS_read, fd, (long)plan, sizeof(plan), 0);
	sc(SYS_close, fd, 0, 0, 0);
	if (n < 32 || !blk_eq(plan, (const uint8_t *)"LDBPLAN1", 8)) {
		die("not a plan", n < 0 ? n : 0);
	}
	uint64_t want_blocks, want_hash, h = 0xcbf29ce484222325ul;
	uint32_t count;
	memcpy(&want_blocks, plan + 8, 8);
	memcpy(&count, plan + 16, 4);
	memcpy(&want_hash, plan + 24, 8);
	for (long i = 32; i < n; i++) {
		h = (h ^ plan[i]) * 0x100000001b3ul;
	}
	if (h != want_hash) {
		die("the plan is damaged", 0);
	}
	if (want_blocks != disk) {
		die("the plan is for a device of another size", 0);
	}
	if (count == 0 || count > MAX_STEPS) {
		die("the plan has a wrong step count", 0);
	}
	long o = 32;
	for (uint32_t i = 0; i < count; i++) {
		struct plan_step *s = &steps[i];
		if (o + 16 > n) {
			die("the plan is short", 0);
		}
		memcpy(&s->lba, plan + o, 8);
		memcpy(&s->blocks, plan + o + 8, 4);
		memcpy(&s->kind, plan + o + 12, 4);
		o += 16;
		if (s->blocks == 0 || s->blocks > MAX_STEP_BLOCKS || s->lba + s->blocks > disk) {
			die("a plan step is out of range", 0);
		}
		if (s->kind == KIND_REPLACE) {
			s->oldb = plan + o;
			s->newb = plan + o + s->blocks * BLK;
			o += 2 * s->blocks * BLK;
			if (o > n) {
				die("the plan is short", 0);
			}
		} else if (s->kind != KIND_ZERO || s->blocks != ZERO_BLOCKS) {
			die("a plan step has a wrong kind", 0);
		}
	}
	if (o != n) {
		die("the plan has trailing bytes", 0);
	}
	return count;
}
/*
 * Each block of a replace step is compared by itself: new, old or neither. A step is new or old when all its blocks are. Allowed: the first k replace steps new, the rest old: a
 * run that stopped there. Also allowed: all steps new but the primary at LBA 1, and that one in any other state (one command can stop half done, and a block can hold anything):
 * *torn = true; the backup holds the plan's new bytes, so the primary can be written from them. Anything else: not the table of this plan: nothing is written.
 * Returns the number of replace steps already done.
 */
static uint32_t
state_of(long fd, uint32_t count, uint32_t *replace_steps, bool *torn)
{
	uint32_t done = 0, total = 0;
	bool seen_old = false;
	*torn = false;
	for (uint32_t i = 0; i < count; i++) {
		const struct plan_step *s = &steps[i];
		if (s->kind != KIND_REPLACE) {
			continue;
		}
		total++;
		uint32_t n_new = 0, n_old = 0;
		for (uint32_t k = 0; k < s->blocks; k++) {
			dev_read(fd, s->lba + k, io, 1);
			if (blk_eq(io, s->newb + k * BLK, BLK)) {
				n_new++;
			} else if (blk_eq(io, s->oldb + k * BLK, BLK)) {
				n_old++;
			} else {
				out(2, "ldbhelper: LBA ");
				num(2, s->lba + k);
				out(2, " is neither the old nor the new bytes of the plan\n");
			}
		}
		if (n_new == s->blocks) {
			if (seen_old) {
				die("the table on the device is not one this plan can leave: a later block is new and an earlier one old", 0);
			}
			done++;
		} else if (n_old == s->blocks) {
			seen_old = true;
		} else if (s->lba == 1 && !seen_old) {
			*torn = true;
		} else {
			die("the table on the device is not the one this plan was made from: nothing written by this run", 0);
		}
	}
	*replace_steps = total;
	return done;
}
/* S5: one writer. The kernel drops the lock when this process ends, also on a kill or a power cut, so a stale lock cannot exist. A second writer stops here, before any read of the device. */
static void
writer_lock(const char *planpath)
{
	static char path[256];
	unsigned long n = slen(planpath);
	if (n + 6 > sizeof(path)) {
		die("the plan path is too long", 0);
	}
	memcpy(path, planpath, n);
	memcpy(path + n, ".lock", 6);
	long fd = open_or_die(path, O_RDWR | O_CREAT, 0600);
	long r = sc(SYS_flock, fd, LOCK_EX | LOCK_NB, 0, 0);
	if (r < 0) {
		die("another gpt-write runs on this phone (it holds the lock): nothing written by this run. Wait for it to end", r);
	}
}
static void
cmd_write(const char *planpath, const char *dev)
{
	writer_lock(planpath);
	long fd = open_dev(dev, O_RDWR | O_SYNC);
	uint32_t count = load_plan(planpath, dev_blocks(fd)), total = 0;
	bool torn = false;
	uint32_t done = state_of(fd, count, &total, &torn), seen = 0;
	if (done == total) {
		out(1, "gpt-write: the device already holds the new table: nothing written\n");
		return;
	}
	if (torn) {
		out(1, "gpt-write: the primary is half written and the backup holds the new table: the primary is written from the plan's new bytes\n");
	}
	for (uint32_t i = 0; i < count; i++) {
		const struct plan_step *s = &steps[i];
		if (s->kind == KIND_REPLACE) {
			if (++seen <= done) {
				continue;
			}
			dev_write(fd, s->lba, s->newb, s->blocks);
			dev_read(fd, s->lba, io, s->blocks);
			if (!blk_eq(io, s->newb, s->blocks * BLK)) {
				die("a block reads back wrong", 0);
			}
		} else {
			/* before the new primary is valid; zeroed again on a later run, because this kind has no old bytes to compare */
			memset(io, 0, s->blocks * BLK);
			dev_write(fd, s->lba, io, s->blocks);
			dev_read(fd, s->lba, io, s->blocks);
			for (uint32_t k = 0; k < s->blocks * BLK; k++) {
				if (io[k]) {
					die("a zeroed block reads back non-zero", 0);
				}
			}
		}
		out(1, "gpt-write: step ");
		num(1, i + 1);
		out(1, " of ");
		num(1, count);
		out(1, ": LBA ");
		num(1, s->lba);
		out(1, " + ");
		num(1, s->blocks);
		out(1, " blocks ok\n");
#ifdef LDB_TEST_FILE
		if (test_stop() == (long)i + 1) {
			sc(SYS_exit, 137, 0, 0, 0);
		}
#endif
	}
	/* all of it again, as a reader after this run sees it */
	if (state_of(fd, count, &total, &torn) != total) {
		die("the new table does not read back in full", 0);
	}
	out(1, "gpt-write ok: new table on the device, read back past the cache. The running kernel keeps the old table until its reboot\n");
}
/* CRC-32 of zlib and crc32fast (polynomial 0xEDB88320, start and end inverted). Slice-by-8: both builds are little-endian. It finds accidental damage, not a change on purpose. */
static void
crc_init(void)
{
	for (uint32_t i = 0; i < 256; i++) {
		uint32_t c = i;
		for (unsigned k = 0; k < 8; k++) {
			c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : c >> 1;
		}
		crc_tab[0][i] = c;
	}
	for (uint32_t i = 0; i < 256; i++) {
		for (unsigned t = 1; t < 8; t++) {
			crc_tab[t][i] = (crc_tab[t - 1][i] >> 8) ^ crc_tab[0][crc_tab[t - 1][i] & 0xff];
		}
	}
}
static uint32_t
crc_add(uint32_t crc, const uint8_t *p, uint64_t n)
{
	/* p is on the block: each 8 bytes load in one read */
	for (; n >= 8; n -= 8, p += 8) {
		uint64_t w = *(const uint64_t *)(const void *)p ^ crc;
		crc = crc_tab[7][w & 0xff] ^ crc_tab[6][(w >> 8) & 0xff] ^ crc_tab[5][(w >> 16) & 0xff] ^ crc_tab[4][(w >> 24) & 0xff] ^
		    crc_tab[3][(w >> 32) & 0xff] ^ crc_tab[2][(w >> 40) & 0xff] ^ crc_tab[1][(w >> 48) & 0xff] ^ crc_tab[0][w >> 56];
	}
	while (n--) {
		crc = crc_tab[0][(crc ^ *p++) & 0xff] ^ (crc >> 8);
	}
	return crc;
}
static void
hex32(int fd, uint32_t v)
{
	char t[9];
	for (int i = 7; i >= 0; i--) {
		t[i] = "0123456789abcdef"[v & 15];
		v >>= 4;
	}
	t[8] = 0;
	out(fd, t);
}
static uint64_t
now_s(void)
{
	long ts[2] = { 0, 0 };
	sc(SYS_clock_gettime, 1 /* CLOCK_MONOTONIC */, (long)ts, 0, 0);
	return (uint64_t)ts[0];
}
/* The ranges one by one, past a small buffer: a list of any length costs no memory */
static long rv_fd;
static uint32_t rv_have, rv_at;
static bool
rv_next(uint32_t *first, uint32_t *count)
{
	if (rv_at == rv_have) {
		long r = sc(SYS_read, rv_fd, (long)rv_list, RV_LIST_BYTES, 0);
		if (r < 0) {
			die("read of the range list", r);
		}
		if (r % 8) {
			die("the range list is damaged: a range is cut", 0);
		}
		if (r == 0) {
			return false;
		}
		rv_have = (uint32_t)r;
		rv_at = 0;
	}
	memcpy(first, rv_list + rv_at, 4);
	memcpy(count, rv_list + rv_at + 4, 4);
	rv_at += 8;
	return true;
}
static void
rv_rewind(void)
{
	long r = sc(SYS_lseek, rv_fd, RV_HEADER, 0 /* SEEK_SET */, 0);
	if (r != RV_HEADER) {
		die("seek in the range list", r < 0 ? r : 0);
	}
	rv_have = rv_at = 0;
}
/* Only reads. A failed read ends this process with no result line: the host then records nothing. Nothing here waits for the host: a lost adb costs only the time of the reads. */
static void
cmd_root_verify(const char *listpath, const char *dev)
{
	uint8_t head[RV_HEADER];
	uint64_t want_ranges, want_blocks, want_end, want_hash, h = 0xcbf29ce484222325ul;

	rv_fd = open_or_die(listpath, O_RDONLY, 0);
	if (sc(SYS_read, rv_fd, (long)head, RV_HEADER, 0) != RV_HEADER || !blk_eq(head, (const uint8_t *)"LDBRNG1", 8)) {
		die("not a range list", 0);
	}
	memcpy(&want_ranges, head + 8, 8);
	memcpy(&want_blocks, head + 16, 8);
	memcpy(&want_end, head + 24, 8);
	memcpy(&want_hash, head + 32, 8);
	long fd = open_dev(dev, O_RDONLY);
	uint64_t disk = dev_blocks(fd);
	/* first the whole list: a damaged one stops before 18 GB of reads */
	uint64_t ranges = 0, blocks = 0, end = 0;
	uint32_t first, count;
	while (rv_next(&first, &count)) {
		const uint8_t *e = rv_list + rv_at;
		for (const uint8_t *b = e - 8; b < e; b++) {
			h = (h ^ *b) * 0x100000001b3ul;
		}
		if (count == 0 || (ranges && first < end)) {
			die("the range list is damaged: ranges out of order", 0);
		}
		end = (uint64_t)first + count;
		blocks += count;
		ranges++;
	}
	if (h != want_hash || ranges != want_ranges || blocks != want_blocks || end != want_end) {
		die("the range list is damaged", 0);
	}
	if (end > disk) {
		die("the range list ends past the device: this is not the partition of the list", 0);
	}
	out(1, "root-verify: ");
	num(1, blocks * BLK >> 20);
	out(1, " MiB in ");
	num(1, ranges);
	out(1, " ranges of a device of ");
	num(1, disk);
	out(1, " blocks\n");

	crc_init();
	rv_rewind();
	uint32_t crc = 0xffffffffu;
	uint64_t done = 0, t0 = now_s();
	while (rv_next(&first, &count)) {
		uint64_t at = first, left = count;
		while (left) {
			uint32_t n = left < RV_READ_BLOCKS ? (uint32_t)left : RV_READ_BLOCKS;
			dev_read(fd, at, rv_buf, n);
			crc = crc_add(crc, rv_buf, (uint64_t)n * BLK);
			at += n;
			left -= n;
			if ((done + n) / RV_PROGRESS_BLOCKS != done / RV_PROGRESS_BLOCKS) {
				out(1, "root-verify: ");
				num(1, (done + n) * BLK >> 20);
				out(1, " of ");
				num(1, blocks * BLK >> 20);
				out(1, " MiB, ");
				num(1, now_s() - t0);
				out(1, " s\n");
			}
			done += n;
		}
	}
	out(1, "root-verify: read in ");
	num(1, now_s() - t0);
	out(1, " s\n");
	/* the same words as the last line of `op10tool simg-verify-list` */
	out(1, "verify ranges ");
	num(1, ranges);
	out(1, " blocks ");
	num(1, done);
	out(1, " end ");
	num(1, end);
	out(1, " crc32 ");
	hex32(1, ~crc);
	out(1, "\n");
}
static void
usage(void)
{
	die("usage: version | gpt-dump DEV HEAD TAIL | gpt-write PLAN DEV | root-verify LIST DEV", 0);
}
__attribute__((used)) void
start_c(long *sp)
{
	long argc = sp[0];
	char **argv = (char **)(sp + 1);

	Envp = argv + argc + 1;
	if (argc < 2) {
		usage();
	}
	const char *c = argv[1];
	if (streq(c, "version") && argc == 2) {
		out(1, helper_version);
		out(1, "\n");
	} else if (streq(c, "gpt-dump") && argc == 5) {
		cmd_dump(argv[2], argv[3], argv[4]);
	} else if (streq(c, "gpt-write") && argc == 4) {
		cmd_write(argv[2], argv[3]);
	} else if (streq(c, "root-verify") && argc == 4) {
		cmd_root_verify(argv[2], argv[3]);
	} else {
		usage();
	}
	sc(SYS_exit, 0, 0, 0, 0);
	for (;;) {
	}
}
