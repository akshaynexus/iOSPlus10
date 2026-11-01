/*
 * ldbhelper: the Android side of the Mi A3 dual boot (docs/laurel_sprout/dual-boot.md). Runs as root on Lineage (adb root), pushed by scripts/laurel/dual-boot.sh. No libc
 * (raw syscalls): one clang builds it for aarch64 (the phone) and for the host (test).
 *
 *   ldbhelper version                     the hash of this source (dual-boot.sh compares it after each push)
 *   ldbhelper gpt-dump DEV HEAD TAIL      the first and last 1 MiB of DEV to files, read past the page cache: the format of the backup
 *   ldbhelper gpt-write PLAN DEV          the steps of a plan of `op10tool gpt plan`: each old block must be what the plan says, each write is read back past the cache
 *
 * Why a helper and not sgdisk or dd: docs/laurel_sprout/dual-boot.md section 3. It changes the 4 blocks of the table and zeroes the 2 superblock blocks of userdata, nothing
 * else, and it never asks the kernel to read the table again: the running Android keeps the old table until its reboot.
 * Build: scripts/laurel/test-dualboot.sh (host, -DLDB_TEST_FILE: DEV is a file) and scripts/laurel/dual-boot.sh (phone).
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
enum { SYS_ioctl = 29, SYS_openat = 56, SYS_close = 57, SYS_read = 63, SYS_write = 64, SYS_pread = 67, SYS_pwrite = 68, SYS_lseek = 62, SYS_fsync = 82, SYS_exit = 94 };
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
enum { SYS_read = 0, SYS_write = 1, SYS_openat = 257, SYS_close = 3, SYS_lseek = 8, SYS_ioctl = 16, SYS_pread = 17, SYS_pwrite = 18, SYS_fsync = 74, SYS_exit = 231 };
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
static uint8_t io[MAX_STEP_BLOCKS * BLK] __attribute__((aligned(4096)));
static uint8_t dump[DUMP_BLOCKS * BLK] __attribute__((aligned(4096)));
static struct plan_step steps[MAX_STEPS];
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
	/* one pwrite on O_DIRECT is one command for a range this small; LBA 1 and 2 go out together */
	long r = sc(SYS_pwrite, fd, (long)p, (long)(blocks * BLK), (long)(lba * BLK));
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
 * Each replace step is old or new. Allowed states: the first k replace steps new, the rest old: a run that stopped there. Anything else: not the table of this plan.
 * Returns the number of replace steps already done.
 */
static uint32_t
state_of(long fd, uint32_t count, uint32_t *replace_steps)
{
	uint32_t done = 0, total = 0;
	bool seen_old = false;
	for (uint32_t i = 0; i < count; i++) {
		const struct plan_step *s = &steps[i];
		if (s->kind != KIND_REPLACE) {
			continue;
		}
		total++;
		dev_read(fd, s->lba, io, s->blocks);
		if (blk_eq(io, s->newb, s->blocks * BLK)) {
			if (seen_old) {
				die("the table on the device is not one this plan can leave: a later block is new and an earlier one old", 0);
			}
			done++;
		} else if (blk_eq(io, s->oldb, s->blocks * BLK)) {
			seen_old = true;
		} else {
			out(2, "ldbhelper: LBA ");
			num(2, s->lba);
			out(2, " is neither the old nor the new bytes of the plan\n");
			die("the table on the device is not the one this plan was made from: nothing written by this run", 0);
		}
	}
	*replace_steps = total;
	return done;
}
static void
cmd_write(const char *planpath, const char *dev)
{
	long fd = open_dev(dev, O_RDWR | O_SYNC);
	uint32_t count = load_plan(planpath, dev_blocks(fd)), total = 0;
	uint32_t done = state_of(fd, count, &total), seen = 0;
	if (done == total) {
		out(1, "gpt-write: the device already holds the new table: nothing written\n");
		return;
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
	if (state_of(fd, count, &total) != total) {
		die("the new table does not read back in full", 0);
	}
	out(1, "gpt-write ok: new table on the device, read back past the cache. The running kernel keeps the old table until its reboot\n");
}
static void
usage(void)
{
	die("usage: version | gpt-dump DEV HEAD TAIL | gpt-write PLAN DEV", 0);
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
	} else {
		usage();
	}
	sc(SYS_exit, 0, 0, 0, 0);
	for (;;) {
	}
}
