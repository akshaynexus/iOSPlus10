/*
 * Host test of laurel_a64emu: one static AArch64 program, no libc.
 *   qemu-aarch64 -cpu max    harness native CLASS CASES SEED OUT   the real word
 *   qemu-aarch64 -cpu cortex-a53 harness emu CLASS CASES SEED OUT  the same case stream: the word traps, SIGILL, the kernel's C and asm run it
 *   ... harness dump CLASS N SEED                                  one case, in full, in the mode the CPU gives
 *   ... harness rules | threads                                    fault paths, single step; concurrency on real threads
 * Both runs write one record per case (word, template, mark, hash of x0-x30, SP, NZCV, V0-V31, FPSR, the memory window). compare.py
 * compares the two files. The word itself is the truth, under a CPU that has the feature.
 */
#include "laurel_a64emu.h"
#include <stddef.h>

typedef uint64_t u64;
typedef uint32_t u32;
typedef uint16_t u16;
typedef uint8_t u8;
typedef int64_t s64;

long sys6(long nr, long a, long b, long c, long d, long e, long f);
#define SYS_write 64
#define SYS_openat 56
#define SYS_close 57
#define SYS_exit_group 94
#define SYS_mmap 222
#define SYS_mprotect 226
#define SYS_munmap 215
#define SYS_rt_sigaction 134
#define SYS_sigaltstack 132
#define SYS_futex 98
#define SYS_clock_gettime 113
#define SYS_gettid 178

void *memset(void *d, int c, size_t n)
{
	volatile u8 *p = d;
	while (n--) {
		*p++ = (u8)c;
	}
	return d;
}
void *memcpy(void *d, const void *s, size_t n)
{
	volatile u8 *p = d;
	const volatile u8 *q = s;
	while (n--) {
		*p++ = *q++;
	}
	return d;
}
static size_t slen(const char *s)
{
	size_t n = 0;
	while (s[n]) {
		n++;
	}
	return n;
}
static void wr(int fd, const char *s)
{
	sys6(SYS_write, fd, (long)s, (long)slen(s), 0, 0, 0);
}
static void out_u(u64 v)
{
	char b[24];
	int i = 23;
	b[i] = 0;
	if (!v) {
		b[--i] = '0';
	}
	while (v) {
		b[--i] = (char)('0' + v % 10);
		v /= 10;
	}
	wr(1, b + i);
}
static void out_x(u64 v)
{
	char b[17];
	for (int i = 15; i >= 0; i--) {
		b[i] = "0123456789abcdef"[v & 15];
		v >>= 4;
	}
	b[16] = 0;
	wr(1, b);
}
static int streq(const char *a, const char *b)
{
	while (*a && *a == *b) {
		a++;
		b++;
	}
	return *a == *b;
}
static u64 parse_u(const char *s)
{
	u64 v = 0;
	while (*s >= '0' && *s <= '9') {
		v = v * 10 + (u64)(*s++ - '0');
	}
	return v;
}
static void die(const char *s)
{
	wr(2, s);
	wr(2, "\n");
	sys6(SYS_exit_group, 2, 0, 0, 0, 0, 0);
}

/* ---- signals ---- */
struct ksigaction {
	void (*handler)(int, void *, void *);
	u64 flags;
	void (*restorer)(void);
	u64 mask;
};
void sigret_tramp(void);
#define SA_SIGINFO 4
#define SA_ONSTACK 0x08000000
#define SA_NODEFER 0x40000000
#define SA_RESTORER 0x04000000
#define SIGILL 4
#define SIGBUS 7
#define SIGSEGV 11

struct sigctx {
	u64 fault_address;
	struct a64emu_regs r;   /* x[31], sp, pc, pstate */
	u32 pad;
	u8 reserved[4096] __attribute__((aligned(16)));
};
struct fpsimd {
	u32 magic, size, fpsr, fpcr;
	u64 v[32][2];
};
static inline struct sigctx *
uc_ctx(void *uc)
{
	return (struct sigctx *)((u8 *)uc + 176);
}
static struct fpsimd *
ctx_fp(struct sigctx *sc)
{
	u8 *p = sc->reserved;
	for (;;) {
		u32 magic = *(u32 *)p, size = *(u32 *)(p + 4);
		if (magic == 0x46508001) {
			return (struct fpsimd *)p;
		}
		if (!magic || !size) {
			die("no fpsimd record in the signal frame");
		}
		p += size;
	}
}

extern const u64 __start_a64emu_recover[], __stop_a64emu_recover[];

/* state of one case */
enum { MARK_OK = 0, MARK_ILL = 1, MARK_SEGV = 2, MARK_BUS = 3 };
static volatile int g_native;
static volatile int g_mark;
static volatile u32 g_fz16;
static volatile u64 g_exit;     /* where a case that ends in a signal goes */
static volatile int g_lazy_fixes;       /* rules: faults that were fixed, as vm_fault would */
static volatile u64 g_lazy_addr;
static u64 g_counts[A64E_NCLASS];

static void
segv_handler(int sig, void *si, void *uc)
{
	struct sigctx *sc = uc_ctx(uc);
	u64 pc = sc->r.pc;

	(void)si;
	for (const u64 *t = __start_a64emu_recover; t < __stop_a64emu_recover; t += 3) {
		if (pc >= t[0] && pc < t[1]) {
			/* a fault in the LL/SC or load code: as handle_kernel_abort(). A lazy page is fixed and the access runs again; else recovery */
			if (g_lazy_addr && (sc->fault_address & ~0xfffULL) == g_lazy_addr) {
				sys6(SYS_mprotect, (long)g_lazy_addr, 4096, 3, 0, 0, 0);
				g_lazy_addr = 0;
				g_lazy_fixes++;
				return;
			}
			sc->r.x[0] = 14;
			sc->r.pc = t[2];
			return;
		}
	}
	/* native: the word itself faulted */
	g_mark = sig == SIGSEGV ? MARK_SEGV : MARK_BUS;
	sc->r.pc = g_exit;
}

static void
ill_handler(int sig, void *si, void *uc)
{
	struct sigctx *sc = uc_ctx(uc);

	(void)sig;
	(void)si;
	if (g_native) {
		g_mark = MARK_ILL;
		sc->r.pc = g_exit;
		return;
	}
	struct fpsimd *fp = ctx_fp(sc);
	u32 fpcr = fp->fpcr | g_fz16;
	struct a64emu_cpu c = { &sc->r, fp->v, &fp->fpsr, &fpcr, 1ULL << 47, 0, false };
	struct a64emu_out o;
	u32 word = *(u32 *)sc->r.pc;
	enum a64emu_result res = a64emu_run(&c, word, &o);
	if (o.cls >= 0) {
		g_counts[o.cls]++;
	}
	switch (res) {
	case A64EMU_OK:
		break;
	case A64EMU_UNKNOWN:
		g_mark = MARK_ILL;
		sc->r.pc = g_exit;
		break;
	case A64EMU_FAULT:
		g_mark = MARK_SEGV;
		sc->r.pc = g_exit;
		break;
	case A64EMU_ALIGN:
	case A64EMU_SP_ALIGN:
		g_mark = MARK_BUS;
		sc->r.pc = g_exit;
		break;
	case A64EMU_RETRY:
		/* return to the word: it traps again */
		break;
	}
}

static u8 altstack[1 << 16] __attribute__((aligned(16)));
static void
set_handlers(void)
{
	struct { void *sp; int flags; size_t size; } ss = { altstack, 0, sizeof(altstack) };
	sys6(SYS_sigaltstack, (long)&ss, 0, 0, 0, 0, 0);
	struct ksigaction a = { ill_handler, SA_SIGINFO | SA_ONSTACK | SA_NODEFER | SA_RESTORER, sigret_tramp, 0 };
	sys6(SYS_rt_sigaction, SIGILL, (long)&a, 0, 8, 0, 0);
	struct ksigaction b = { segv_handler, SA_SIGINFO | SA_ONSTACK | SA_NODEFER | SA_RESTORER, sigret_tramp, 0 };
	sys6(SYS_rt_sigaction, SIGSEGV, (long)&b, 0, 8, 0, 0);
	sys6(SYS_rt_sigaction, SIGBUS, (long)&b, 0, 8, 0, 0);
}

/* ---- one case ---- */
struct st {
	u64 x[31];
	u64 sp;
	u64 nzcv;
	u64 v[32][2];
	u64 fpsr;
	u64 fpcr;
};
_Static_assert(offsetof(struct st, sp) == 248, "st");
_Static_assert(offsetof(struct st, nzcv) == 256, "st");
_Static_assert(offsetof(struct st, v) == 264, "st");
_Static_assert(offsetof(struct st, fpsr) == 776, "st");
_Static_assert(offsetof(struct st, fpcr) == 784, "st");

void run_case(struct st *);
extern u32 code_buf[];
extern void case_exit(void);

static inline u32
enc_b(const u32 *from, const void *to)
{
	s64 d = ((const u8 *)to - (const u8 *)from) >> 2;
	return 0x14000000u | ((u32)d & 0x03ffffffu);
}

/* memory window */
#define MEMSZ 2048
static u8 mem[MEMSZ + 64] __attribute__((aligned(4096)));
#define CELL (mem + MEMSZ / 2)

static u64 rs;
static inline u64
rnd(void)
{
	rs ^= rs << 13;
	rs ^= rs >> 7;
	rs ^= rs << 17;
	return rs;
}

static const u16 pool16[] = {
	0x0000, 0x8000, 0x7c00, 0xfc00, 0x7e00, 0xfe00, 0x7d00, 0xfd00, 0x7c01, 0x7e01, 0x0001, 0x8001, 0x03ff, 0x83ff, 0x0400, 0x8400,
	0x7bff, 0xfbff, 0x3c00, 0xbc00, 0x3800, 0xb800, 0x4000, 0xc000, 0x3e00, 0x4200, 0x3555, 0x0100, 0x00ff, 0x0200, 0x7400, 0x73ff,
	0x3bff, 0x3c01, 0x47ff, 0x4800, 0x5000, 0x6000, 0x77ff, 0x7800,
};
static const u32 pool32[] = {
	0, 0x80000000, 0x7f800000, 0xff800000, 0x7fc00000, 0xffc00000, 0x7fa00000, 0xffa00000, 0x7f800001, 0x7fc00001, 1, 0x80000001, 0x007fffff, 0x807fffff,
	0x00800000, 0x80800000, 0x7f7fffff, 0xff7fffff, 0x3f800000, 0xbf800000, 0x3f000000, 0xbf000000, 0x40000000, 0xc0000000, 0x3fc00000, 0x40400000,
	0x33800000, 0x38800000, 0x477fe000, 0x47800000,
};
static const u64 pool64[] = {
	0, 0x8000000000000000ULL, 0x7ff0000000000000ULL, 0xfff0000000000000ULL, 0x7ff8000000000000ULL, 0xfff8000000000000ULL, 0x7ff4000000000000ULL, 0xfff4000000000000ULL,
	0x7ff0000000000001ULL, 0x7ff8000000000001ULL, 1, 0x8000000000000001ULL, 0x000fffffffffffffULL, 0x0010000000000000ULL, 0x7fefffffffffffffULL, 0xffefffffffffffffULL,
	0x3ff0000000000000ULL, 0xbff0000000000000ULL, 0x3fe0000000000000ULL, 0xbfe0000000000000ULL, 0x4000000000000000ULL, 0xc000000000000000ULL,
	0x41dfffffffc00000ULL, 0x41e0000000000000ULL, 0xc1e0000000000000ULL, 0xc1e0000000200000ULL, 0x41f0000000000000ULL, 0x43e0000000000000ULL, 0xc3e0000000000000ULL,
	0x3fefffffffffffffULL, 0x3ff0000000000001ULL, 0x4330000000000000ULL, 0x4340000000000000ULL, 0x41f0000000500000ULL, 0x4170000000000000ULL,
};

static u64
val16(void)
{
	u64 r = rnd();
	switch (r % 8) {
	case 0: case 1: case 2:
		return pool16[(r >> 8) % (sizeof(pool16) / 2)];
	case 3:         /* numbers near 1, the same exponents: cancellation and ties */
		return (((r >> 8) & 0x8000) | (0x3800 + ((r >> 16) & 0x0c00)) | ((r >> 32) & 0x3ff));
	case 4:         /* denormal or small */
		return ((r >> 8) & 0x8000) | ((r >> 16) & 0x7ff);
	case 5:         /* integers */
		return ((r >> 8) & 0x8000) | ((0x3c00 + ((r >> 16) & 0x3c00)) & 0x7fff) | (r >> 40 & 0x3e0);
	default:
		return (r >> 8) & 0xffff;
	}
}
static u64
val32(void)
{
	u64 r = rnd();
	switch (r % 6) {
	case 0: case 1:
		return pool32[(r >> 8) % (sizeof(pool32) / 4)];
	case 2:
		return ((r >> 8) & 0x80000000u) | (0x3f000000u + ((r >> 16) & 0x01800000u)) | ((r >> 32) & 0x7fffffu);
	case 3:
		return ((r >> 8) & 0x80000000u) | ((r >> 16) & 0x00ffffffu);
	default:
		return (r >> 8) & 0xffffffffu;
	}
}
static u64
val64(void)
{
	u64 r = rnd();
	u64 q = rnd();
	switch (r % 6) {
	case 0: case 1:
		return pool64[(r >> 8) % (sizeof(pool64) / 8)];
	case 2:
		return (q & 0x8000000000000000ULL) | (0x3fe0000000000000ULL + (((r >> 16) & 3) << 52)) | (q & 0x000fffffffffffffULL);
	case 3:         /* large and small for FJCVTZS: the exponent around 2^31 and 2^63 */
		return (q & 0x8000000000000000ULL) | ((u64)(0x41d + ((r >> 16) & 0x3f)) << 52) | (q & 0x000fffffffffffffULL);
	case 4:
		return (q & 0x8000000000000000ULL) | (q & 0x001fffffffffffffULL);
	default:
		return q;
	}
}

static void
fill_v(struct st *s, int kind)
{
	for (int r = 0; r < 32; r++) {
		int k = kind;
		if (k == 9) {   /* mixed by register */
			k = (int)(rnd() % 3);
		}
		u64 w[2];
		if (k == 0) {
			for (int q = 0; q < 2; q++) {
				w[q] = val16() | (val16() << 16) | (val16() << 32) | (val16() << 48);
			}
		} else if (k == 1) {
			for (int q = 0; q < 2; q++) {
				w[q] = val32() | (val32() << 32);
			}
		} else if (k == 2) {
			w[0] = val64();
			w[1] = val64();
		} else {
			w[0] = rnd();
			w[1] = rnd();
		}
		s->v[r][0] = w[0];
		s->v[r][1] = w[1];
	}
}

/* ---- templates: base word, bits that are free ---- */
struct tmpl {
	u32 base, free;
	u8 cls, vkind;  /* vkind: 0 H, 1 S, 2 D, 3 random, 9 mixed */
	u8 kind;        /* see below */
	const char *name;
};
enum { TK_PLAIN, TK_LSE, TK_CAS, TK_CASP, TK_RCPC, TK_LDLAR, TK_BR, TK_BLR, TK_RET, TK_LDRA, TK_PACPAIR, TK_XPAC, TK_PACGA, TK_GPRS };

#define RD   0x0000001Fu
#define RN   0x000003E0u
#define RM   0x001F0000u
#define RA   0x00007C00u
#define R3   (RD | RN | RM)
#define Q    0x40000000u

static const struct tmpl tmpls[] = {
	/* FP16 scalar */
	{ 0x1EE04000, RD | RN | (0x3Fu << 15), A64E_FP16, 0, TK_PLAIN, "s1source" },
	{ 0x1EE02000, RN | RM | (3u << 3), A64E_FP16, 0, TK_PLAIN, "fcmp" },
	{ 0x1EE01000, RD | (0xFFu << 13), A64E_FP16, 0, TK_PLAIN, "fmovimm" },
	{ 0x1EE00400, RN | RM | (0xFu << 12) | 0x1Fu, A64E_FP16, 0, TK_PLAIN, "fccmp" },
	{ 0x1EE00800, R3 | (0xFu << 12), A64E_FP16, 0, TK_PLAIN, "s2source" },
	{ 0x1EE00C00, R3 | (0xFu << 12), A64E_FP16, 0, TK_PLAIN, "fcsel" },
	{ 0x1FC00000, R3 | RA | (1u << 21) | (1u << 15), A64E_FP16, 0, TK_PLAIN, "fmadd" },
	{ 0x1EE00000, RD | RN | (1u << 31) | (0x1Fu << 16), A64E_FP16, 0, TK_GPRS, "fp2int" },
	{ 0x1EC00000, RD | RN | (1u << 31) | (0x1Fu << 16) | (0x3Fu << 10), A64E_FP16, 0, TK_GPRS, "fp2fix" },
	/* FP16 SIMD */
	{ 0x0E400400, R3 | Q | (1u << 29) | (1u << 23) | (7u << 11), A64E_FP16, 0, TK_PLAIN, "v3same" },
	{ 0x5E400400, R3 | (1u << 29) | (1u << 23) | (7u << 11), A64E_FP16, 0, TK_PLAIN, "s3same" },
	{ 0x0E780800, RD | RN | Q | (1u << 29) | (1u << 23) | (0x1Fu << 12), A64E_FP16, 0, TK_PLAIN, "v2misc" },
	{ 0x5E780800, RD | RN | (1u << 29) | (1u << 23) | (0x1Fu << 12), A64E_FP16, 0, TK_PLAIN, "s2misc" },
	{ 0x5E300800, RD | RN | (1u << 23) | (0x1Fu << 12), A64E_FP16, 0, TK_PLAIN, "spair" },
	{ 0x0E300800, RD | RN | Q | (1u << 23) | (0x1Fu << 12), A64E_FP16, 0, TK_PLAIN, "across" },
	{ 0x0F000000, RD | RN | Q | (1u << 29) | (0xFu << 12) | (1u << 11) | (7u << 19) | (1u << 16) | (7u << 16), A64E_FP16, 0, TK_PLAIN, "vbyelem" },
	{ 0x5F000000, RD | RN | (1u << 29) | (0xFu << 12) | (1u << 11) | (0xFu << 16) | (3u << 20), A64E_FP16, 0, TK_PLAIN, "sbyelem" },
	{ 0x0F100400, RD | RN | Q | (1u << 29) | (0x1Fu << 11) | (0xFu << 16), A64E_FP16, 0, TK_PLAIN, "vfixed" },
	{ 0x5F100400, RD | RN | (1u << 29) | (0x1Fu << 11) | (0xFu << 16), A64E_FP16, 0, TK_PLAIN, "sfixed" },
	{ 0x0F00FC00, RD | RN | Q | (7u << 16), A64E_FP16, 0, TK_PLAIN, "vimm" },
	/* FCMA */
	{ 0x2E00E400, R3 | Q | (3u << 22) | (1u << 12), A64E_FCMA, 9, TK_PLAIN, "fcadd" },
	{ 0x2E00C400, R3 | Q | (3u << 22) | (3u << 11), A64E_FCMA, 9, TK_PLAIN, "fcmla" },
	{ 0x2F001000, R3 | Q | (3u << 22) | (1u << 21) | (3u << 13) | (1u << 11), A64E_FCMA, 9, TK_PLAIN, "fcmlaelem" },
	/* DotProd */
	{ 0x0E809400, R3 | Q | (1u << 29), A64E_DOTPROD, 3, TK_PLAIN, "dot" },
	{ 0x0F80E000, R3 | Q | (1u << 29) | (1u << 21) | (1u << 11), A64E_DOTPROD, 3, TK_PLAIN, "dotelem" },
	/* JSCVT */
	{ 0x1E7E0000, RD | RN, A64E_JSCVT, 2, TK_GPRS, "fjcvtzs" },
	/* FHM */
	{ 0x0E20EC00, R3 | Q | (1u << 23), A64E_FHM, 9, TK_PLAIN, "fmlal" },
	{ 0x2E20CC00, R3 | Q | (1u << 23), A64E_FHM, 9, TK_PLAIN, "fmlal2" },
	{ 0x0F800000, RD | RN | (0xFu << 16) | Q | (3u << 20) | (1u << 11) | (1u << 14), A64E_FHM, 9, TK_PLAIN, "fmlalelem" },
	{ 0x2F808000, RD | RN | (0xFu << 16) | Q | (3u << 20) | (1u << 11) | (1u << 14), A64E_FHM, 9, TK_PLAIN, "fmlal2elem" },
	/* SHA3, SHA512 */
	{ 0xCE000000, R3 | RA, A64E_SHA3, 3, TK_PLAIN, "eor3" },
	{ 0xCE200000, R3 | RA, A64E_SHA3, 3, TK_PLAIN, "bcax" },
	{ 0xCE608C00, R3, A64E_SHA3, 3, TK_PLAIN, "rax1" },
	{ 0xCE800000, R3 | (0x3Fu << 10), A64E_SHA3, 3, TK_PLAIN, "xar" },
	{ 0xCE608000, R3, A64E_SHA3, 3, TK_PLAIN, "sha512h" },
	{ 0xCE608400, R3, A64E_SHA3, 3, TK_PLAIN, "sha512h2" },
	{ 0xCE608800, R3, A64E_SHA3, 3, TK_PLAIN, "sha512su1" },
	{ 0xCEC08000, RD | RN, A64E_SHA3, 3, TK_PLAIN, "sha512su0" },
	/* RDM */
	{ 0x2E008400, R3 | Q | (3u << 22) | (1u << 11), A64E_RDM, 3, TK_PLAIN, "sqrdmlah" },
	{ 0x7E008400, R3 | (3u << 22) | (1u << 11), A64E_RDM, 3, TK_PLAIN, "ssqrdmlah" },
	{ 0x2F00D000, R3 | Q | (3u << 22) | (1u << 21) | (1u << 13) | (1u << 11), A64E_RDM, 3, TK_PLAIN, "sqrdmlahelem" },
	{ 0x7F00D000, R3 | (3u << 22) | (1u << 21) | (1u << 13) | (1u << 11), A64E_RDM, 3, TK_PLAIN, "ssqrdmlahelem" },
	/* LSE */
	{ 0x38200000, RD | RN | RM | (3u << 30) | (3u << 22) | (7u << 12), A64E_LSE, 3, TK_LSE, "ldop" },
	{ 0x38208000, RD | RN | RM | (3u << 30) | (3u << 22), A64E_LSE, 3, TK_LSE, "swp" },
	{ 0x08A07C00, RD | RN | RM | (3u << 30) | (1u << 22) | (1u << 15), A64E_LSE, 3, TK_CAS, "cas" },
	{ 0x08207C00, RD | RN | RM | (1u << 30) | (1u << 22) | (1u << 15), A64E_CASP, 3, TK_CASP, "casp" },
	/* RCpc */
	{ 0x38BFC000, RD | RN | (3u << 30), A64E_RCPC, 3, TK_RCPC, "ldapr" },
	{ 0x19000000, RD | RN | (3u << 30) | (3u << 22) | (0x1FFu << 12), A64E_RCPC, 3, TK_RCPC, "ldapur" },
	{ 0x08DF7C00, RD | RN | (3u << 30), A64E_RCPC, 3, TK_LDLAR, "ldlar" },
	{ 0x089F7C00, RD | RN | (3u << 30), A64E_RCPC, 3, TK_LDLAR, "stllr" },
	/* PAC */
	{ 0xD71F0800, RN | RD | (1u << 10), A64E_PAC, 3, TK_BR, "brab" },
	{ 0xD61F081F, RN | (1u << 10), A64E_PAC, 3, TK_BR, "braz" },
	{ 0xD73F0800, RN | RD | (1u << 10), A64E_PAC, 3, TK_BLR, "blrab" },
	{ 0xD63F081F, RN | (1u << 10), A64E_PAC, 3, TK_BLR, "blraz" },
	{ 0xD65F0BFF, 1u << 10, A64E_PAC, 3, TK_RET, "ret" },
	{ 0xF8200400, RD | RN | (1u << 23) | (1u << 22) | (0x1FFu << 12) | (1u << 11), A64E_PAC, 3, TK_LDRA, "ldra" },
	{ 0xDAC10000, RD | RN | (3u << 10), A64E_PAC, 3, TK_PACPAIR, "pacpair" },
	{ 0xDAC12000, RD | (3u << 10), A64E_PAC, 3, TK_PACPAIR, "pacpairz" },
	{ 0xDAC143E0, RD | (1u << 10), A64E_PAC, 3, TK_XPAC, "xpac" },
	{ 0x9AC03000, R3, A64E_PAC, 3, TK_PACGA, "pacga" },
	/* system: DIT and SB. The native CPU has them; the Apple register has a rule check only */
	{ 0xD53B42A0, RD, A64E_SYSREG, 3, TK_PLAIN, "mrsdit" },
	{ 0xD51B42A0, RD, A64E_SYSREG, 3, TK_PLAIN, "msrdit" },
	{ 0xD503405F, 1u << 8, A64E_SYSREG, 3, TK_PLAIN, "msrditimm" },
	{ 0xD50330FF, 0, A64E_SYSREG, 3, TK_PLAIN, "sb" },
};
#define NTMPL (sizeof(tmpls) / sizeof(tmpls[0]))

#define NOP 0xD503201Fu
static u64 ptr_plain(void)
{
	return (u64)CELL + (rnd() & 0x70);
}

struct plan {
	u32 w0, w1, w2;
	u64 norm_mask;  /* registers to put back after a native run: they hold a signed pointer there, a plain one on this CPU */
	u64 norm_fault; /* the same, only when the word faulted */
	int pacga_rd;
};

/* make one case; the same for both modes */
static void
make_case(const struct tmpl *t, struct st *s, struct plan *p, int native)
{
	u32 w = t->base | ((u32)rnd() & t->free);
	/* SUDOT, USDOT by element (I8MM) share this space. An A13 has no I8MM, the truth CPU has: not in the stream */
	if ((w & 0x9FC0F400) == 0x0F00F000 || (w & 0x9FC0F400) == 0x0F80F000) {
		w &= ~(0xFu << 12);
	}
	int rd = (int)(w & 31), rn = (int)((w >> 5) & 31), rm = (int)((w >> 16) & 31);

	for (int k = 0; k < 31; k++) {
		u64 r = rnd();
		switch (r & 3) {
		case 0: s->x[k] = rnd(); break;
		case 1: s->x[k] = rnd() & 0xffffffffULL; break;
		case 2: s->x[k] = (u64)(s64)(int16_t)(r >> 16); break;
		default: s->x[k] = ((r >> 8) & 1) ? 0 : (rnd() & 0xff); break;
		}
	}
	s->sp = (u64)CELL & ~15ULL;
	s->nzcv = (rnd() & 0xF) << 28;
	s->fpsr = 0;
	{
		u64 r = rnd();
		u64 fpcr = (r & 3) << 22;                       /* RMode */
		if (((r >> 2) & 3) == 0) {
			fpcr |= 1u << 24;                       /* FZ */
		}
		if (((r >> 4) & 3) == 0) {
			fpcr |= 1u << 25;                       /* DN */
		}
		if (((r >> 6) & 7) == 0) {
			fpcr |= 1u << 26;                       /* AHP */
		}
		g_fz16 = ((r >> 9) & 7) == 0 ? (1u << 19) : 0;
		if (native) {
			fpcr |= g_fz16;
		}
		s->fpcr = fpcr;
	}
	fill_v(s, t->vkind);
	{
		volatile u64 *m = (volatile u64 *)mem;
		for (int k = 0; k < MEMSZ / 8; k++) {
			m[k] = rnd();
		}
	}
	p->w0 = NOP;
	p->w1 = w;
	p->w2 = NOP;
	p->norm_mask = 0;
	p->norm_fault = 0;
	p->pacga_rd = -1;
	u32 land = 4;
	u64 target = (u64)&code_buf[land];
	u64 tag = (rnd() & 3) == 0 ? (rnd() & 0xff) << 56 : 0;
	tag &= ~(1ULL << 55);
	switch (t->kind) {
	case TK_LSE:
	case TK_CAS: {
		u32 size = w >> 30;
		u64 a = (u64)CELL + (rnd() & 0x70);
		u64 r = rnd();
		a &= ~((1ULL << size) - 1);
		if ((r & 7) == 0) {
			/* an unaligned atomic: LSE2 inside 16 bytes, a fault across */
			a += (r >> 8) & 15;
		}
		if ((r & 0x70) == 0) {
			a = 0x1000 + ((r >> 8) & 0xff0);        /* unmapped */
		}
		if (rn != 31) {
			s->x[rn] = a | tag;
		}
		/* half of the compares match */
		if (t->kind == TK_CAS && (r & 0x80)) {
			u64 mv = rd == rn ? 0 : 0;
			(void)mv;
			if (rn != 31 && rm != rn && rm != 31 && (a & ((1ULL << size) - 1)) == 0 && a >= (u64)mem) {
				u64 mask = size == 3 ? ~0ULL : (1ULL << (8 << size)) - 1;
				s->x[rm] = (*(volatile u64 *)a) & mask;
			}
		}
		break;
	}
	case TK_CASP: {
		u32 dbl = (w >> 30) & 1;
		u64 a = (u64)CELL + (rnd() & 0x70);
		u64 r = rnd();
		a &= ~15ULL;
		if ((r & 15) == 0) {
			a += (r >> 8) & 8;
		}
		if ((r & 0xF0) == 0) {
			a = 0x1000 + ((r >> 8) & 0xff0);
		}
		if (rn != 31) {
			s->x[rn] = a;
		}
		/* even registers (odd ones are unallocated: both modes must say so) */
		if ((r >> 12) & 3) {
			rm &= ~1;
			rd &= ~1;
			w = (w & ~(RM | RD)) | ((u32)rm << 16) | (u32)rd;
			p->w1 = w;
		}
		if (((r >> 16) & 1) && rm < 30 && rm != rn && rm + 1 != rn && a >= (u64)mem) {
			if (dbl) {
				s->x[rm] = *(volatile u64 *)a;
				s->x[rm + 1] = *(volatile u64 *)(a + 8);
			} else {
				s->x[rm] = *(volatile u32 *)a;
				s->x[rm + 1] = *(volatile u32 *)(a + 4);
			}
		}
		break;
	}
	case TK_RCPC:
	case TK_LDLAR: {
		u32 size = w >> 30;
		u64 a = (u64)CELL + (rnd() & 0x70);
		u64 r = rnd();
		a &= ~((1ULL << size) - 1);
		if ((r & 7) == 0) {
			a += (r >> 8) & 15;
		}
		if ((r & 0x70) == 0) {
			a = 0x1000 + ((r >> 8) & 0xff0);
		}
		if (rn != 31) {
			s->x[rn] = a | tag;
		}
		break;
	}
	case TK_BR:
	case TK_BLR: {
		/* a real pointer, signed in the native run; bit 24 picks the form with Rm */
		int z = !((w >> 24) & 1);
		int key = (w >> 10) & 1;
		if (!z && (rd == rn || rn == 30 || rd == 30)) {
			rn = (rn + 1) % 28 + 1;
			rd = (rn + 2) % 28 + 1;
			w = (w & ~(RN | RD)) | ((u32)rn << 5) | (u32)rd;
			p->w1 = w;
		}
		if (rn == 31 || (z && rn == 30)) {
			rn = 7;
			w = (w & ~RN) | ((u32)rn << 5);
			p->w1 = w;
		}
		s->x[rn] = target;
		if (!z && rd != 31) {
			s->x[rd] = rnd() & 0xffffffffffffULL;
		}
		if (native) {
			if (z) {
				p->w0 = 0xDAC123E0u | ((u32)key << 10) | (u32)rn;       /* PACIZA/PACIZB Xn */
			} else {
				p->w0 = 0xDAC10000u | ((u32)key << 10) | ((u32)rd << 5) | (u32)rn;      /* PACIA/PACIB Xn, Xm|SP */
			}
			p->norm_mask |= 1ULL << rn;
		}
		break;
	}
	case TK_RET: {
		int key = (w >> 10) & 1;
		s->x[30] = target;
		if (native) {
			p->w0 = 0xDAC103FEu | ((u32)key << 10);         /* PACIA/PACIB x30, SP */
			p->norm_mask |= 1ULL << 30;
		}
		break;
	}
	case TK_LDRA: {
		int key = (w >> 23) & 1;
		int wb = (w >> 11) & 1;
		if (rn == 31) {
			rn = 3;
			w = (w & ~RN) | ((u32)rn << 5);
			p->w1 = w;
		}
		if (wb && rn == rd) {
			rd = (rn + 1) % 30;
			w = (w & ~RD) | (u32)rd;
			p->w1 = w;
		}
		/* offset up to 4 KiB either way: keep it inside the window */
		int64_t off = (int64_t)((((w >> 22) & 1) << 9) | ((w >> 12) & 0x1FF));
		if (off & 0x200) {
			off -= 0x400;
		}
		off = off * 8;
		if (off > 512 || off < -512) {
			w &= ~((1u << 22) | (0x1FFu << 12));
			w |= ((u32)(rnd() & 0x3F)) << 12;
			p->w1 = w;
			off = (int64_t)((w >> 12) & 0x1FF) * 8;
		}
		s->x[rn] = ((u64)CELL + (rnd() & 0x70)) & ~7ULL;
		if (rnd() % 16 == 0) {
			s->x[rn] = 0x2000;      /* unmapped */
		}
		if (native) {
			p->w0 = 0xDAC12BE0u | ((u32)key << 10) | (u32)rn;       /* PACDZA/PACDZB Xn */
			if (!wb && rn != rd) {
				p->norm_mask |= 1ULL << rn;
			}
			p->norm_fault |= 1ULL << rn;
		}
		break;
	}
	case TK_PACPAIR: {
		/* PACxx then AUTxx with the same modifier: a real sign and check on -cpu max, two no-ops here. The pointer comes back */
		u32 op = (w >> 10) & 3;
		int zform = (w >> 13) & 1;
		if (rd == 31 || (!zform && rd == rn) || rd == 30) {
			rd = 5;
			if (rn == 5) {
				rn = 6;
			}
			w = (w & ~(RD | RN)) | (zform ? (31u << 5) : ((u32)rn << 5)) | (u32)rd;
		}
		if (zform) {
			rn = 31;
		}
		s->x[rd] = rnd() & 0xffffffffffffULL;
		s->x[rd] &= 0x00007fffffffffffULL;
		p->w1 = (w & ~(7u << 10)) | (op << 10);                 /* PAC */
		p->w2 = (w & ~(7u << 10)) | (op << 10) | (1u << 12);    /* AUT */
		break;
	}
	case TK_XPAC: {
		int d = (w >> 10) & 1;
		s->x[rd] = rnd() & 0x00007fffffffffffULL;
		if (rd == 31) {
			break;
		}
		if (native) {
			p->w0 = 0xDAC123E0u | (d ? (2u << 10) : 0) | (u32)rd;   /* PACIZA or PACDZA */
		}
		break;
	}
	case TK_PACGA:
		p->pacga_rd = rd;
		break;
	default:
		break;
	}
	code_buf[0] = p->w0;
	code_buf[1] = p->w1;
	code_buf[2] = p->w2;
	code_buf[3] = enc_b(&code_buf[3], (void *)case_exit);
	code_buf[4] = enc_b(&code_buf[4], (void *)case_exit);
	__asm__ volatile ("dsb ish; ic ivau, %0; dsb ish; isb" : : "r"(code_buf));
}

static u64
fnv(u64 h, u64 v)
{
	h ^= v;
	h *= 0x100000001b3ULL;
	return h ^ (h >> 29);
}

static u64
hash_state(const struct st *s)
{
	u64 h = 0xcbf29ce484222325ULL;
	for (int k = 0; k < 31; k++) {
		h = fnv(h, s->x[k]);
	}
	h = fnv(h, s->sp);
	h = fnv(h, s->nzcv);
	for (int k = 0; k < 32; k++) {
		h = fnv(h, s->v[k][0]);
		h = fnv(h, s->v[k][1]);
	}
	h = fnv(h, s->fpsr);
	const volatile u64 *m = (const volatile u64 *)mem;
	for (int k = 0; k < MEMSZ / 8; k++) {
		h = fnv(h, m[k]);
	}
	return h;
}

static void
finish_case(struct st *s, const struct st *in, const struct plan *p, int native)
{
	if (native) {
		for (int k = 0; k <= 30; k++) {
			if ((p->norm_mask & (1ULL << k)) || (g_mark != MARK_OK && (p->norm_fault & (1ULL << k)))) {
				s->x[k] = in->x[k];
			}
		}
		if (p->pacga_rd >= 0 && p->pacga_rd != 31 && g_mark == MARK_OK) {
			/* the real word gives a hash in bits 32-63 and 0 in bits 0-31. Our rule (same as the lowering tool): 0 */
			if (s->x[p->pacga_rd] & 0xffffffffULL) {
				die("pacga: the real word has a nonzero low half");
			}
			s->x[p->pacga_rd] = 0;
		}
	}
}

static void
print_state(const char *what, const struct st *s)
{
	wr(1, what);
	wr(1, "\n");
	for (int k = 0; k < 31; k++) {
		wr(1, " x");
		out_u((u64)k);
		wr(1, "=");
		out_x(s->x[k]);
		if (k % 4 == 3) {
			wr(1, "\n");
		}
	}
	wr(1, "\n sp=");
	out_x(s->sp);
	wr(1, " nzcv=");
	out_x(s->nzcv);
	wr(1, " fpsr=");
	out_x(s->fpsr);
	wr(1, " fpcr=");
	out_x(s->fpcr);
	wr(1, "\n");
	for (int k = 0; k < 32; k++) {
		wr(1, " v");
		out_u((u64)k);
		wr(1, "=");
		out_x(s->v[k][1]);
		wr(1, ":");
		out_x(s->v[k][0]);
		if (k % 2 == 1) {
			wr(1, "\n");
		}
	}
}

/* every half-precision value through every one-input FP16 word, in 8 lanes at a time, for each rounding mode with FZ16 off and on */
static const u32 exh_words[] = {
	/* vector .8h: FRINTN M A P Z X I, FCVT*, SCVTF UCVTF, compares with zero, FABS FNEG FSQRT FRECPE FRSQRTE */
	0x4E798800, 0x4E799800, 0x6E798800, 0x4EF98800, 0x4EF99800, 0x6E799800, 0x6EF99800,
	0x4E79A800, 0x4E79B800, 0x4E79C800, 0x4EF9A800, 0x4EF9B800,
	0x6E79A800, 0x6E79B800, 0x6E79C800, 0x6EF9A800, 0x6EF9B800,
	0x4E79D800, 0x6E79D800, 0x4EF8C800, 0x4EF8D800, 0x4EF8E800, 0x6EF8C800, 0x6EF8D800,
	0x4EF8F800, 0x6EF8F800, 0x6EF9F800, 0x4EF9D800, 0x6EF9D800,
};
static const u32 exh_scalar[] = { 0x5EF9F800 /* FRECPX */, 0x1EE0C000 /* FABS h0 */, 0x1EE1C000 /* FSQRT */ };

static int
exh_main(const char *mode, const char *path)
{
	int native = streq(mode, "native");
	long fd = sys6(SYS_openat, -100, (long)path, 01101, 0644, 0, 0);
	static struct { u32 word; u16 tmpl; u16 mark; u64 hash; } buf[4096];
	int nb = 0;
	u64 total = 0;
	static struct st s;
	if (fd < 0) {
		die("cannot open the output file");
	}
	g_native = native;
	set_handlers();
	g_exit = (u64)&code_buf[4];
	code_buf[0] = NOP;
	code_buf[2] = NOP;
	code_buf[3] = enc_b(&code_buf[3], (void *)case_exit);
	code_buf[4] = enc_b(&code_buf[4], (void *)case_exit);
	memset(&s, 0, sizeof(s));
	s.sp = (u64)CELL & ~15ULL;
	for (int w = 0; w < (int)(sizeof(exh_words) / 4 + sizeof(exh_scalar) / 4); w++) {
		int vec = w < (int)(sizeof(exh_words) / 4);
		u32 word = (vec ? exh_words[w] : exh_scalar[w - sizeof(exh_words) / 4]) | (1u << 5);    /* Vd = v0, Vn = v1 */
		code_buf[1] = word;
		__asm__ volatile ("dsb ish; ic ivau, %0; dsb ish; isb" : : "r"(code_buf));
		for (u32 combo = 0; combo < 8; combo++) {
			u64 fpcr = (u64)(combo & 3) << 22;
			g_fz16 = (combo & 4) ? (1u << 19) : 0;
			if (native) {
				fpcr |= g_fz16;
			}
			for (u32 v = 0; v < 65536; v += vec ? 8 : 1) {
				for (int r = 0; r < 32; r++) {
					s.v[r][0] = s.v[r][1] = 0;
				}
				for (int k = 0; k < 31; k++) {
					s.x[k] = 0;
				}
				if (vec) {
					s.v[1][0] = (u64)v | ((u64)(v + 1) << 16) | ((u64)(v + 2) << 32) | ((u64)(v + 3) << 48);
					s.v[1][1] = (u64)(v + 4) | ((u64)(v + 5) << 16) | ((u64)(v + 6) << 32) | ((u64)(v + 7) << 48);
				} else {
					s.v[1][0] = v;
				}
				s.sp = (u64)CELL & ~15ULL;
				s.nzcv = 0;
				s.fpsr = 0;
				s.fpcr = fpcr;
				g_mark = MARK_OK;
				run_case(&s);
				buf[nb].word = word;
				buf[nb].tmpl = (u16)w;
				buf[nb].mark = (u16)g_mark;
				buf[nb].hash = hash_state(&s);
				total++;
				if (++nb == 4096) {
					sys6(SYS_write, fd, (long)buf, (long)sizeof(buf), 0, 0, 0);
					nb = 0;
				}
			}
		}
	}
	if (nb) {
		sys6(SYS_write, fd, (long)buf, (long)nb * 16, 0, 0, 0);
	}
	sys6(SYS_close, fd, 0, 0, 0, 0, 0);
	wr(1, "fp16x ");
	wr(1, mode);
	wr(1, " cases ");
	out_u(total);
	wr(1, "\n");
	return 0;
}

static int
cases_main(const char *mode, const char *cls_name, u64 ncases, u64 seed, const char *path, int dump, u64 dump_n)
{
	static const char *names[] = { "pac", "lse", "casp", "rcpc", "fp16", "fcma", "dotprod", "jscvt", "fhm", "sha3", "rdm", "sysreg" };
	int native = streq(mode, "native");
	int cls = -1;
	for (int k = 0; k < A64E_NCLASS; k++) {
		if (streq(cls_name, names[k])) {
			cls = k;
		}
	}
	if (cls < 0) {
		die("unknown class");
	}
	/* which templates */
	int use[NTMPL], nuse = 0;
	for (unsigned k = 0; k < NTMPL; k++) {
		if (tmpls[k].cls == cls) {
			use[nuse++] = (int)k;
		}
	}
	if (!nuse) {
		die("no templates");
	}
	long fd = -1;
	if (!dump) {
		fd = sys6(SYS_openat, -100, (long)path, 01101, 0644, 0, 0);
		if (fd < 0) {
			die("cannot open the output file");
		}
	}
	g_native = native;
	set_handlers();
	rs = seed * 0x9E3779B97F4A7C15ULL + 88172645463325252ULL;
	static struct { u32 word; u16 tmpl; u16 mark; u64 hash; } buf[4096];
	int nb = 0;
	static struct st s, in;
	g_exit = (u64)&code_buf[4];
	for (u64 n = 0; n < ncases; n++) {
		int ti = use[n % (u64)nuse];
		struct plan p;
		g_mark = MARK_OK;
		make_case(&tmpls[ti], &s, &p, native);
		if (native && cls == A64E_SYSREG) {
			__asm__ volatile (".long 0xD503405F");  /* msr DIT, #0: a case before it left DIT on, and an A73 has no DIT to keep */
		}
		in = s;
		if (dump && n == dump_n) {
			wr(1, "word ");
			out_x(p.w1);
			wr(1, " w0 ");
			out_x(p.w0);
			wr(1, " w2 ");
			out_x(p.w2);
			wr(1, " fz16 ");
			out_x(g_fz16);
			wr(1, "\n");
			print_state("in", &s);
		}
		run_case(&s);
		finish_case(&s, &in, &p, native);
		if (dump && n == dump_n) {
			wr(1, "mark ");
			out_u((u64)g_mark);
			wr(1, "\n");
			print_state("out", &s);
			const volatile u64 *m = (const volatile u64 *)CELL;
			wr(1, " mem ");
			for (int k = 0; k < 16; k++) {
				out_x(m[k]);
				wr(1, " ");
			}
			wr(1, "\n");
			sys6(SYS_exit_group, 0, 0, 0, 0, 0, 0);
		}
		if (!dump) {
			buf[nb].word = p.w1;
			buf[nb].tmpl = (u16)ti;
			buf[nb].mark = (u16)g_mark;
			buf[nb].hash = hash_state(&s);
			if (++nb == 4096) {
				sys6(SYS_write, fd, (long)buf, (long)sizeof(buf), 0, 0, 0);
				nb = 0;
			}
		}
	}
	if (!dump) {
		if (nb) {
			sys6(SYS_write, fd, (long)buf, (long)nb * 16, 0, 0, 0);
		}
		sys6(SYS_close, fd, 0, 0, 0, 0, 0);
	}
	wr(1, cls_name);
	wr(1, " ");
	wr(1, mode);
	wr(1, " cases ");
	out_u(ncases);
	wr(1, " emulated ");
	out_u(g_counts[cls]);
	wr(1, "\n");
	return 0;
}

/* ---- rules: what no real word can show ---- */
static int g_fail, g_checks;
static int
memcmp_regs(const struct a64emu_regs *a, const struct a64emu_regs *b)
{
	for (int k = 0; k < 31; k++) {
		if (a->x[k] != b->x[k]) {
			return 0;
		}
	}
	return a->sp == b->sp && a->pc == b->pc && a->pstate == b->pstate;
}
static void
ck(int cond, const char *what)
{
	g_checks++;
	if (!cond) {
		g_fail++;
		wr(1, "FAIL ");
		wr(1, what);
		wr(1, "\n");
	}
}

static long
mapa(u64 *p, int prot)
{
	long r = sys6(SYS_mmap, 0, 4096, prot, 0x22, -1, 0);
	*p = (u64)r;
	return r;
}

static int
rules_main(void)
{
	u64 v[32][2];
	struct a64emu_regs r;
	u32 fpsr, fpcr;
	struct a64emu_cpu c = { &r, v, &fpsr, &fpcr, 1ULL << 47, 0, false };
	struct a64emu_out o;
	u64 pnone, pro, plazy, prw;

	set_handlers();
	for (int k = 0; k < A64E_NCLASS; k++) {
		int e = a64emu_selfcheck(k);
		if (e) {
			wr(1, "selfcheck class ");
			out_u((u64)k);
			wr(1, " check ");
			out_u((u64)e);
			wr(1, "\n");
		}
		ck(e == 0, "selfcheck");
	}
	mapa(&pnone, 0);
	mapa(&pro, 1);
	mapa(&plazy, 0);
	mapa(&prw, 3);
#define RESET() do { memset(&r, 0x55, sizeof(r)); r.pc = 0x4000; r.pstate = 0; memset(v, 0, sizeof(v)); fpsr = 0; fpcr = 0; } while (0)
	static struct a64emu_regs before;
	/* a word on a bad address: every register and the PC stay; the address and the access kind come back */
	static const struct { u32 w; const char *n; int wr; } onbad[] = {
		{ 0xF8E10002, "ldaddal", 1 }, { 0xC8E2FC01, "casal", 1 }, { 0xF8BFC001, "ldapr", 0 }, { 0xF8200401, "ldraa", 0 },
		{ 0x48227C04, "casp", 1 }, { 0xD9000001, "stlur", 1 }, { 0xD9400001, "ldapur", 0 },
	};
	for (unsigned k = 0; k < sizeof(onbad) / sizeof(onbad[0]); k++) {
		u64 bad[] = { pnone, 0x10, (1ULL << 47), (1ULL << 48), 0xfffffff007004000ULL, (1ULL << 55) | pro };
		for (unsigned b = 0; b < sizeof(bad) / sizeof(bad[0]); b++) {
			RESET();
			r.x[0] = bad[b];
			before = r;
			enum a64emu_result e = a64emu_run(&c, onbad[k].w, &o);
			ck(e == A64EMU_FAULT, onbad[k].n);
			ck(o.addr == bad[b], "fault address");
			ck((int)o.write == onbad[k].wr, "fault kind");
			ck(memcmp_regs(&r, &before), "registers unchanged after a fault");
		}
	}
	/* read-only page: the load works, the store of the atomic faults: nothing changes */
	RESET();
	r.x[0] = pro;
	r.x[1] = 1;
	before = r;
	ck(a64emu_run(&c, 0xF8E10002, &o) == A64EMU_FAULT, "ldaddal read-only page");
	ck(memcmp_regs(&r, &before), "registers unchanged, read-only page");
	/* a lazy page: the first access faults, the fault path maps it, the access runs again (COW, zero fill, paged out) */
	RESET();
	r.x[0] = plazy;
	r.x[1] = 3;
	g_lazy_addr = plazy;
	g_lazy_fixes = 0;
	ck(a64emu_run(&c, 0xF8E10002, &o) == A64EMU_OK, "ldaddal lazy page");
	ck(g_lazy_fixes == 1, "the fault ran once");
	ck(*(volatile u64 *)plazy == 3, "ldaddal lazy page result");
	ck(r.x[2] == 0, "ldaddal lazy page old value");
	ck(r.pc == 0x4004, "PC after the word");
	/* top byte ignored */
	RESET();
	*(volatile u64 *)prw = 9;
	r.x[0] = prw | (0x7BULL << 56);
	r.x[1] = 1;
	ck(a64emu_run(&c, 0xF8E10002, &o) == A64EMU_OK && r.x[2] == 9 && *(volatile u64 *)prw == 10, "tagged pointer");
	/* SP base not aligned */
	RESET();
	r.sp = prw + 8;
	ck(a64emu_run(&c, 0xF8E103E2, &o) == A64EMU_SP_ALIGN, "SP alignment"); /* ldaddal x1, x2, [sp] */
	ck(r.pc == 0x4000, "PC stays on an SP alignment fault");
	/* single step: a finished word clears SPSR.SS (the step exception comes at the next instruction); a fault keeps it */
	RESET();
	r.x[0] = prw;
	r.pstate = 1u << 21;
	ck(a64emu_run(&c, 0xF8E10002, &o) == A64EMU_OK && !(r.pstate & (1u << 21)), "SS cleared after the word");
	RESET();
	r.x[0] = pnone;
	r.pstate = 1u << 21;
	ck(a64emu_run(&c, 0xF8E10002, &o) == A64EMU_FAULT && (r.pstate & (1u << 21)), "SS kept on a fault");
	/* NZCV other than the class that writes it stays: JSCVT writes it */
	RESET();
	r.pstate = 0xF0000000;
	v[1][0] = 0x3FF0000000000000ULL;
	ck(a64emu_run(&c, 0x1E7E0020, &o) == A64EMU_OK && r.pstate == 0x40000000 && (u32)r.x[0] == 1, "fjcvtzs 1.0: Z set, others clear");
	/* a class that is off is unknown, nothing changes */
	RESET();
	c.off = 1u << A64E_FP16;
	before = r;
	ck(a64emu_run(&c, 0x1EE22820, &o) == A64EMU_UNKNOWN && memcmp_regs(&r, &before), "class off");
	c.off = 0;
	/* words that must stay undefined */
	static const u32 unk[] = { 0x00201000, 0x00000000, 0xC0080000, 0x8B000000, 0xFFFFFFFF, 0xD53BE060 };
	for (unsigned k = 0; k < sizeof(unk) / sizeof(unk[0]); k++) {
		ck(a64emu_classify(unk[k]) == -1, "AMX, SME and other words stay unknown");
	}
	/* PACGA: the tool's rule. LDRAA with SP base, which the native pre-sign cannot reach */
	RESET();
	r.x[1] = 0x1111;
	r.x[2] = 0x2222;
	r.x[0] = 5;
	ck(a64emu_run(&c, 0x9AC23020, &o) == A64EMU_OK && r.x[0] == 0, "pacga is 0");
	RESET();
	r.sp = prw;
	*(volatile u64 *)prw = 0xABCDEF;
	ck(a64emu_run(&c, 0xF82007E1, &o) == A64EMU_OK && r.x[1] == 0xABCDEF, "ldraa x1, [sp]");
	RESET();
	r.x[3] = 7;
	ck(a64emu_run(&c, 0xD53EF1A3, &o) == A64EMU_OK && r.x[3] == 0, "S3_6_C15_C1_5 reads 0");
	wr(1, "rules: checks ");
	out_u((u64)g_checks);
	wr(1, " failures ");
	out_u((u64)g_fail);
	wr(1, "\n");
	return g_fail != 0;
}

/* ---- threads: LL/SC on real threads against the emulated words ---- */
void llsc_add(volatile u64 *, u64);
void llsc_pair(volatile u64 *, u64);
u64 lse_ldaddal(volatile u64 *, u64);
u64 lse_casal(volatile u64 *, u64, u64);
u64 lse_swpal(volatile u64 *, u64);
void lse_casp(volatile u64 *, u64 *);
int thread_start(u64 flags, void *stack, void (*fn)(void *), void *arg, volatile int *tid);

#define NTHR 4
#define CLONE_FLAGS (0x00000100 | 0x00000200 | 0x00000400 | 0x00000800 | 0x00010000 | 0x00040000 | 0x00200000 | 0x01000000)
/* VM FS FILES SIGHAND THREAD CHILD_CLEARTID(0x00200000) CHILD_SETTID(0x01000000) */
static volatile u64 g_count __attribute__((aligned(64)));
static volatile u64 g_pair[2] __attribute__((aligned(64)));
static volatile u64 g_lock __attribute__((aligned(64)));
static u64 g_plain;     /* only under the lock */
static volatile u64 g_torn;
static u64 g_iter;
static u8 thr_stack[2 * NTHR][1 << 16] __attribute__((aligned(16)));
static u8 thr_alt[2 * NTHR][1 << 16] __attribute__((aligned(16)));
static volatile int thr_tid[2 * NTHR];
static volatile u64 g_go;

struct targ { int idx, kind; };
static struct targ targs[2 * NTHR];

static void
worker(void *a)
{
	struct targ *t = a;
	struct { void *sp; int flags; size_t size; } ss = { thr_alt[t->idx], 0, sizeof(thr_alt[0]) };
	sys6(SYS_sigaltstack, (long)&ss, 0, 0, 0, 0, 0);
	while (!g_go) {
	}
	for (u64 n = 0; n < g_iter; n++) {
		switch (t->kind) {
		case 0:         /* trap: LDADDAL */
			lse_ldaddal(&g_count, 1);
			break;
		case 1:         /* user LL/SC */
			llsc_add(&g_count, 1);
			break;
		case 2:         /* a lock: CASAL taken through the trap; released with a plain store */
			while (lse_casal(&g_lock, 0, 1) != 0) {
			}
			g_plain++;
			__asm__ volatile ("stlr xzr, %0" : "=Q"(g_lock));
			break;
		case 3:         /* the same lock with user LL/SC */
			for (;;) {
				u64 old;
				u32 st;
				__asm__ volatile ("ldaxr %0, %2\n cbnz %0, 1f\n stxr %w1, %3, %2\n cbnz %w1, 1f\n b 2f\n 1: clrex\n mov %0, #1\n 2:" : "=&r"(old), "=&r"(st), "+Q"(g_lock) : "r"(1ULL));
				if (old == 0) {
					break;
				}
			}
			g_plain++;
			__asm__ volatile ("stlr xzr, %0" : "=Q"(g_lock));
			break;
		case 4: {       /* CASP through the trap: both words go up together */
			u64 q[4];
			for (;;) {
				q[0] = g_pair[0];
				q[1] = q[0];
				q[2] = q[0] + 1;
				q[3] = q[0] + 1;
				lse_casp(g_pair, q);
				if (q[0] != q[1]) {
					g_torn = g_torn + 1;
				}
				if (q[0] == q[2] - 1) {
					break;
				}
			}
			break;
		}
		case 5:         /* user LDAXP/STLXP on the pair */
			llsc_pair(g_pair, 1);
			break;
		}
	}
}

static void
join_all(int n)
{
	for (int k = 0; k < n; k++) {
		for (;;) {
			int v = thr_tid[k];
			if (v == 0) {
				break;
			}
			sys6(SYS_futex, (long)&thr_tid[k], 0, v, 0, 0, 0);
		}
	}
}

static void
start_all(int ka, int kb)
{
	g_go = 0;
	for (int k = 0; k < 2 * NTHR; k++) {
		targs[k].idx = k;
		targs[k].kind = k < NTHR ? ka : kb;
		thr_tid[k] = 1;
		thread_start(CLONE_FLAGS, thr_stack[k] + sizeof(thr_stack[k]), worker, &targs[k], &thr_tid[k]);
	}
	g_go = 1;
	join_all(2 * NTHR);
}

static int
threads_main(u64 iter)
{
	int bad = 0;

	set_handlers();
	g_iter = iter;
	g_count = 0;
	start_all(0, 1);
	wr(1, "threads: LDADDAL trap x4 + user LL/SC x4: ");
	out_u(g_count);
	wr(1, " of ");
	out_u(iter * 2 * NTHR);
	wr(1, "\n");
	bad |= g_count != iter * 2 * NTHR;
	g_plain = 0;
	g_lock = 0;
	start_all(2, 3);
	wr(1, "threads: lock CASAL trap x4 + LL/SC x4, plain counter under it: ");
	out_u(g_plain);
	wr(1, " of ");
	out_u(iter * 2 * NTHR);
	wr(1, "\n");
	bad |= g_plain != iter * 2 * NTHR;
	g_pair[0] = g_pair[1] = 0;
	g_torn = 0;
	start_all(4, 5);
	wr(1, "threads: CASP trap x4 + LDAXP/STLXP x4: pair ");
	out_u(g_pair[0]);
	wr(1, " ");
	out_u(g_pair[1]);
	wr(1, " of ");
	out_u(iter * 2 * NTHR);
	wr(1, ", torn reads ");
	out_u(g_torn);
	wr(1, "\n");
	bad |= g_pair[0] != iter * 2 * NTHR || g_pair[1] != iter * 2 * NTHR || g_torn != 0;
	return bad;
}

void
c_start(long *sp)
{
	long argc = sp[0];
	char **argv = (char **)(sp + 1);
	int rc = 2;

	if (argc >= 2 && streq(argv[1], "rules")) {
		rc = rules_main();
	} else if (argc >= 3 && streq(argv[1], "threads")) {
		rc = threads_main(parse_u(argv[2]));
	} else if (argc >= 4 && streq(argv[1], "exh")) {
		rc = exh_main(argv[2], argv[3]);
	} else if (argc >= 6 && (streq(argv[1], "native") || streq(argv[1], "emu"))) {
		rc = cases_main(argv[1], argv[2], parse_u(argv[3]), parse_u(argv[4]), argv[5], 0, 0);
	} else if (argc >= 6 && streq(argv[1], "dump")) {
		/* dump native|emu CLASS N SEED */
		rc = cases_main(argv[2], argv[3], parse_u(argv[4]) + 1, parse_u(argv[5]), "", 1, parse_u(argv[4]));
	} else {
		wr(2, "usage: harness native|emu CLASS CASES SEED OUT; dump native|emu CLASS N SEED; rules; threads ITER\n");
	}
	sys6(SYS_exit_group, rc, 0, 0, 0, 0, 0);
}

__asm__(".text\n.globl _start\n_start:\n mov x0, sp\n bl c_start\n");
