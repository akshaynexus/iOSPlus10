/*
 * ldbhelper: the Android side of the Mi A3 dual boot (docs/laurel_sprout/dual-boot.md). Runs as root on Lineage (adb root), pushed by
 * scripts/laurel/dual-boot.sh. The phone has no tool for F2FS_IOC_SET_PIN_FILE or FIEMAP, and its C library is not ours: this file has no
 * libc at all (raw syscalls), so one clang can build it for aarch64 (the phone) and for the host (test) without a sysroot.
 *
 *   ldbhelper version                                      the hash of this source (dual-boot.sh compares it after each push)
 *   ldbhelper check TABLE                                  the table rules, nothing else
 *   ldbhelper alloc PATH BYTES PARTDEV FSDEV               new file, pin, preallocate, sync until a raw checkpoint block changed; then as map
 *   ldbhelper map PATH                                     "pin-failures N" and "extent LOGICAL PHYSICAL LENGTH FLAGS" lines (op10tool dualboot table reads them)
 *   ldbhelper check-map TABLE PATH PARTDEV                 proof of the mapping: a write through the file changes the raw block the table names; then the record PATH.ldbok
 *   ldbhelper lock PATH                                    immutable flag (no unlink, no write through the file)
 *   ldbhelper write TABLE PARTDEV PATH                     frames from stdin (op10tool dualboot stream) to the raw partition, only inside the table; only after the file checks and the record
 *   ldbhelper verify TABLE PARTDEV PATH                    frame index from stdin: compare the raw blocks; when equal, the record says "image verified"
 *   ldbhelper read TABLE PARTDEV AREA_BLOCK COUNT          raw blocks to stdout (console log, checks)
 *   ldbhelper seal TABLE PARTDEV FSDEV PATH                pin, FIEMAP, record; freeze /data; fingerprint; area header state BOUND; immediate reboot, no unmount. Failure: thaw, exit 1
 *   ldbhelper wipe TABLE PARTDEV PATH                      file checks, zero the area header and the HFS+ header by raw write, read back, remove the file and its record, checkpoint
 *   ldbhelper unlink-only PATH                             remove a file that no longer fits its table: no raw write
 *
 * The file checks (pin, immutable flag, FIEMAP = table) run before the first raw block of write, verify, seal and wipe: a table can be stale, and ldb_lba_allowed only
 * compares against the table. Every raw write goes through ldb_lba_allowed (laurel_dualboot.h, the same code as the kernel fence). Nothing here writes outside the table
 * except alloc, check-map, lock, wipe and unlink-only, which act through the file system.
 * Build: scripts/laurel/test-dualboot.sh (host, with LDB_TEST_NO_PIN) and scripts/laurel/dual-boot.sh (phone).
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
#include "laurel_dualboot.h"

#ifndef LDB_HELPER_VERSION
#define LDB_HELPER_VERSION "unversioned"    /* dual-boot.sh gives the hash of this source and laurel_dualboot.h */
#endif
__attribute__((used)) static const char helper_version[] = "ldbhelper-version " LDB_HELPER_VERSION;

#if defined(__aarch64__)
enum { SYS_ioctl = 29, SYS_unlinkat = 35, SYS_renameat = 38, SYS_fallocate = 47, SYS_openat = 56, SYS_close = 57, SYS_lseek = 62, SYS_read = 63, SYS_write = 64, SYS_pread = 67, SYS_pwrite = 68, SYS_fstat = 80, SYS_sync = 81, SYS_fsync = 82, SYS_exit = 94, SYS_nanosleep = 101, SYS_kill = 129, SYS_rt_sigaction = 134, SYS_reboot = 142, SYS_clone = 220, SYS_syncfs = 267, SYS_getrandom = 278 };
#define O_DIRECT 0x10000
static long
sc(long n, long a, long b, long c, long d, long e)
{
	register long x8 __asm__("x8") = n, x0 __asm__("x0") = a, x1 __asm__("x1") = b, x2 __asm__("x2") = c, x3 __asm__("x3") = d, x4 __asm__("x4") = e;
	__asm__ volatile ("svc #0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2), "r"(x3), "r"(x4) : "memory");
	return x0;
}
__asm__(".globl _start\n_start:\n  mov x0, sp\n  and sp, x0, #-16\n  b start_c\n");
#elif defined(__x86_64__)
enum { SYS_read = 0, SYS_write = 1, SYS_close = 3, SYS_fstat = 5, SYS_lseek = 8, SYS_rt_sigaction = 13, SYS_ioctl = 16, SYS_pread = 17, SYS_pwrite = 18, SYS_nanosleep = 35, SYS_clone = 56, SYS_kill = 62, SYS_fsync = 74, SYS_sync = 162, SYS_reboot = 169, SYS_exit = 231, SYS_unlinkat = 263, SYS_renameat = 264, SYS_openat = 257, SYS_fallocate = 285, SYS_syncfs = 306, SYS_getrandom = 318 };
#define O_DIRECT 0x4000
static long
sc(long n, long a, long b, long c, long d, long e)
{
	long r;
	register long r10 __asm__("r10") = d, r8 __asm__("r8") = e;
	__asm__ volatile ("syscall" : "=a"(r) : "0"(n), "D"(a), "S"(b), "d"(c), "r"(r10), "r"(r8) : "rcx", "r11", "memory");
	return r;
}
__asm__(".globl _start\n_start:\n  mov %rsp, %rdi\n  and $-16, %rsp\n  call start_c\n");
#else
#error "aarch64 (phone) or x86_64 (host test) only"
#endif

#define AT_FDCWD -100
#define O_RDONLY 0
#define O_RDWR 2
#define O_CREAT 0100
#define O_EXCL 0200
#define O_SYNC 04010000
#define F2FS_IOC_SET_PIN_FILE 0x4004f50dul
#define F2FS_IOC_GET_PIN_FILE 0x8004f50eul
#define FS_IOC_FIEMAP 0xc020660bul
#define FS_IOC_GETFLAGS 0x80086601ul
#define FS_IOC_SETFLAGS 0x40086602ul
#define FS_IMMUTABLE_FL 0x10
#define FIFREEZE 0xc0045877ul
#define FITHAW 0xc0045878ul
#define ENOENT 2
#define EPERM_ 1
#define EINVAL_ 22
#define SIG_KILL 9
#define SIG_CHLD 17
#define WATCHDOG_THAW_SECONDS 20        /* /data frozen and this helper gone: the child thaws it. Android writes wait until then. */
#define FREEZE_TRIES 3                  /* f2fs_freeze says -EINVAL when a writer dirtied the fs after the sync (fs/f2fs/super.c) */
#define RECHECK_FRAMES 1024u            /* write: the file checks again every 1024 frames (about 1 GiB) */
#define REC_MAPPED 1u                   /* check-map passed for this table */
#define REC_VERIFIED 2u                 /* the image was read back and is right */
#define FIEMAP_FLAG_SYNC 1u
#define FIEMAP_EXTENT_LAST 1u
#define F2FS_SUPER_MAGIC 0xF2F52010u
#define PIN_FAILURES_REFUSE 1024u       /* f2fs clears the pin at gc_pin_file_thresh = 2048 (fs/f2fs/gc.h DEF_GC_FAILED_PINNED_FILES) */
#define FRAME_BLOCKS 256u
#define FRAME_FLAG_ZERO 1u
#define MAP_SAMPLES 64u

struct fiemap_extent {
	uint64_t fe_logical, fe_physical, fe_length, fe_reserved64[2];
	uint32_t fe_flags, fe_reserved[3];
};
struct fiemap {
	uint64_t fm_start, fm_length;
	uint32_t fm_flags, fm_mapped_extents, fm_extent_count, fm_reserved;
	struct fiemap_extent fm_extents[512];
};
struct frame {                          /* op10tool dualboot stream: one header, then blocks x 4096 bytes unless FRAME_FLAG_ZERO */
	char magic[8];
	uint64_t area_block;
	uint32_t blocks, flags;
	uint64_t hash;
};
_Static_assert(sizeof(struct frame) == 32, "frame layout");
struct record {                         /* PATH.ldbok, on /data: a format or a reset takes it away with the file */
	char magic[8];
	uint32_t version, state;
	uint64_t table_id, table_hash, ino, hash;
};
_Static_assert(sizeof(struct record) == 48, "record layout");

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

static uint8_t buf[FRAME_BLOCKS * LDB_BLOCK] __attribute__((aligned(4096)));
static uint64_t table_mem[(sizeof(struct ldb_table) + LDB_MAX_EXTENTS * sizeof(struct ldb_extent)) / 8 + 1];
static const struct ldb_table *T;
static struct fiemap fm;
__attribute__((unused)) static char **Envp;
/* seal: what die() must undo. Header written and /data frozen, in that order of undo. */
static long frozen_fd = -1, watchdog_pid, header_part = -1;
static uint64_t header_lba;
static void seal_undo(void);

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
	sc(SYS_write, fd, (long)s, (long)slen(s), 0, 0);
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
	seal_undo();
	out(2, "ldbhelper: FAILED: ");
	out(2, what);
	if (err) {
		out(2, " (errno ");
		num(2, (uint64_t)-err);
		out(2, ")");
	}
	out(2, "\n");
	sc(SYS_exit, 1, 0, 0, 0, 0);
	for (;;) {
	}
}
static uint64_t
parse(const char *s)
{
	uint64_t v = 0;
	if (!*s) {
		die("number expected", 0);
	}
	for (; *s; s++) {
		if (*s < '0' || *s > '9' || v > (uint64_t)-1 / 10 - 1) {
			die("bad number", 0);
		}
		v = v * 10 + (uint64_t)(*s - '0');
	}
	return v;
}
static long
open_or_die(const char *path, long flags, long mode)
{
	long fd = sc(SYS_openat, AT_FDCWD, (long)path, flags, mode, 0);
	if (fd < 0) {
		die(path, fd);
	}
	return fd;
}
#ifdef LDB_TEST_NO_PIN
/* Host test only (this block is not in the phone binary): the test names a failure in LDB_TEST_FAULT, and traces the steps that need root. */
static int
test_fault(const char *name)
{
	static const char key[] = "LDB_TEST_FAULT=";
	for (char **e = Envp; e && *e; e++) {
		const char *v = *e;
		unsigned i = 0;
		while (key[i] && v[i] == key[i]) {
			i++;
		}
		if (key[i]) {
			continue;
		}
		v += i;
		while (*v) {            /* comma list */
			const char *n = name;
			while (*n && *v == *n) {
				v++;
				n++;
			}
			if (!*n && (*v == ',' || !*v)) {
				return 1;
			}
			while (*v && *v != ',') {
				v++;
			}
			if (*v) {
				v++;
			}
		}
	}
	return 0;
}
#endif
static void
read_exact(long fd, void *p, uint64_t len, const char *what)
{
	uint8_t *d = p;
	while (len) {
		long r = sc(SYS_read, fd, (long)d, (long)len, 0, 0);
		if (r <= 0) {
			die(what, r);
		}
		d += r;
		len -= (uint64_t)r;
	}
}
/* the raw partition, one extent piece at a time; lba comes from ldb_map and is checked again here */
static void
raw_read(long dev, uint64_t lba, void *p, uint32_t blocks)
{
	long r = sc(SYS_pread, dev, (long)p, (long)(blocks * LDB_BLOCK), (long)((lba - T->part_first) * LDB_BLOCK), 0);
	if (r != (long)(blocks * LDB_BLOCK)) {
		die("raw read", r < 0 ? r : 0);
	}
}
static void
raw_write(long dev, uint64_t lba, const void *p, uint32_t blocks)
{
	if (!ldb_lba_allowed(T, lba, blocks)) {
		die("refused: write outside the table", 0);
	}
	long r = sc(SYS_pwrite, dev, (long)p, (long)(blocks * LDB_BLOCK), (long)((lba - T->part_first) * LDB_BLOCK), 0);
	if (r != (long)(blocks * LDB_BLOCK)) {
		die("raw write", r < 0 ? r : 0);
	}
}
static void
load_table(const char *path)
{
	long fd = open_or_die(path, O_RDONLY, 0);
	long r = sc(SYS_read, fd, (long)table_mem, sizeof(table_mem), 0, 0);
	if (r < 0) {
		die("read table", r);
	}
	sc(SYS_close, fd, 0, 0, 0, 0);
	const char *why = ldb_table_check(table_mem, (uint64_t)r);
	if (why) {
		die(why, 0);
	}
	T = (const struct ldb_table *)(const void *)table_mem;
}
/* FIEMAP of the whole file into calls of cb. sync: FIEMAP_FLAG_SYNC; not on a frozen /data. Returns the extent count. */
static uint64_t
walk_fiemap(long fd, uint32_t fm_flags, void (*cb)(uint64_t, uint64_t, uint64_t, uint32_t, void *), void *ctx)
{
	uint64_t start = 0, n = 0;
	for (;;) {
		memset(&fm, 0, sizeof(fm));
		fm.fm_start = start;
		fm.fm_length = (uint64_t)-1;
		fm.fm_flags = fm_flags;
		fm.fm_extent_count = 512;
		long r = sc(SYS_ioctl, fd, FS_IOC_FIEMAP, (long)&fm, 0, 0);
		if (r < 0) {
			die("FIEMAP", r);
		}
		if (fm.fm_mapped_extents == 0) {
			return n;
		}
		for (uint32_t i = 0; i < fm.fm_mapped_extents; i++) {
			const struct fiemap_extent *e = &fm.fm_extents[i];
			cb(e->fe_logical, e->fe_physical, e->fe_length, e->fe_flags, ctx);
			n++;
			start = e->fe_logical + e->fe_length;
			if (e->fe_flags & FIEMAP_EXTENT_LAST) {
				return n;
			}
		}
	}
}
/* failure count of a pinned file. GET gives 0 for "not pinned" too (fs/f2fs/file.c f2fs_ioc_get_pin_file), so it says nothing about the pin itself. */
static uint32_t
pin_failures(long fd)
{
#ifdef LDB_TEST_NO_PIN
	(void)fd;
	return 0;
#else
	uint32_t pin = 0;
	long r = sc(SYS_ioctl, fd, F2FS_IOC_GET_PIN_FILE, (long)&pin, 0, 0);
	if (r < 0) {
		die("F2FS_IOC_GET_PIN_FILE", r);
	}
	return pin;
#endif
}
/* Make sure of the pin: SET on a pinned file changes nothing and answers the failure count; over the limit f2fs refuses with EAGAIN (f2fs_pin_file_control). */
static uint32_t
pin_ensure(long fd)
{
#ifdef LDB_TEST_NO_PIN
	(void)fd;
	return 0;
#else
	uint32_t one = 1;
	long r = sc(SYS_ioctl, fd, F2FS_IOC_SET_PIN_FILE, (long)&one, 0, 0);
	if (r < 0) {
		die("cannot pin the file (f2fs gave up on it after failed GC tries: the blocks may have moved)", r);
	}
	return (uint32_t)r;
#endif
}
static void
print_extent(uint64_t l, uint64_t p, uint64_t len, uint32_t f, void *ctx)
{
	(void)ctx;
	out(1, "extent ");
	num(1, l);
	out(1, " ");
	num(1, p);
	out(1, " ");
	num(1, len);
	out(1, " ");
	num(1, f);
	out(1, "\n");
}
static void
cmd_map(long fd)
{
	out(1, "pin-failures ");
	num(1, pin_failures(fd));
	out(1, "\n");
	walk_fiemap(fd, FIEMAP_FLAG_SYNC, print_extent, NULL);
}
/* Raw read with no table yet: partition block, from 0. */
static void
part_read(long part, uint64_t pb, void *p)
{
	long r = sc(SYS_pread, part, (long)p, LDB_BLOCK, (long)(pb * LDB_BLOCK), 0);
	if (r != LDB_BLOCK) {
		die("raw read", r < 0 ? r : 0);
	}
}
/* Where the checkpoint packs are: the only f2fs parsing in this project, on Android's own plain view of the superblock. */
static void
fp_locate(const char *fsdev, uint64_t fp[LDB_FP_BLOCKS])
{
	long fs = open_or_die(fsdev, O_RDONLY, 0);
	if (sc(SYS_pread, fs, (long)buf, LDB_BLOCK, 0, 0) != LDB_BLOCK) {
		die("superblock read", 0);
	}
	sc(SYS_close, fs, 0, 0, 0, 0);
	const uint8_t *sb = buf + 1024;
	uint32_t magic, log_bps, cp;
	memcpy(&magic, sb, 4);
	memcpy(&log_bps, sb + 20, 4);
	memcpy(&cp, sb + 76, 4);
	if (magic != F2FS_SUPER_MAGIC || log_bps == 0 || log_bps > 16 || cp == 0) {
		die("no f2fs superblock on the filesystem device", 0);
	}
	fp[0] = 0;
	fp[1] = cp;
	fp[2] = (uint64_t)cp + (1ul << log_bps);
}
/* The raw bytes (ciphertext) of the fingerprint blocks, as the kernel will hash them. A block of only zeros is no fingerprint. */
static void
fp_hash(long part, const uint64_t fp[LDB_FP_BLOCKS], uint64_t out_hash[LDB_FP_BLOCKS])
{
	static uint8_t raw[LDB_BLOCK] __attribute__((aligned(4096)));
	for (unsigned i = 0; i < LDB_FP_BLOCKS; i++) {
		part_read(part, fp[i], raw);
		bool zero = true;
		for (unsigned k = 0; k < LDB_BLOCK && zero; k++) {
			zero = raw[k] == 0;
		}
		if (zero) {
			die("a fingerprint block holds only zeros: this is not a live f2fs on this partition", 0);
		}
		out_hash[i] = ldb_hash_add(LDB_HASH_INIT, raw, LDB_BLOCK);
	}
}
static void
cmd_alloc(const char *path, uint64_t bytes, const char *partdev, const char *fsdev)
{
	if (bytes == 0 || bytes % LDB_BLOCK) {
		die("size must be a multiple of 4096", 0);
	}
	uint64_t fp[LDB_FP_BLOCKS], before[LDB_FP_BLOCKS], after[LDB_FP_BLOCKS];
	long part = open_or_die(partdev, O_RDONLY | O_DIRECT, 0);
	fp_locate(fsdev, fp);
	fp_hash(part, fp, before);
	long fd = open_or_die(path, O_RDWR | O_CREAT | O_EXCL, 0600);
#ifndef LDB_TEST_NO_PIN
	/* pin first: only a pinned file gets real blocks from fallocate (fs/f2fs/file.c expand_inode_data: F2FS_GET_BLOCK_PRE_DIO in CURSEG_COLD_DATA_PINNED, whole segments) */
	uint32_t one = 1;
	long r = sc(SYS_ioctl, fd, F2FS_IOC_SET_PIN_FILE, (long)&one, 0, 0);
	if (r < 0) {
		die("F2FS_IOC_SET_PIN_FILE", r);
	}
#else
	long r;
#endif
	r = sc(SYS_fallocate, fd, 0, 0, (long)bytes, 0);
	if (r < 0) {
		sc(SYS_unlinkat, AT_FDCWD, (long)path, 0, 0, 0);        /* no half file left */
		die("fallocate", r);
	}
	r = sc(SYS_fsync, fd, 0, 0, 0, 0);
	if (r < 0) {
		die("fsync", r);
	}
	/*
	 * fsync_mode=nobarrier: fsync alone can lose the new file in a crash, its blocks free again, while the host holds a table for them.
	 * Only a checkpoint makes the file permanent, and syncfs writes one. Proof: a raw checkpoint head changed on the flash.
	 */
	r = sc(SYS_syncfs, fd, 0, 0, 0, 0);
	if (r < 0) {
		die("syncfs", r);
	}
	fp_hash(part, fp, after);
	bool same = before[1] == after[1] && before[2] == after[2];
#ifdef LDB_TEST_NO_PIN
	same = test_fault("no-checkpoint");     /* a file system on this host writes no f2fs checkpoint */
#endif
	if (same) {
		die("no checkpoint reached the flash after the allocation: a crash now loses this file. Stop: dual-boot.sh remove", 0);
	}
	cmd_map(fd);
}
/* ---- the file checks: pin, immutable flag, FIEMAP = table ---- */
static uint32_t file_checks(long fd);
static long open_part(const char *partdev, long flags);
static long
stat_ino(long fd)
{
	uint64_t st[32];                /* struct stat: st_ino at byte 8 on aarch64 and x86_64 */
	long r = sc(SYS_fstat, fd, (long)st, 0, 0, 0);
	if (r < 0) {
		die("fstat", r);
	}
	return (long)st[1];
}
__attribute__((unused)) static long
get_flags(long fd)
{
	long flags = 0;
	long r = sc(SYS_ioctl, fd, FS_IOC_GETFLAGS, (long)&flags, 0, 0);
	if (r < 0) {
		die("FS_IOC_GETFLAGS", r);
	}
	return flags;
}
static void
need_immutable(long fd)
{
#ifdef LDB_TEST_NO_PIN
	if (test_fault("not-immutable")) {
		die("the file has no immutable flag: run check-map first", 0);
	}
#else
	if (!(get_flags(fd) & FS_IMMUTABLE_FL)) {
		die("the file has no immutable flag: run check-map first", 0);
	}
#endif
}
static void
record_path(char *d, const char *path)
{
	static const char ext[] = ".ldbok";
	unsigned long n = slen(path);
	if (n + sizeof(ext) > 512) {
		die("path too long", 0);
	}
	memcpy(d, path, n);
	memcpy(d + n, ext, sizeof(ext));
}
static uint64_t
record_hash(const struct record *r)
{
	return ldb_hash_zeroing(r, sizeof(*r), __builtin_offsetof(struct record, hash));
}
/* The record of this file and this table, or die. min: REC_MAPPED or REC_VERIFIED. */
static uint32_t
record_need(const char *path, long fd, uint32_t min)
{
	static char p[512];
	struct record r;
#ifdef LDB_TEST_NO_PIN
	if (test_fault("no-file-check")) {      /* the frame tests: a fragmented synthetic table with no such file behind it */
		return REC_VERIFIED;
	}
#endif
	record_path(p, path);
	long rf = sc(SYS_openat, AT_FDCWD, (long)p, O_RDONLY, 0, 0);
	if (rf < 0) {
		die("no record that check-map passed for this file: run check-map first", 0);
	}
	long n = sc(SYS_read, rf, (long)&r, sizeof(r), 0, 0);
	sc(SYS_close, rf, 0, 0, 0, 0);
	bool magic = n == (long)sizeof(r);
	for (unsigned i = 0; i < 8 && magic; i++) {
		magic = r.magic[i] == "LDBCHECK"[i];
	}
	if (!magic || r.version != 1 || record_hash(&r) != r.hash) {
		die("the check-map record is damaged: run check-map first", 0);
	}
	if (r.table_id != T->table_id || r.table_hash != T->hash || (long)r.ino != stat_ino(fd)) {
		die("the check-map record is for another table or another file: run check-map for this one", 0);
	}
	if (r.state < min) {
		die(min == REC_VERIFIED ? "the image was not read back: run install to its end" : "check-map did not pass", 0);
	}
	return r.state;
}
/* Atomic and on the flash (a checkpoint) when this returns. */
static void
record_write(const char *path, long fd, uint32_t state)
{
	static char p[512], t[520];
	struct record r;
#ifdef LDB_TEST_NO_PIN
	if (test_fault("no-file-check")) {
		return;
	}
#endif
	record_path(p, path);
	memcpy(t, p, slen(p));
	memcpy(t + slen(p), ".t", 3);
	memset(&r, 0, sizeof(r));
	memcpy(r.magic, "LDBCHECK", 8);
	r.version = 1;
	r.state = state;
	r.table_id = T->table_id;
	r.table_hash = T->hash;
	r.ino = (uint64_t)stat_ino(fd);
	r.hash = record_hash(&r);
	sc(SYS_unlinkat, AT_FDCWD, (long)t, 0, 0, 0);
	long rf = open_or_die(t, O_RDWR | O_CREAT | O_EXCL, 0600);
	if (sc(SYS_write, rf, (long)&r, sizeof(r), 0, 0) != (long)sizeof(r)) {
		die("record write", 0);
	}
	long e = sc(SYS_fsync, rf, 0, 0, 0, 0);
	sc(SYS_close, rf, 0, 0, 0, 0);
	if (e < 0) {
		die("record fsync", e);
	}
	e = sc(SYS_renameat, AT_FDCWD, (long)t, AT_FDCWD, (long)p, 0);
	if (e < 0) {
		die("record rename", e);
	}
	e = sc(SYS_syncfs, fd, 0, 0, 0, 0);
	if (e < 0) {
		die("syncfs", e);
	}
}
static void
cmd_lock(const char *path)
{
	long fd = open_or_die(path, O_RDONLY, 0);
	long flags = 0;
	long r = sc(SYS_ioctl, fd, FS_IOC_GETFLAGS, (long)&flags, 0, 0);
	if (r < 0) {
		die("FS_IOC_GETFLAGS", r);
	}
	flags |= FS_IMMUTABLE_FL;
	r = sc(SYS_ioctl, fd, FS_IOC_SETFLAGS, (long)&flags, 0, 0);
	if (r < 0) {
		die("FS_IOC_SETFLAGS", r);
	}
	out(1, "locked\n");
}

/*
 * The mapping must not rest on reasoning about dm-default-key and f2fs. So: for samples over the area, read the raw block, write new bytes through the file,
 * sync, read the raw block again. It must have changed: this file block is that partition block. Only for a file with no root in it yet.
 */
static uint64_t
sample_block(uint32_t i, uint32_t n)
{
	/* first and last block of the area always; the others evenly between */
	return n < 2 ? 0 : (T->area_blocks - 1) * i / (n - 1);
}
static void
cmd_check_map(const char *path, const char *partdev)
{
#ifdef LDB_TEST_NO_PIN
	/* the host has no raw view of a file: this test build writes each sample to the blocks the table names instead of through the file; fault no-mirror: a table that does not describe the file */
	long part = open_or_die(partdev, O_RDWR | O_DIRECT, 0);
#else
	long part = open_or_die(partdev, O_RDONLY | O_DIRECT, 0);
#endif
	long fd = open_or_die(path, O_RDWR, 0);
	uint64_t seed = 0;
	static uint8_t raw0[LDB_BLOCK] __attribute__((aligned(4096)));
	static uint8_t raw1[LDB_BLOCK] __attribute__((aligned(4096)));

	if (sc(SYS_getrandom, (long)&seed, sizeof(seed), 0, 0, 0) != sizeof(seed)) {
		die("getrandom", 0);
	}
	uint64_t lba = 0;
	uint32_t run = 0;
	if (ldb_map(T, 0, 1, &lba, &run) != 0) {
		die("no area block 0", 0);
	}
	raw_read(part, lba, raw0, 1);
	const struct ldb_header *h = (const struct ldb_header *)(const void *)raw0;
	bool magic = true;
	for (unsigned i = 0; i < 8; i++) {
		magic = magic && h->magic[i] == LDB_HDR_MAGIC[i];
	}
	if (magic) {
		die("this area is already installed: check-map would overwrite it", 0);
	}
	/* installed, not sealed yet: the volume header is there */
	if (ldb_map(T, LDB_RESERVED_BLOCKS, 1, &lba, &run) != 0) {
		die("no root block in the table", 0);
	}
	raw_read(part, lba, raw0, 1);
	if (ldb_hfs_volume_bytes(raw0) != 0) {
		die("this area holds a root: check-map would overwrite it", 0);
	}
	for (uint32_t i = 0; i < MAP_SAMPLES; i++) {
		uint64_t ab = sample_block(i, MAP_SAMPLES);
		if (ldb_map(T, ab, 1, &lba, &run) != 0) {
			die("sample block not in the table", 0);
		}
		raw_read(part, lba, raw0, 1);
		for (unsigned k = 0; k < LDB_BLOCK; k += 8) {
			seed = seed * 0x100000001b3ull + 0x9e3779b97f4a7c15ull + k;
			memcpy(buf + k, &seed, 8);
		}
#ifdef LDB_TEST_NO_PIN
		long r = LDB_BLOCK;             /* copy-on-write file systems (btrfs) would move the blocks; f2fs writes a pinned file in place */
#else
		long r = sc(SYS_pwrite, fd, (long)buf, LDB_BLOCK, (long)(ab * LDB_BLOCK), 0);
#endif
		if (r != LDB_BLOCK) {
			die("write through the file", r < 0 ? r : 0);
		}
		r = sc(SYS_fsync, fd, 0, 0, 0, 0);
		if (r < 0) {
			die("fsync", r);
		}
#ifdef LDB_TEST_NO_PIN
		if (!test_fault("no-mirror")) {
			raw_write(part, lba, buf, 1);
		}
#endif
		raw_read(part, lba, raw1, 1);
		bool same = true;
		for (unsigned k = 0; k < LDB_BLOCK; k++) {
			same = same && raw0[k] == raw1[k];
		}
		if (same) {
			out(2, "ldbhelper: area block ");
			num(2, ab);
			out(2, " did not change on the raw partition at LBA ");
			num(2, lba);
			out(2, "\n");
			die("the table does not describe this file: do not install", 0);
		}
	}
	/* The record: write refuses without it. On /data: a reset takes it away. */
	record_write(path, fd, REC_MAPPED);
	out(1, "check-map ok: ");
	num(1, MAP_SAMPLES);
	out(1, " samples: a write through the file changes the raw block the table names\n");
}
static void
cmd_write(const char *partdev, const char *path)
{
	/*
	 * The table can be stale: the file removed, /data reset, the file moved. ldb_lba_allowed cannot see that. So: this file, pinned, immutable (check-map passed), with
	 * the blocks of the table, and a record of check-map for this table, before the first block of a 12 GB write.
	 */
	long fd = open_or_die(path, O_RDONLY, 0);
	record_need(path, fd, REC_MAPPED);
	need_immutable(fd);
	file_checks(fd);
	/* O_SYNC: every frame is on flash when pwrite returns; O_DIRECT: no page cache of the partition to go stale */
	long part = open_part(partdev, O_RDWR | O_SYNC | O_DIRECT);
	uint64_t frames = 0, blocks = 0;
	/* from here until verify the area has no valid image: seal refuses. An old seal does not survive either. */
	record_write(path, fd, REC_MAPPED);
	{
		static uint8_t zero[LDB_BLOCK] __attribute__((aligned(4096)));
		uint64_t lba;
		uint32_t run;
		if (ldb_map(T, 0, 1, &lba, &run) != 0) {
			die("no area block 0", 0);
		}
		raw_write(part, lba, zero, 1);
	}
	for (;;) {
		struct frame f;
		read_exact(0, &f, sizeof(f), "frame header");
		for (unsigned i = 0; i < 8; i++) {
			if (f.magic[i] != "LDBFRAME"[i]) {
				die("bad frame", 0);
			}
		}
		if (f.blocks == 0) {
			break;
		}
		/* the area header stays away from an image: seal writes it */
		if (f.blocks > FRAME_BLOCKS || f.area_block < LDB_RESERVED_BLOCKS || f.area_block >= T->area_blocks) {
			die("frame out of range", 0);
		}
		if (f.flags & FRAME_FLAG_ZERO) {
			memset(buf, 0, f.blocks * LDB_BLOCK);
		} else {
			read_exact(0, buf, f.blocks * LDB_BLOCK, "frame data");
		}
		if (ldb_hash_add(LDB_HASH_INIT, buf, f.blocks * LDB_BLOCK) != f.hash) {
			die("frame hash wrong", 0);
		}
		uint32_t done = 0;
		while (done < f.blocks) {
			uint64_t lba;
			uint32_t run;
			if (ldb_map(T, f.area_block + done, f.blocks - done, &lba, &run) != 0) {
				die("frame not in the table", 0);
			}
			raw_write(part, lba, buf + done * LDB_BLOCK, run);
			done += run;
		}
		frames++;
		blocks += f.blocks;
		if (frames % RECHECK_FRAMES == 0) {
			file_checks(fd);
			num(1, blocks >> 8);
			out(1, " MiB\n");
		}
	}
	file_checks(fd);
	out(1, "write ok: ");
	num(1, frames);
	out(1, " frames, ");
	num(1, blocks);
	out(1, " blocks\n");
}
static void
cmd_verify(const char *partdev, const char *path)
{
	long fd = open_or_die(path, O_RDONLY, 0);
	record_need(path, fd, REC_MAPPED);
	file_checks(fd);
	long part = open_part(partdev, O_RDONLY | O_DIRECT);
	uint64_t frames = 0, bad = 0;
	for (;;) {
		struct frame f;
		read_exact(0, &f, sizeof(f), "index entry");
		if (f.blocks == 0) {
			break;
		}
		if (f.blocks > FRAME_BLOCKS) {
			die("index entry out of range", 0);
		}
		uint32_t done = 0;
		while (done < f.blocks) {
			uint64_t lba;
			uint32_t run;
			if (ldb_map(T, f.area_block + done, f.blocks - done, &lba, &run) != 0) {
				die("index entry not in the table", 0);
			}
			raw_read(part, lba, buf + done * LDB_BLOCK, run);
			done += run;
		}
		if (ldb_hash_add(LDB_HASH_INIT, buf, f.blocks * LDB_BLOCK) != f.hash) {
			if (++bad <= 8) {
				out(1, "mismatch at area block ");
				num(1, f.area_block);
				out(1, "\n");
			}
		}
		frames++;
	}
	out(1, "verify: ");
	num(1, frames);
	out(1, " frames, ");
	num(1, bad);
	out(1, " wrong\n");
	if (bad) {
		die("the raw blocks are not the image", 0);
	}
	if (frames == 0) {
		die("the index has no frames", 0);
	}
	record_write(path, fd, REC_VERIFIED);
}
static void
cmd_read(const char *partdev, uint64_t ab, uint64_t count)
{
	long part = open_or_die(partdev, O_RDONLY | O_DIRECT, 0);
	while (count) {
		uint64_t lba;
		uint32_t run;
		if (ldb_map(T, ab, count > FRAME_BLOCKS ? FRAME_BLOCKS : (uint32_t)count, &lba, &run) != 0) {
			die("block not in the table", 0);
		}
		raw_read(part, lba, buf, run);
		const uint8_t *p = buf;
		uint64_t left = run * LDB_BLOCK;
		while (left) {
			long w = sc(SYS_write, 1, (long)p, (long)left, 0, 0);
			if (w <= 0) {
				die("write to stdout", w);
			}
			p += w;
			left -= (uint64_t)w;
		}
		ab += run;
		count -= run;
	}
}
struct seal_walk {
	uint64_t covered;
	const char *why;
};
static void
seal_extent(uint64_t l, uint64_t p, uint64_t len, uint32_t flags, void *ctx)
{
	/* The table merged neighbours: walk the table with what FIEMAP says */
	struct seal_walk *w = ctx;
	if (w->why) {
		return;
	}
	/* the same list as op10tool: LAST, DATA_ENCRYPTED, MERGED. Unwritten, delayed, shared, encoded: not a plain allocated block */
	if (flags & ~(0x1u | 0x80u | 0x1000u)) {
		w->why = "FIEMAP shows blocks that are not plain allocated blocks";
		return;
	}
	if (l % LDB_BLOCK || p % LDB_BLOCK || len % LDB_BLOCK) {
		w->why = "FIEMAP not block aligned";
		return;
	}
	uint64_t ab = l / LDB_BLOCK, pb = p / LDB_BLOCK, left = len / LDB_BLOCK;
	if (ab != w->covered) {
		w->why = "FIEMAP has a hole";
		return;
	}
	while (left) {
		uint64_t lba;
		uint32_t run;
		if (ldb_map(T, ab, left > 0xffffffffu ? 0xffffffffu : (uint32_t)left, &lba, &run) != 0) {
			w->why = "the file is longer than the table";
			return;
		}
		if (lba != T->part_first + pb) {
			w->why = "the file moved: FIEMAP no longer matches the table";
			return;
		}
		ab += run;
		pb += run;
		left -= run;
	}
	w->covered = ab;
}
/* Same device size as the table says: another partition, or another phone's table, stops here. */
static long
open_part(const char *partdev, long flags)
{
	long part = open_or_die(partdev, flags, 0);
	long size = sc(SYS_lseek, part, 0, 2 /* SEEK_END */, 0, 0);
	if (size < 0 || (uint64_t)size != T->part_blocks * LDB_BLOCK) {
		die("the partition device has another size than the table says", 0);
	}
	return part;
}
static uint32_t
fiemap_is_table(long fd, uint32_t fm_flags)
{
	struct seal_walk w = { 0, NULL };
	walk_fiemap(fd, fm_flags, seal_extent, &w);
	if (w.why) {
		die(w.why, 0);
	}
	if (w.covered != T->area_blocks) {
		die("the file is shorter than the table", 0);
	}
	return 0;
}
/* Before the first raw block of each command: this file is pinned and has the blocks of the table. pin_ensure can dirty the inode: never on a frozen /data (it would also hang there: mnt_want_write_file). */
static uint32_t
file_checks(long fd)
{
#ifdef LDB_TEST_NO_PIN
	if (test_fault("no-file-check")) {
		return 0;
	}
#endif
	uint32_t failures = pin_ensure(fd);
	if (failures >= PIN_FAILURES_REFUSE) {
		die("f2fs tried to move this file too often (it clears the pin at 2048): stop, see dual-boot.md", 0);
	}
	fiemap_is_table(fd, FIEMAP_FLAG_SYNC);
	return failures;
}
static void
sleep_ms(long ms)
{
	long ts[2] = { ms / 1000, (ms % 1000) * 1000000 };
	sc(SYS_nanosleep, (long)ts, 0, 0, 0, 0);
}
static long
do_freeze(long fd)
{
#ifdef LDB_TEST_NO_PIN
	out(1, "TEST freeze\n");
	return test_fault("freeze") ? -EINVAL_ : 0;
#else
	return sc(SYS_ioctl, fd, FIFREEZE, 0, 0, 0);
#endif
}
static void
do_thaw(long fd, const char *who)
{
#ifdef LDB_TEST_NO_PIN
	(void)fd;
	out(1, "TEST thaw ");
	out(1, who);
	out(1, "\n");
#else
	(void)who;
	sc(SYS_ioctl, fd, FITHAW, 0, 0, 0);
#endif
}
/* A failed seal: the header that went out says OFF, /data runs again. */
static void
seal_undo(void)
{
	long part = header_part, fd = frozen_fd;
	header_part = -1;
	frozen_fd = -1;
	if (part >= 0) {
		static uint8_t off[LDB_BLOCK] __attribute__((aligned(4096)));
		struct ldb_header h;
		memset(off, 0, sizeof(off));
		memset(&h, 0, sizeof(h));
		memcpy(h.magic, LDB_HDR_MAGIC, 8);
		h.version = LDB_HDR_VERSION;
		h.state = LDB_STATE_OFF;
		h.table_id = T->table_id;
		h.table_hash = T->hash;
		h.area_blocks = T->area_blocks;
		h.hash = ldb_header_hash(&h);
		memcpy(off, &h, sizeof(h));
		/* no raw_write: it would call die again. ldb_map gave this LBA and ldb_lba_allowed passed it for the header that is there now */
		if (sc(SYS_pwrite, part, (long)off, LDB_BLOCK, (long)((header_lba - T->part_first) * LDB_BLOCK), 0) != LDB_BLOCK) {
			out(2, "ldbhelper: the area header could not be set to OFF. The next Android write changes the fingerprint: the kernel stays off\n");
		}
		sc(SYS_fsync, part, 0, 0, 0, 0);
	}
	if (fd >= 0) {
		do_thaw(fd, "undo");
		if (watchdog_pid > 0) {
			sc(SYS_kill, watchdog_pid, SIG_KILL, 0, 0, 0);
		}
	}
}
/* The helper can die while /data is frozen (kill -9, a crash): the freeze stays after it. This child ends that. A thaw at the wrong time only costs a false refusal: Android's next checkpoint changes the fingerprint. */
static void
start_watchdog(long fd)
{
	long pid = sc(SYS_clone, SIG_CHLD, 0, 0, 0, 0);
	if (pid == 0) {
#ifdef LDB_TEST_NO_PIN
		sleep_ms(test_fault("kill-frozen") ? 300 : 1000 * WATCHDOG_THAW_SECONDS);
		do_thaw(fd, "watchdog");
#else
		sc(SYS_close, 0, 0, 0, 0, 0);
		sc(SYS_close, 1, 0, 0, 0, 0);
		sc(SYS_close, 2, 0, 0, 0, 0);
		sleep_ms(1000 * WATCHDOG_THAW_SECONDS);
		do_thaw(fd, "watchdog");
#endif
		sc(SYS_exit, 0, 0, 0, 0, 0);
	}
	if (pid < 0) {
		die("cannot start the thaw watchdog", pid);
	}
	watchdog_pid = pid;
}
/* adb can go away while /data is frozen: only SIGKILL ends this process now. */
static void
ignore_signals(void)
{
	static const int sigs[] = { 1 /* HUP */, 2 /* INT */, 13 /* PIPE */, 15 /* TERM */ };
	for (unsigned i = 0; i < sizeof(sigs) / sizeof(sigs[0]); i++) {
		long act[4] = { 1 /* SIG_IGN */, 0, 0, 0 };
		sc(SYS_rt_sigaction, sigs[i], (long)act, 0, 8, 0);
	}
}
/*
 * The seal. Required property: no header state lets the kernel write against a filesystem that changed since the last verified pin and FIEMAP check. So the check and
 * the fingerprint happen in one frozen period, and then this kernel restarts at once: no unmount, so no CP_UMOUNT checkpoint that would change the fingerprint.
 * After this function the kernel on slot b compares; there is no state left that passes without that compare. docs/laurel_sprout/dual-boot.md.
 */
static void
cmd_seal(const char *partdev, const char *fsdev, const char *path)
{
	long fd = open_or_die(path, O_RDONLY, 0);
	record_need(path, fd, REC_VERIFIED);
	need_immutable(fd);
	uint32_t failures = file_checks(fd);    /* not frozen yet: can pin */
	uint64_t fp[LDB_FP_BLOCKS], fp1[LDB_FP_BLOCKS], fp2[LDB_FP_BLOCKS];
	fp_locate(fsdev, fp);
	static uint8_t raw[LDB_BLOCK] __attribute__((aligned(4096))), back[LDB_BLOCK] __attribute__((aligned(4096)));
	long part = open_part(partdev, O_RDWR | O_SYNC | O_DIRECT);
	uint64_t lba;
	uint32_t run;
	if (ldb_map(T, 0, 1, &lba, &run) != 0) {
		die("no area block 0", 0);
	}
	raw_read(part, lba, raw, 1);
	struct ldb_header old, h;
	memcpy(&old, raw, sizeof(old));
	bool had = true;
	for (unsigned i = 0; i < 8; i++) {
		had = had && old.magic[i] == LDB_HDR_MAGIC[i];
	}
	ignore_signals();
	sc(SYS_sync, 0, 0, 0, 0, 0);            /* the other file systems, and less work for the freeze: they get no unmount either */
	long r = -1;
	for (unsigned i = 0; i < FREEZE_TRIES; i++) {
		r = do_freeze(fd);
		if (r != -EINVAL_) {
			break;
		}
		sleep_ms(500);
	}
	if (r < 0) {
		die("cannot freeze /data; nothing was written", r);
	}
	frozen_fd = fd;
	start_watchdog(fd);
	/* ---- frozen: no SET_PIN, no FIEMAP_FLAG_SYNC, nothing that needs a write to /data ---- */
#ifdef LDB_TEST_NO_PIN
	if (test_fault("kill-frozen")) {
		sc(SYS_exit, 137, 0, 0, 0, 0);          /* as a kill -9: no undo code runs */
	}
#endif
	if (pin_failures(fd) >= PIN_FAILURES_REFUSE) {
		die("f2fs tried to move this file too often: stop", 0);
	}
	fiemap_is_table(fd, 0);
	fp_hash(part, fp, fp1);
	memset(&h, 0, sizeof(h));
	memcpy(h.magic, LDB_HDR_MAGIC, 8);
	h.version = LDB_HDR_VERSION;
	h.state = LDB_STATE_BOUND;
	h.table_id = T->table_id;
	h.table_hash = T->hash;
	h.area_blocks = T->area_blocks;
	h.seal_generation = (had && old.table_id == T->table_id ? old.seal_generation : 0) + 1;
	for (unsigned i = 0; i < LDB_FP_BLOCKS; i++) {
		h.fp_part_block[i] = fp[i];
		h.fp_hash[i] = fp1[i];
	}
	h.hash = ldb_header_hash(&h);
	const char *why = ldb_header_check(&h, T);
	if (why) {
		die(why, 0);
	}
	memset(raw, 0, sizeof(raw));
	memcpy(raw, &h, sizeof(h));
	header_lba = lba;
	header_part = part;                     /* from here die() sets the header to OFF */
	raw_write(part, lba, raw, 1);
	r = sc(SYS_fsync, part, 0, 0, 0, 0);
	if (r < 0) {
		die("fsync of the partition", r);
	}
	raw_read(part, lba, back, 1);
	for (unsigned k = 0; k < LDB_BLOCK; k++) {
		if (raw[k] != back[k]) {
			die("the area header reads back wrong", 0);
		}
	}
	fp_hash(part, fp, fp2);
#ifdef LDB_TEST_NO_PIN
	if (test_fault("fp-race")) {
		fp2[1] ^= 1;
	}
#endif
	for (unsigned i = 0; i < LDB_FP_BLOCKS; i++) {
		if (fp1[i] != fp2[i]) {
			die("the fingerprint changed on a frozen /data", 0);
		}
	}
	out(1, "sealed: generation ");
	num(1, h.seal_generation);
	out(1, ", pin failures ");
	num(1, failures);
	out(1, ", /data frozen, reboot now\n");
	sleep_ms(300);                          /* the line reaches the host before USB goes away */
#ifdef LDB_TEST_NO_PIN
	if (!test_fault("reboot")) {
		out(1, "TEST reboot\n");
		sc(SYS_kill, watchdog_pid, SIG_KILL, 0, 0, 0);
		sc(SYS_exit, 0, 0, 0, 0, 0);
	}
	r = -EPERM_;
#else
	r = sc(SYS_reboot, 0xfee1deadl, 672274793l, 0x01234567l /* LINUX_REBOOT_CMD_RESTART: no sync, no unmount */, 0, 0);
#endif
	die("the reboot call came back", r);
}
/* Remove: the header and the HFS+ volume header must not stay in blocks that Android gets back. */
static void
cmd_wipe(const char *partdev, const char *path)
{
	long fd = open_or_die(path, O_RDONLY, 0);
	file_checks(fd);
	long part = open_part(partdev, O_RDWR | O_SYNC | O_DIRECT);
	static const uint64_t which[2] = { 0, LDB_RESERVED_BLOCKS };
	static uint8_t raw[LDB_BLOCK] __attribute__((aligned(4096)));
	for (unsigned i = 0; i < 2; i++) {
		uint64_t lba;
		uint32_t run;
		if (ldb_map(T, which[i], 1, &lba, &run) != 0) {
			die("block not in the table", 0);
		}
		memset(raw, 0, sizeof(raw));
		raw_write(part, lba, raw, 1);
		raw_read(part, lba, raw, 1);
		for (unsigned k = 0; k < LDB_BLOCK; k++) {
			if (raw[k]) {
				die("a zeroed block reads back non-zero", 0);
			}
		}
	}
	long r = sc(SYS_fsync, part, 0, 0, 0, 0);
	if (r < 0) {
		die("fsync of the partition", r);
	}
	out(1, "wiped: area header and HFS+ header are zero\n");
}
static void
cmd_unlink(const char *path)
{
	long fd = sc(SYS_openat, AT_FDCWD, (long)path, O_RDONLY, 0, 0);
	if (fd < 0) {
		die(path, fd);
	}
#ifndef LDB_TEST_NO_PIN
	long flags = get_flags(fd) & ~(long)FS_IMMUTABLE_FL;
	long r = sc(SYS_ioctl, fd, FS_IOC_SETFLAGS, (long)&flags, 0, 0);
	if (r < 0) {
		die("FS_IOC_SETFLAGS", r);
	}
#else
	long r;
#endif
	static char p[512];
	record_path(p, path);
	sc(SYS_unlinkat, AT_FDCWD, (long)p, 0, 0, 0);
	r = sc(SYS_unlinkat, AT_FDCWD, (long)path, 0, 0, 0);
#ifdef LDB_TEST_NO_PIN
	if (test_fault("unlink")) {
		r = -EPERM_;
	}
#endif
	if (r < 0) {
		die("cannot remove the file", r);
	}
	r = sc(SYS_syncfs, fd, 0, 0, 0, 0);
	sc(SYS_close, fd, 0, 0, 0, 0);
	if (r < 0) {
		die("syncfs", r);
	}
	if (sc(SYS_openat, AT_FDCWD, (long)path, O_RDONLY, 0, 0) != -ENOENT) {
		die("the file is still there", 0);
	}
	out(1, "removed\n");
}
static void
usage(void)
{
	die("usage: version | check TABLE | alloc PATH BYTES PARTDEV FSDEV | map PATH | check-map TABLE PATH PARTDEV | lock PATH | write TABLE PARTDEV PATH | verify TABLE PARTDEV PATH | read TABLE PARTDEV BLOCK COUNT | seal TABLE PARTDEV FSDEV PATH | wipe TABLE PARTDEV PATH | unlink-only PATH", 0);
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
	} else if (argc < 3) {
		usage();
	} else if (streq(c, "check") && argc == 3) {
		load_table(argv[2]);
		out(1, "table ok: ");
		num(1, T->count);
		out(1, " extents, ");
		num(1, T->area_blocks >> 8);
		out(1, " MiB\n");
	} else if (streq(c, "alloc") && argc == 6) {
		cmd_alloc(argv[2], parse(argv[3]), argv[4], argv[5]);
	} else if (streq(c, "map") && argc == 3) {
		cmd_map(open_or_die(argv[2], O_RDONLY, 0));
	} else if (streq(c, "lock") && argc == 3) {
		cmd_lock(argv[2]);
	} else if (streq(c, "check-map") && argc == 5) {
		load_table(argv[2]);
		cmd_check_map(argv[3], argv[4]);
	} else if (streq(c, "write") && argc == 5) {
		load_table(argv[2]);
		cmd_write(argv[3], argv[4]);
	} else if (streq(c, "verify") && argc == 5) {
		load_table(argv[2]);
		cmd_verify(argv[3], argv[4]);
	} else if (streq(c, "read") && argc == 6) {
		load_table(argv[2]);
		cmd_read(argv[3], parse(argv[4]), parse(argv[5]));
	} else if (streq(c, "seal") && argc == 6) {
		load_table(argv[2]);
		cmd_seal(argv[3], argv[4], argv[5]);
	} else if (streq(c, "wipe") && argc == 5) {
		load_table(argv[2]);
		cmd_wipe(argv[3], argv[4]);
		cmd_unlink(argv[4]);
	} else if (streq(c, "unlink-only") && argc == 3) {
		cmd_unlink(argv[2]);
	} else {
		usage();
	}
	sc(SYS_exit, 0, 0, 0, 0, 0);
	for (;;) {
	}
}
