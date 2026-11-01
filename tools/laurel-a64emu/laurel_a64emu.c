/*
 * laurel_a64emu.c: see laurel_a64emu.h. The FP code follows the ARM ARM pseudocode (FPUnpack, FPRound, FPProcessNaNs, FPMulAdd ...).
 * A value is sign, mant x 2^exp, with the mantissa in an integer: nothing here uses an FP register.
 */
#ifdef KERNEL
#include <arm64/laurel_a64emu.h>
#else
#include "laurel_a64emu.h"
#endif

typedef unsigned __int128 u128;
typedef uint64_t u64;
typedef uint32_t u32;
typedef uint16_t u16;
typedef uint8_t u8;

#define BIT(x, n)       (((x) >> (n)) & 1u)
#define BITS(x, hi, lo) (((x) >> (lo)) & ((1u << ((hi) - (lo) + 1)) - 1u))

#define FPCR_AHP   (1u << 26)
#define FPCR_DN    (1u << 25)
#define FPCR_FZ    (1u << 24)
#define FPCR_FZ16  (1u << 19)
#define FPSR_QC    (1u << 27)
#define FPSR_IDC   (1u << 7)
#define FPSR_IXC   (1u << 4)
#define FPSR_UFC   (1u << 3)
#define FPSR_OFC   (1u << 2)
#define FPSR_DZC   (1u << 1)
#define FPSR_IOC   (1u << 0)
#define PSTATE_SS  (1u << 21)

/* ---- formats ---- */
enum { F16 = 0, F32 = 1, F64 = 2 };
static const struct {
	uint8_t n, e, f;
	int16_t minexp;
} fmts[3] = { {16, 5, 10, -14}, {32, 8, 23, -126}, {64, 11, 52, -1022} };

enum { T_ZERO, T_NUM, T_INF, T_QNAN, T_SNAN };
enum { RM_N = 0, RM_P = 1, RM_M = 2, RM_Z = 3, RM_A = 4 };

struct fpc {
	u32 fpcr;
	u32 flags;
};

struct fpv {
	int type, sign;
	int exp;
	u64 mant;       /* value = mant x 2^exp */
};

static inline u64
fp_signbit(int f)
{
	return 1ULL << (fmts[f].n - 1);
}
static inline u64
fp_absmask(int f)
{
	return fp_signbit(f) - 1;
}
static inline u64
fp_expmask(int f)
{
	return ((1ULL << fmts[f].e) - 1) << fmts[f].f;
}
static inline u64
fp_qbit(int f)
{
	return 1ULL << (fmts[f].f - 1);
}
static inline u64
fp_zero(int f, int s)
{
	return s ? fp_signbit(f) : 0;
}
static inline u64
fp_inf(int f, int s)
{
	return fp_zero(f, s) | fp_expmask(f);
}
static inline u64
fp_defnan(int f)
{
	return fp_expmask(f) | fp_qbit(f);
}
static inline u64
fp_maxnormal(int f, int s)
{
	return fp_zero(f, s) | (fp_expmask(f) - (1ULL << fmts[f].f)) | ((1ULL << fmts[f].f) - 1);
}
static inline u64
fp_neg(int f, u64 x)
{
	return x ^ fp_signbit(f);
}
static inline u64
fp_abs(int f, u64 x)
{
	return x & fp_absmask(f);
}
static inline int
fp_fz(int f, const struct fpc *c)
{
	return (c->fpcr & (f == F16 ? FPCR_FZ16 : FPCR_FZ)) != 0;
}
static inline int
fp_rmode(const struct fpc *c)
{
	return (int)BITS(c->fpcr, 23, 22);
}

static struct fpv
fp_unpack(int f, u64 x, struct fpc *c)
{
	struct fpv v;
	int F = fmts[f].f;
	u64 frac = x & ((1ULL << F) - 1);
	u64 e = (x >> F) & ((1ULL << fmts[f].e) - 1);

	v.sign = (int)((x >> (fmts[f].n - 1)) & 1);
	v.exp = 0;
	v.mant = 0;
	if (e == 0) {
		if (frac == 0) {
			v.type = T_ZERO;
		} else if (fp_fz(f, c)) {
			v.type = T_ZERO;
			if (f != F16) {         /* FZ16 gives no input denormal flag (FPUnpackBase) */
				c->flags |= FPSR_IDC;
			}
		} else {
			v.type = T_NUM;
			v.mant = frac;
			v.exp = fmts[f].minexp - F;
		}
	} else if (e == (1ULL << fmts[f].e) - 1) {
		if (frac == 0) {
			v.type = T_INF;
		} else {
			v.type = (frac & fp_qbit(f)) ? T_QNAN : T_SNAN;
		}
	} else {
		v.type = T_NUM;
		v.mant = frac | (1ULL << F);
		v.exp = (int)e + fmts[f].minexp - 1 - F;
	}
	return v;
}

static inline int
clz128(u128 m)
{
	u64 hi = (u64)(m >> 64);
	if (hi) {
		return __builtin_clzll(hi);
	}
	return 64 + __builtin_clzll((u64)m);
}

/* FPRound: (-1)^s x m x 2^e, m != 0. The lowest bit of m may be a sticky bit. */
static u64
fp_round(int f, struct fpc *c, int s, int e, u128 m, int rm)
{
	int F = fmts[f].f, E = fmts[f].e, minexp = fmts[f].minexp;
	int p = 127 - clz128(m);
	int exponent = e + p;
	int biased, sh;
	u64 im;
	int inexact, half, more;
	bool up, ovf_inf;

	if (fp_fz(f, c) && exponent < minexp) {
		c->flags |= FPSR_UFC;
		return fp_zero(f, s);
	}
	biased = exponent - minexp + 1;
	if (biased < 0) {
		biased = 0;
	}
	sh = p - F;
	if (biased == 0) {
		sh += minexp - exponent;
	}
	if (sh <= 0) {
		im = (u64)(m << -sh);
		half = more = 0;
	} else if (sh >= 128) {
		im = 0;
		half = 0;
		more = 1;
	} else {
		u128 rest = m & (((u128)1 << sh) - 1);
		u128 h = (u128)1 << (sh - 1);
		im = (u64)(m >> sh);
		half = (rest & h) != 0;
		more = (rest & (h - 1)) != 0;
	}
	inexact = half || more;
	if (biased == 0 && inexact) {
		c->flags |= FPSR_UFC;
	}
	switch (rm) {
	case RM_P:
		up = inexact && !s;
		ovf_inf = !s;
		break;
	case RM_M:
		up = inexact && s;
		ovf_inf = s;
		break;
	case RM_Z:
		up = false;
		ovf_inf = false;
		break;
	case RM_A:
		up = half;
		ovf_inf = true;
		break;
	default:
		up = half && (more || (im & 1));
		ovf_inf = true;
		break;
	}
	if (up) {
		im++;
		if (im == (1ULL << F) && biased == 0) {
			biased = 1;
		}
		if (im == (1ULL << (F + 1))) {
			biased++;
			im >>= 1;
		}
	}
	if (biased >= (1 << E) - 1) {
		c->flags |= FPSR_OFC | FPSR_IXC;
		return ovf_inf ? fp_inf(f, s) : fp_maxnormal(f, s);
	}
	if (inexact) {
		c->flags |= FPSR_IXC;
	}
	return fp_zero(f, s) | ((u64)biased << F) | (im & ((1ULL << F) - 1));
}

static u64
fp_nan(int f, int type, u64 x, struct fpc *c)
{
	if (type == T_SNAN) {
		c->flags |= FPSR_IOC;
		x |= fp_qbit(f);
	}
	return (c->fpcr & FPCR_DN) ? fp_defnan(f) : x;
}

static bool
fp_nans2(int f, const struct fpv *a, const struct fpv *b, u64 x, u64 y, struct fpc *c, u64 *r)
{
	if (a->type == T_SNAN) {
		*r = fp_nan(f, T_SNAN, x, c);
	} else if (b->type == T_SNAN) {
		*r = fp_nan(f, T_SNAN, y, c);
	} else if (a->type == T_QNAN) {
		*r = fp_nan(f, T_QNAN, x, c);
	} else if (b->type == T_QNAN) {
		*r = fp_nan(f, T_QNAN, y, c);
	} else {
		return false;
	}
	return true;
}

static bool
fp_nans3(int f, const struct fpv *a, const struct fpv *b, const struct fpv *d, u64 x, u64 y, u64 z, struct fpc *c, u64 *r)
{
	if (a->type == T_SNAN) {
		*r = fp_nan(f, T_SNAN, x, c);
	} else if (b->type == T_SNAN) {
		*r = fp_nan(f, T_SNAN, y, c);
	} else if (d->type == T_SNAN) {
		*r = fp_nan(f, T_SNAN, z, c);
	} else if (a->type == T_QNAN) {
		*r = fp_nan(f, T_QNAN, x, c);
	} else if (b->type == T_QNAN) {
		*r = fp_nan(f, T_QNAN, y, c);
	} else if (d->type == T_QNAN) {
		*r = fp_nan(f, T_QNAN, z, c);
	} else {
		return false;
	}
	return true;
}

static inline u64
fp_invalid(int f, struct fpc *c)
{
	c->flags |= FPSR_IOC;
	return fp_defnan(f);
}

/* exact sum of two signed values, with a sticky bit if bits fell out of the 127-bit window */
static void
add_exact(int s1, int e1, u128 m1, int s2, int e2, u128 m2, int *rs, int *re, u128 *rm)
{
	if (m1 == 0) {
		*rs = s2;
		*re = e2;
		*rm = m2;
		return;
	}
	if (m2 == 0) {
		*rs = s1;
		*re = e1;
		*rm = m1;
		return;
	}
	int l1 = clz128(m1) - 1, l2 = clz128(m2) - 1;
	m1 <<= l1;
	e1 -= l1;
	m2 <<= l2;
	e2 -= l2;
	if (e1 < e2 || (e1 == e2 && m1 < m2)) {
		int ts = s1, te = e1;
		u128 tm = m1;
		s1 = s2;
		e1 = e2;
		m1 = m2;
		s2 = ts;
		e2 = te;
		m2 = tm;
	}
	int d = e1 - e2;
	if (d >= 127) {
		m2 = 1;
	} else if (d > 0) {
		u128 lost = m2 & (((u128)1 << d) - 1);
		m2 >>= d;
		if (lost) {
			m2 |= 1;
		}
	}
	*rs = s1;
	*re = e1;
	*rm = (s1 == s2) ? m1 + m2 : m1 - m2;
}

static u64
fp_addsub(int f, u64 x, u64 y, bool sub, struct fpc *c)
{
	struct fpv a = fp_unpack(f, x, c), b = fp_unpack(f, y, c);
	u64 r;
	if (fp_nans2(f, &a, &b, x, y, c, &r)) {
		return r;
	}
	if (sub) {
		b.sign ^= 1;
	}
	if (a.type == T_INF && b.type == T_INF && a.sign != b.sign) {
		return fp_invalid(f, c);
	}
	if (a.type == T_INF) {
		return fp_inf(f, a.sign);
	}
	if (b.type == T_INF) {
		return fp_inf(f, b.sign);
	}
	if (a.type == T_ZERO && b.type == T_ZERO && a.sign == b.sign) {
		return fp_zero(f, a.sign);
	}
	int rs, re;
	u128 rm;
	add_exact(a.sign, a.exp, a.mant, b.sign, b.exp, b.mant, &rs, &re, &rm);
	if (rm == 0) {
		return fp_zero(f, fp_rmode(c) == RM_M);
	}
	return fp_round(f, c, rs, re, rm, fp_rmode(c));
}

static u64
fp_mul(int f, u64 x, u64 y, bool mulx, struct fpc *c)
{
	struct fpv a = fp_unpack(f, x, c), b = fp_unpack(f, y, c);
	u64 r;
	if (fp_nans2(f, &a, &b, x, y, c, &r)) {
		return r;
	}
	int s = a.sign ^ b.sign;
	if ((a.type == T_INF && b.type == T_ZERO) || (a.type == T_ZERO && b.type == T_INF)) {
		if (mulx) {     /* FPTwo(sign) */
			return fp_zero(f, s) | ((u64)((1u << (fmts[f].e - 1))) << fmts[f].f);
		}
		return fp_invalid(f, c);
	}
	if (a.type == T_INF || b.type == T_INF) {
		return fp_inf(f, s);
	}
	if (a.type == T_ZERO || b.type == T_ZERO) {
		return fp_zero(f, s);
	}
	return fp_round(f, c, s, a.exp + b.exp, (u128)a.mant * b.mant, fp_rmode(c));
}

/* FPMulAdd: d + n x m, fused */
static u64
fp_muladd(int f, u64 d, u64 n, u64 m, struct fpc *c)
{
	struct fpv a = fp_unpack(f, d, c), x = fp_unpack(f, n, c), y = fp_unpack(f, m, c);
	u64 r;
	bool infzero = (x.type == T_INF && y.type == T_ZERO) || (x.type == T_ZERO && y.type == T_INF);
	bool done = fp_nans3(f, &a, &x, &y, d, n, m, c, &r);
	if (a.type == T_QNAN && infzero) {
		return fp_invalid(f, c);
	}
	if (done) {
		return r;
	}
	int sp = x.sign ^ y.sign;
	bool infp = x.type == T_INF || y.type == T_INF;
	bool zerop = x.type == T_ZERO || y.type == T_ZERO;
	if (infzero || (a.type == T_INF && infp && a.sign != sp)) {
		return fp_invalid(f, c);
	}
	if (a.type == T_INF) {
		return fp_inf(f, a.sign);
	}
	if (infp) {
		return fp_inf(f, sp);
	}
	if (a.type == T_ZERO && zerop && a.sign == sp) {
		return fp_zero(f, a.sign);
	}
	int rs, re;
	u128 rm;
	add_exact(a.sign, a.exp, a.mant, sp, x.exp + y.exp, zerop ? 0 : (u128)x.mant * y.mant, &rs, &re, &rm);
	if (rm == 0) {
		return fp_zero(f, fp_rmode(c) == RM_M);
	}
	return fp_round(f, c, rs, re, rm, fp_rmode(c));
}

static u64
fp_div(int f, u64 x, u64 y, struct fpc *c)
{
	struct fpv a = fp_unpack(f, x, c), b = fp_unpack(f, y, c);
	u64 r;
	if (fp_nans2(f, &a, &b, x, y, c, &r)) {
		return r;
	}
	int s = a.sign ^ b.sign;
	if ((a.type == T_INF && b.type == T_INF) || (a.type == T_ZERO && b.type == T_ZERO)) {
		return fp_invalid(f, c);
	}
	if (a.type == T_INF || b.type == T_ZERO) {
		if (a.type != T_INF) {
			c->flags |= FPSR_DZC;
		}
		return fp_inf(f, s);
	}
	if (a.type == T_ZERO || b.type == T_INF) {
		return fp_zero(f, s);
	}
	int sa = __builtin_clzll(a.mant), sb = __builtin_clzll(b.mant);
	u128 rem = (u128)(a.mant << sa);
	u64 den = b.mant << sb, q = 0;
	for (int i = 0; i < 64; i++) {
		q <<= 1;
		if (rem >= den) {
			rem -= den;
			q |= 1;
		}
		rem <<= 1;
	}
	return fp_round(f, c, s, a.exp - sa - b.exp + sb - 64, ((u128)q << 1) | (rem != 0), fp_rmode(c));
}

static u64
fp_sqrt(int f, u64 x, struct fpc *c)
{
	struct fpv a = fp_unpack(f, x, c);
	if (a.type == T_QNAN || a.type == T_SNAN) {
		return fp_nan(f, a.type, x, c);
	}
	if (a.type == T_ZERO) {
		return fp_zero(f, a.sign);
	}
	if (a.sign) {
		return fp_invalid(f, c);
	}
	if (a.type == T_INF) {
		return fp_inf(f, 0);
	}
	/* M x 2^e, e even, M with 125 or 126 bits: the root has 63 bits */
	u128 M = a.mant;
	int e = a.exp;
	int l = clz128(M) - 2;
	M <<= l;
	e -= l;
	if (e & 1) {
		M >>= 1;        /* the low bits of a mantissa are zero here: nothing is lost */
		e += 1;
	}
	u128 root = 0, bit = (u128)1 << 124;
	while (bit > M) {
		bit >>= 2;
	}
	while (bit != 0) {
		if (M >= root + bit) {
			M -= root + bit;
			root = (root >> 1) + bit;
		} else {
			root >>= 1;
		}
		bit >>= 2;
	}
	return fp_round(f, c, 0, e / 2 - 1, (root << 1) | (M != 0), fp_rmode(c));
}

/* compare the values of two non-NaN numbers: -1, 0, 1 */
static int
fp_cmpval(const struct fpv *a, const struct fpv *b)
{
	int za = a->type == T_ZERO, zb = b->type == T_ZERO;
	if (za && zb) {
		return 0;
	}
	if (a->type == T_INF && b->type == T_INF && a->sign == b->sign) {
		return 0;
	}
	int sa = a->sign, sb = b->sign;
	if (za) {
		return sb ? 1 : -1;
	}
	if (zb) {
		return sa ? -1 : 1;
	}
	if (sa != sb) {
		return sa ? -1 : 1;
	}
	int r;
	if (a->type == T_INF) {
		r = 1;
	} else if (b->type == T_INF) {
		r = -1;
	} else {
		int la = __builtin_clzll(a->mant), lb = __builtin_clzll(b->mant);
		int ea = a->exp - la, eb = b->exp - lb;
		u64 ma = a->mant << la, mb = b->mant << lb;
		r = ea != eb ? (ea > eb ? 1 : -1) : (ma == mb ? 0 : (ma > mb ? 1 : -1));
	}
	return sa ? -r : r;
}

/* FPCompare: NZCV */
static u32
fp_compare(int f, u64 x, u64 y, bool signal, struct fpc *c)
{
	struct fpv a = fp_unpack(f, x, c), b = fp_unpack(f, y, c);
	if (a.type >= T_QNAN || b.type >= T_QNAN) {
		if (a.type == T_SNAN || b.type == T_SNAN || signal) {
			c->flags |= FPSR_IOC;
		}
		return 0x3;
	}
	int r = fp_cmpval(&a, &b);
	return r == 0 ? 0x6 : (r < 0 ? 0x8 : 0x2);
}

enum { C_EQ, C_GE, C_GT };
static bool
fp_cmpq(int f, u64 x, u64 y, int kind, struct fpc *c)
{
	struct fpv a = fp_unpack(f, x, c), b = fp_unpack(f, y, c);
	if (a.type >= T_QNAN || b.type >= T_QNAN) {
		if (kind != C_EQ || a.type == T_SNAN || b.type == T_SNAN) {
			c->flags |= FPSR_IOC;
		}
		return false;
	}
	int r = fp_cmpval(&a, &b);
	return kind == C_EQ ? r == 0 : (kind == C_GE ? r >= 0 : r > 0);
}

static u64
fp_maxmin(int f, u64 x, u64 y, bool ismax, struct fpc *c)
{
	struct fpv a = fp_unpack(f, x, c), b = fp_unpack(f, y, c);
	u64 r;
	if (fp_nans2(f, &a, &b, x, y, c, &r)) {
		return r;
	}
	int cmp = fp_cmpval(&a, &b);
	bool first = ismax ? cmp > 0 : cmp < 0;
	const struct fpv *w = first ? &a : &b;
	u64 raw = first ? x : y;
	if (w->type == T_INF) {
		return fp_inf(f, w->sign);
	}
	if (w->type == T_ZERO) {
		return fp_zero(f, ismax ? (a.sign & b.sign) : (a.sign | b.sign));
	}
	return raw;
}

static u64
fp_maxminnum(int f, u64 x, u64 y, bool ismax, struct fpc *c)
{
	struct fpv a = fp_unpack(f, x, c), b = fp_unpack(f, y, c);
	if (a.type == T_QNAN && b.type != T_QNAN) {
		x = fp_inf(f, ismax);
	} else if (a.type != T_QNAN && b.type == T_QNAN) {
		y = fp_inf(f, ismax);
	}
	return fp_maxmin(f, x, y, ismax, c);
}

/* magnitude rounded to an integer: returns the integer; *inexact */
static u128
round_mag(int s, int exp, u64 mant, int rm, int *inexact)
{
	u128 im;
	int half, more;
	if (exp >= 0) {
		*inexact = 0;
		return exp >= 72 ? ((u128)1 << 125) : (u128)mant << exp;
	}
	int sh = -exp;
	if (sh >= 65) {
		im = 0;
		half = 0;
		more = 1;
	} else if (sh == 64) {
		im = 0;
		half = (mant >> 63) & 1;
		more = (mant << 1) != 0;
	} else {
		u64 rest = mant & ((1ULL << sh) - 1), h = 1ULL << (sh - 1);
		im = mant >> sh;
		half = (rest & h) != 0;
		more = (rest & (h - 1)) != 0;
	}
	*inexact = half || more;
	bool up;
	switch (rm) {
	case RM_P:
		up = *inexact && !s;
		break;
	case RM_M:
		up = *inexact && s;
		break;
	case RM_Z:
		up = false;
		break;
	case RM_A:
		up = half;
		break;
	default:
		up = half && (more || (im & 1));
		break;
	}
	return im + (up ? 1 : 0);
}

static u64
fp_roundint(int f, u64 x, int rm, bool exact, struct fpc *c)
{
	struct fpv a = fp_unpack(f, x, c);
	if (a.type >= T_QNAN) {
		return fp_nan(f, a.type, x, c);
	}
	if (a.type == T_INF) {
		return fp_inf(f, a.sign);
	}
	if (a.type == T_ZERO) {
		return fp_zero(f, a.sign);
	}
	int inexact;
	u128 im = round_mag(a.sign, a.exp, a.mant, rm, &inexact);
	u64 r = im == 0 ? fp_zero(f, a.sign) : fp_round(f, c, a.sign, 0, im, RM_Z);
	if (inexact && exact) {
		c->flags |= FPSR_IXC;
	}
	return r;
}

/* FPToFixed to M bits, result zero-extended from M bits */
static u64
fp_tofixed(int f, u64 x, int fbits, bool uns, int rm, int M, struct fpc *c)
{
	struct fpv a = fp_unpack(f, x, c);
	u64 maxs = (1ULL << (M - 1)) - 1;
	u64 mask = M == 64 ? ~0ULL : (1ULL << M) - 1;
	if (a.type >= T_QNAN) {
		c->flags |= FPSR_IOC;
		return 0;
	}
	if (a.type == T_INF) {
		c->flags |= FPSR_IOC;
		if (a.sign) {
			return uns ? 0 : (maxs + 1);
		}
		return uns ? mask : maxs;
	}
	if (a.type == T_ZERO) {
		return 0;
	}
	int inexact;
	u128 im = round_mag(a.sign, a.exp + fbits, a.mant, rm, &inexact);
	if (a.sign) {
		if (im == 0) {
			/* rounds to -0 = 0, in range */
		} else if (uns || im > (u128)maxs + 1) {
			c->flags |= FPSR_IOC;
			return uns ? 0 : (maxs + 1);
		}
	} else if (im > (u128)(uns ? mask : maxs)) {
		c->flags |= FPSR_IOC;
		return uns ? mask : maxs;
	}
	if (inexact) {
		c->flags |= FPSR_IXC;
	}
	return (a.sign ? (u64)(0 - (u64)im) : (u64)im) & mask;
}

/* FixedToFP: an M-bit integer in the low bits of v */
static u64
fp_fromfixed(int f, u64 v, int M, int fbits, bool uns, struct fpc *c)
{
	int s = 0;
	if (M < 64) {
		v &= (1ULL << M) - 1;
	}
	if (!uns && ((v >> (M - 1)) & 1)) {
		s = 1;
		v = (M == 64 ? 0 - v : ((1ULL << M) - v));
	}
	if (v == 0) {
		return 0;
	}
	return fp_round(f, c, s, -fbits, v, fp_rmode(c));
}

static u32
recip_estimate(u32 a)
{
	a = a * 2 + 1;
	u32 b = (1u << 19) / a;
	return (b + 1) / 2;
}

static u32
rsqrt_estimate(u32 a)
{
	u32 b;
	if (a < 256) {
		a = a * 2 + 1;
	} else {
		a = (a >> 1) << 1;
		a = (a + 1) * 2;
	}
	b = 512;
	while (a * (b + 1) * (b + 1) < (1u << 28)) {
		b++;
	}
	return (b + 1) / 2;
}

/* FPRecipEstimate and FPRSqrtEstimate for 16 bits (the only size emulated) */
static u64
fp_recpe16(u64 x, struct fpc *c)
{
	struct fpv a = fp_unpack(F16, x, c);
	if (a.type >= T_QNAN) {
		return fp_nan(F16, a.type, x, c);
	}
	if (a.type == T_INF) {
		return fp_zero(F16, a.sign);
	}
	if (a.type == T_ZERO) {
		c->flags |= FPSR_DZC;
		return fp_inf(F16, a.sign);
	}
	u64 mag = fp_abs(F16, x);
	if (mag < 0x0100) {             /* below 2^-16 */
		int rm = fp_rmode(c);
		bool inf = rm == RM_N || (rm == RM_P && !a.sign) || (rm == RM_M && a.sign);
		c->flags |= FPSR_OFC | FPSR_IXC;
		return inf ? fp_inf(F16, a.sign) : fp_maxnormal(F16, a.sign);
	}
	if (fp_fz(F16, c) && mag >= 0x7400) {   /* 2^14 and above */
		c->flags |= FPSR_UFC;
		return fp_zero(F16, a.sign);
	}
	u64 frac = (x & 0x3ff) << 42;
	int e = (int)((x >> 10) & 0x1f);
	if (e == 0) {
		if (!((frac >> 51) & 1)) {
			e = -1;
			frac = (frac & ((1ULL << 50) - 1)) << 2;
		} else {
			frac = (frac & ((1ULL << 51) - 1)) << 1;
		}
	}
	u32 scaled = (u32)(0x100 | ((frac >> 44) & 0xff));
	int re = 29 - e;
	u32 est = recip_estimate(scaled);
	u64 rf = (u64)(est & 0xff) << 44;
	if (re == 0) {
		rf = (1ULL << 51) | (rf >> 1);
	} else if (re == -1) {
		rf = (1ULL << 50) | (rf >> 2);
		re = 0;
	}
	return fp_zero(F16, a.sign) | ((u64)(re & 0x1f) << 10) | ((rf >> 42) & 0x3ff);
}

static u64
fp_rsqrte16(u64 x, struct fpc *c)
{
	struct fpv a = fp_unpack(F16, x, c);
	if (a.type >= T_QNAN) {
		return fp_nan(F16, a.type, x, c);
	}
	if (a.type == T_ZERO) {
		c->flags |= FPSR_DZC;
		return fp_inf(F16, a.sign);
	}
	if (a.sign) {
		return fp_invalid(F16, c);
	}
	if (a.type == T_INF) {
		return 0;
	}
	u64 frac = (x & 0x3ff) << 42;
	int e = (int)((x >> 10) & 0x1f);
	if (e == 0) {
		while (!((frac >> 51) & 1)) {
			frac = (frac & ((1ULL << 51) - 1)) << 1;
			e--;
		}
		frac = (frac & ((1ULL << 51) - 1)) << 1;
	}
	u32 scaled = (e & 1) == 0 ? (u32)(0x100 | ((frac >> 44) & 0xff)) : (u32)(0x80 | ((frac >> 45) & 0x7f));
	int d = 44 - e;
	int re = d >= 0 ? d / 2 : -((-d + 1) / 2);
	u32 est = rsqrt_estimate(scaled);
	return ((u64)(re & 0x1f) << 10) | ((u64)(est & 0xff) << 2);
}

static u64
fp_recpx16(u64 x, struct fpc *c)
{
	struct fpv a = fp_unpack(F16, x, c);
	if (a.type >= T_QNAN) {
		return fp_nan(F16, a.type, x, c);
	}
	u64 e = (x >> 10) & 0x1f;
	if (a.type == T_ZERO || e == 0) {
		return fp_zero(F16, a.sign) | ((u64)0x1e << 10);
	}
	return fp_zero(F16, a.sign) | ((~e & 0x1f) << 10);
}

/* FPRecipStepFused (is_rsqrt false) and FPRSqrtStepFused (is_rsqrt true), op1 already handled here */
static u64
fp_step(int f, u64 x, u64 y, bool is_rsqrt, struct fpc *c)
{
	x = fp_neg(f, x);
	struct fpv a = fp_unpack(f, x, c), b = fp_unpack(f, y, c);
	u64 r;
	if (fp_nans2(f, &a, &b, x, y, c, &r)) {
		return r;
	}
	int bias = (1 << (fmts[f].e - 1)) - 1;
	if ((a.type == T_INF && b.type == T_ZERO) || (a.type == T_ZERO && b.type == T_INF)) {
		if (is_rsqrt) { /* 1.5 */
			return ((u64)bias << fmts[f].f) | (1ULL << (fmts[f].f - 1));
		}
		return (u64)(bias + 1) << fmts[f].f;    /* 2.0 */
	}
	int sp = a.sign ^ b.sign;
	if (a.type == T_INF || b.type == T_INF) {
		return fp_inf(f, sp);
	}
	int rs, re;
	u128 rm;
	bool zerop = a.type == T_ZERO || b.type == T_ZERO;
	add_exact(0, 0, is_rsqrt ? 3 : 2, sp, a.exp + b.exp, zerop ? 0 : (u128)a.mant * b.mant, &rs, &re, &rm);
	if (rm == 0) {
		return fp_zero(f, fp_rmode(c) == RM_M);
	}
	if (is_rsqrt) {
		re -= 1;
	}
	return fp_round(f, c, rs, re, rm, fp_rmode(c));
}

/* FJCVTZS: returns the word, *z the Z flag */
static u32
fp_fjcvtzs(u64 x, struct fpc *c, int *z)
{
	struct fpv a = fp_unpack(F64, x, c);
	*z = 0;
	if (a.type >= T_QNAN || a.type == T_INF) {
		c->flags |= FPSR_IOC;
		return 0;
	}
	if (a.type == T_ZERO) {
		/* a denormal flushed to zero is not an exact zero */
		*z = !a.sign && (x & ((1ULL << 52) - 1)) == 0;
		return 0;
	}
	/* truncate; the value modulo 2^32 */
	u64 frac_lost = 0, low;
	bool big = false;
	if (a.exp >= 0) {
		low = a.exp >= 64 ? 0 : a.mant << a.exp;
		big = a.exp >= 11 || (a.mant >> (63 - a.exp)) != 0;     /* mant has 53 bits: at or above 2^63 */
	} else if (a.exp <= -64) {
		low = 0;
		frac_lost = 1;
	} else {
		low = a.mant >> -a.exp;
		frac_lost = a.mant & ((1ULL << -a.exp) - 1);
	}
	if (!big) {
		big = a.sign ? low > (1ULL << 31) : low > 0x7fffffffULL;
	}
	u32 r = (u32)(a.sign ? 0 - low : low);
	if (big) {
		c->flags |= FPSR_IOC;
	} else if (frac_lost) {
		c->flags |= FPSR_IXC;
	} else {
		*z = 1;
	}
	return r;
}

/* ---- register helpers ---- */
static inline u64
vlane(const u64 *q, int esz_log2, int idx)
{
	int bits = 8 << esz_log2;
	int pos = idx * bits;
	u64 w = q[pos >> 6] >> (pos & 63);
	return bits == 64 ? w : w & ((1ULL << bits) - 1);
}
static inline void
vset(u64 *q, int esz_log2, int idx, u64 val)
{
	int bits = 8 << esz_log2;
	int pos = idx * bits;
	if (bits == 64) {
		q[pos >> 6] = val;
	} else {
		u64 m = ((1ULL << bits) - 1) << (pos & 63);
		q[pos >> 6] = (q[pos >> 6] & ~m) | ((val << (pos & 63)) & m);
	}
}
static inline void
vput(struct a64emu_cpu *c, int r, u64 lo, u64 hi)
{
	c->v[r][0] = lo;
	c->v[r][1] = hi;
}
static inline u64
xget(const struct a64emu_cpu *c, int r)
{
	return r == 31 ? 0 : c->r->x[r];
}
static inline void
xset(struct a64emu_cpu *c, int r, u64 val)
{
	if (r != 31) {
		c->r->x[r] = val;
	}
}
static inline u64
xsp(const struct a64emu_cpu *c, int r)
{
	return r == 31 ? c->r->sp : c->r->x[r];
}
static inline bool
cond_holds(u32 pstate, u32 cond)
{
	u32 n = BIT(pstate, 31), z = BIT(pstate, 30), cf = BIT(pstate, 29), v = BIT(pstate, 28);
	bool r;
	switch (cond >> 1) {
	case 0: r = z; break;
	case 1: r = cf; break;
	case 2: r = n; break;
	case 3: r = v; break;
	case 4: r = cf && !z; break;
	case 5: r = n == v; break;
	case 6: r = n == v && !z; break;
	default: r = true; break;
	}
	if ((cond & 1) && cond != 15) {
		r = !r;
	}
	return r;
}

/* ---- FP16 lane operations ---- */
enum {
	V_FMAXNM, V_FMLA, V_FADD, V_FMULX, V_FCMEQ, V_FMAX, V_FRECPS, V_FMINNM, V_FMLS, V_FSUB, V_FMIN, V_FRSQRTS,
	V_FMAXNMP, V_FADDP, V_FMUL, V_FCMGE, V_FACGE, V_FMAXP, V_FDIV, V_FMINNMP, V_FABD, V_FCMGT, V_FACGT, V_FMINP, V_BAD
};
enum {
	U_FRINTN, U_FRINTM, U_FRINTP, U_FRINTZ, U_FRINTA, U_FRINTX, U_FRINTI,
	U_FCVTNS, U_FCVTMS, U_FCVTAS, U_FCVTPS, U_FCVTZS, U_FCVTNU, U_FCVTMU, U_FCVTAU, U_FCVTPU, U_FCVTZU,
	U_SCVTF, U_UCVTF, U_FCMGT0, U_FCMEQ0, U_FCMLT0, U_FCMGE0, U_FCMLE0, U_FABS, U_FNEG, U_FSQRT, U_FRECPE, U_FRSQRTE, U_FRECPX, U_BAD
};

static u64
bin16(int op, u64 d, u64 a, u64 b, struct fpc *c)
{
	switch (op) {
	case V_FMAXNM: case V_FMAXNMP: return fp_maxminnum(F16, a, b, true, c);
	case V_FMINNM: case V_FMINNMP: return fp_maxminnum(F16, a, b, false, c);
	case V_FMAX: case V_FMAXP: return fp_maxmin(F16, a, b, true, c);
	case V_FMIN: case V_FMINP: return fp_maxmin(F16, a, b, false, c);
	case V_FMLA: return fp_muladd(F16, d, a, b, c);
	case V_FMLS: return fp_muladd(F16, d, fp_neg(F16, a), b, c);
	case V_FADD: case V_FADDP: return fp_addsub(F16, a, b, false, c);
	case V_FSUB: return fp_addsub(F16, a, b, true, c);
	case V_FABD: return fp_abs(F16, fp_addsub(F16, a, b, true, c));
	case V_FMUL: return fp_mul(F16, a, b, false, c);
	case V_FMULX: return fp_mul(F16, a, b, true, c);
	case V_FDIV: return fp_div(F16, a, b, c);
	case V_FCMEQ: return fp_cmpq(F16, a, b, C_EQ, c) ? 0xffff : 0;
	case V_FCMGE: return fp_cmpq(F16, a, b, C_GE, c) ? 0xffff : 0;
	case V_FCMGT: return fp_cmpq(F16, a, b, C_GT, c) ? 0xffff : 0;
	case V_FACGE: return fp_cmpq(F16, fp_abs(F16, a), fp_abs(F16, b), C_GE, c) ? 0xffff : 0;
	case V_FACGT: return fp_cmpq(F16, fp_abs(F16, a), fp_abs(F16, b), C_GT, c) ? 0xffff : 0;
	case V_FRECPS: return fp_step(F16, a, b, false, c);
	case V_FRSQRTS: return fp_step(F16, a, b, true, c);
	default: return 0;
	}
}

static u64
un16(int op, u64 a, int fbits, int M, struct fpc *c)
{
	switch (op) {
	case U_FRINTN: return fp_roundint(F16, a, RM_N, false, c);
	case U_FRINTM: return fp_roundint(F16, a, RM_M, false, c);
	case U_FRINTP: return fp_roundint(F16, a, RM_P, false, c);
	case U_FRINTZ: return fp_roundint(F16, a, RM_Z, false, c);
	case U_FRINTA: return fp_roundint(F16, a, RM_A, false, c);
	case U_FRINTX: return fp_roundint(F16, a, fp_rmode(c), true, c);
	case U_FRINTI: return fp_roundint(F16, a, fp_rmode(c), false, c);
	case U_FCVTNS: return fp_tofixed(F16, a, fbits, false, RM_N, M, c);
	case U_FCVTMS: return fp_tofixed(F16, a, fbits, false, RM_M, M, c);
	case U_FCVTAS: return fp_tofixed(F16, a, fbits, false, RM_A, M, c);
	case U_FCVTPS: return fp_tofixed(F16, a, fbits, false, RM_P, M, c);
	case U_FCVTZS: return fp_tofixed(F16, a, fbits, false, RM_Z, M, c);
	case U_FCVTNU: return fp_tofixed(F16, a, fbits, true, RM_N, M, c);
	case U_FCVTMU: return fp_tofixed(F16, a, fbits, true, RM_M, M, c);
	case U_FCVTAU: return fp_tofixed(F16, a, fbits, true, RM_A, M, c);
	case U_FCVTPU: return fp_tofixed(F16, a, fbits, true, RM_P, M, c);
	case U_FCVTZU: return fp_tofixed(F16, a, fbits, true, RM_Z, M, c);
	case U_SCVTF: return fp_fromfixed(F16, a, M, fbits, false, c);
	case U_UCVTF: return fp_fromfixed(F16, a, M, fbits, true, c);
	case U_FCMGT0: return fp_cmpq(F16, a, 0, C_GT, c) ? 0xffff : 0;
	case U_FCMEQ0: return fp_cmpq(F16, a, 0, C_EQ, c) ? 0xffff : 0;
	case U_FCMLT0: return fp_cmpq(F16, 0, a, C_GT, c) ? 0xffff : 0;
	case U_FCMGE0: return fp_cmpq(F16, a, 0, C_GE, c) ? 0xffff : 0;
	case U_FCMLE0: return fp_cmpq(F16, 0, a, C_GE, c) ? 0xffff : 0;
	case U_FABS: return fp_abs(F16, a);
	case U_FNEG: return fp_neg(F16, a);
	case U_FSQRT: return fp_sqrt(F16, a, c);
	case U_FRECPE: return fp_recpe16(a, c);
	case U_FRSQRTE: return fp_rsqrte16(a, c);
	case U_FRECPX: return fp_recpx16(a, c);
	default: return 0;
	}
}

/* ---- FP16 decoder ---- */
enum {
	K_NONE, K_S1, K_CMP, K_IMM, K_CCMP, K_S2, K_CSEL, K_FMA, K_F2I, K_I2F, K_FMOV_TOGEN, K_FMOV_FROMGEN, K_F2X, K_X2F,
	K_V3, K_S3, K_V2, K_S2M, K_SP, K_ACROSS, K_VE, K_SE, K_VSH, K_SSH, K_VIMM
};
struct fp16op {
	int kind, op;
};

static int
dec3(u32 U, u32 a, u32 o)
{
	static const int8_t t[4][8] = {
		/* U0 a0 */ {V_FMAXNM, V_FMLA, V_FADD, V_FMULX, V_FCMEQ, V_BAD, V_FMAX, V_FRECPS},
		/* U0 a1 */ {V_FMINNM, V_FMLS, V_FSUB, V_BAD, V_BAD, V_BAD, V_FMIN, V_FRSQRTS},
		/* U1 a0 */ {V_FMAXNMP, V_BAD, V_FADDP, V_FMUL, V_FCMGE, V_FACGE, V_FMAXP, V_FDIV},
		/* U1 a1 */ {V_FMINNMP, V_BAD, V_FABD, V_BAD, V_FCMGT, V_FACGT, V_FMINP, V_BAD},
	};
	return t[U * 2 + a][o];
}

static int
dec2(u32 U, u32 a, u32 o, bool scalar)
{
	int r = U_BAD;
	if (!U && !a) {
		switch (o) {
		case 0x18: r = U_FRINTN; break;
		case 0x19: r = U_FRINTM; break;
		case 0x1a: r = U_FCVTNS; break;
		case 0x1b: r = U_FCVTMS; break;
		case 0x1c: r = U_FCVTAS; break;
		case 0x1d: r = U_SCVTF; break;
		}
	} else if (!U && a) {
		switch (o) {
		case 0x0c: r = U_FCMGT0; break;
		case 0x0d: r = U_FCMEQ0; break;
		case 0x0e: r = U_FCMLT0; break;
		case 0x0f: r = U_FABS; break;
		case 0x18: r = U_FRINTP; break;
		case 0x19: r = U_FRINTZ; break;
		case 0x1a: r = U_FCVTPS; break;
		case 0x1b: r = U_FCVTZS; break;
		case 0x1d: r = U_FRECPE; break;
		case 0x1f: r = U_FRECPX; break;
		}
	} else if (U && !a) {
		switch (o) {
		case 0x18: r = U_FRINTA; break;
		case 0x19: r = U_FRINTX; break;
		case 0x1a: r = U_FCVTNU; break;
		case 0x1b: r = U_FCVTMU; break;
		case 0x1c: r = U_FCVTAU; break;
		case 0x1d: r = U_UCVTF; break;
		}
	} else {
		switch (o) {
		case 0x0c: r = U_FCMGE0; break;
		case 0x0d: r = U_FCMLE0; break;
		case 0x0f: r = U_FNEG; break;
		case 0x19: r = U_FRINTI; break;
		case 0x1a: r = U_FCVTPU; break;
		case 0x1b: r = U_FCVTZU; break;
		case 0x1d: r = U_FRSQRTE; break;
		case 0x1f: r = U_FSQRT; break;
		}
	}
	if (scalar) {
		switch (r) {
		case U_FRINTN: case U_FRINTM: case U_FRINTP: case U_FRINTZ: case U_FRINTA: case U_FRINTX: case U_FRINTI:
		case U_FABS: case U_FNEG: case U_FSQRT:
			return U_BAD;
		}
	} else if (r == U_FRECPX) {
		return U_BAD;
	}
	return r;
}

static bool
fp16_decode(u32 i, struct fp16op *o)
{
	o->kind = K_NONE;
	o->op = 0;
	/* scalar FP, type = half */
	if ((i & 0xFFE07C00) == 0x1EE04000) {
		u32 opc = BITS(i, 20, 15);
		if (opc <= 3 || (opc >= 8 && opc <= 15 && opc != 13)) {
			o->kind = K_S1;
			o->op = (int)opc;
			return true;
		}
		return false;
	}
	if ((i & 0xFFE0FC07) == 0x1EE02000) {
		o->kind = K_CMP;
		return true;
	}
	if ((i & 0xFFE01FE0) == 0x1EE01000) {
		o->kind = K_IMM;
		return true;
	}
	if ((i & 0xFFE00C00) == 0x1EE00400) {
		o->kind = K_CCMP;
		return true;
	}
	if ((i & 0xFFE00C00) == 0x1EE00800) {
		o->op = (int)BITS(i, 15, 12);
		if (o->op > 8) {
			return false;
		}
		o->kind = K_S2;
		return true;
	}
	if ((i & 0xFFE00C00) == 0x1EE00C00) {
		o->kind = K_CSEL;
		return true;
	}
	if ((i & 0xFFC00000) == 0x1FC00000) {
		o->kind = K_FMA;
		return true;
	}
	if ((i & 0x7FE0FC00) == 0x1EE00000) {
		u32 rmode = BITS(i, 20, 19), opc = BITS(i, 18, 16);
		if (opc <= 1) {
			o->kind = K_F2I;
			return true;
		}
		if (rmode == 0) {
			if (opc == 2 || opc == 3) {
				o->kind = K_I2F;
				return true;
			}
			if (opc == 4 || opc == 5) {
				o->kind = K_F2I;
				return true;
			}
			if (opc == 6) {
				o->kind = K_FMOV_TOGEN;
				return true;
			}
			if (opc == 7) {
				o->kind = K_FMOV_FROMGEN;
				return true;
			}
		}
		return false;
	}
	if ((i & 0x7FE00000) == 0x1EC00000) {
		u32 rmode = BITS(i, 20, 19), opc = BITS(i, 18, 16), scale = BITS(i, 15, 10);
		if (!BIT(i, 31) && scale < 32) {
			return false;
		}
		if (rmode == 0 && (opc == 2 || opc == 3)) {
			o->kind = K_X2F;
			return true;
		}
		if (rmode == 3 && (opc == 0 || opc == 1)) {
			o->kind = K_F2X;
			return true;
		}
		return false;
	}
	/* AdvSIMD */
	if ((i & 0x9F60C400) == 0x0E400400) {
		o->op = dec3(BIT(i, 29), BIT(i, 23), BITS(i, 13, 11));
		if (o->op == V_BAD) {
			return false;
		}
		o->kind = K_V3;
		return true;
	}
	if ((i & 0xDF60C400) == 0x5E400400) {
		u32 U = BIT(i, 29), a = BIT(i, 23), oo = BITS(i, 13, 11);
		int op = dec3(U, a, oo);
		switch (op) {
		case V_FMULX: case V_FCMEQ: case V_FRECPS: case V_FRSQRTS: case V_FCMGE: case V_FACGE: case V_FABD: case V_FCMGT: case V_FACGT:
			o->op = op;
			o->kind = K_S3;
			return true;
		}
		return false;
	}
	if ((i & 0x9F7E0C00) == 0x0E780800) {
		o->op = dec2(BIT(i, 29), BIT(i, 23), BITS(i, 16, 12), false);
		if (o->op == U_BAD) {
			return false;
		}
		o->kind = K_V2;
		return true;
	}
	if ((i & 0xDF7E0C00) == 0x5E780800) {
		o->op = dec2(BIT(i, 29), BIT(i, 23), BITS(i, 16, 12), true);
		if (o->op == U_BAD) {
			return false;
		}
		o->kind = K_S2M;
		return true;
	}
	if ((i & 0xFF7E0C00) == 0x5E300800) {
		u32 a = BIT(i, 23), oo = BITS(i, 16, 12);
		if (oo == 0x0c) {
			o->op = a ? V_FMINNMP : V_FMAXNMP;
		} else if (oo == 0x0d && !a) {
			o->op = V_FADDP;
		} else if (oo == 0x0f) {
			o->op = a ? V_FMINP : V_FMAXP;
		} else {
			return false;
		}
		o->kind = K_SP;
		return true;
	}
	if ((i & 0xBF7E0C00) == 0x0E300800) {
		u32 a = BIT(i, 23), oo = BITS(i, 16, 12);
		if (oo == 0x0c) {
			o->op = a ? V_FMINNMP : V_FMAXNMP;
		} else if (oo == 0x0f) {
			o->op = a ? V_FMINP : V_FMAXP;
		} else {
			return false;
		}
		o->kind = K_ACROSS;
		return true;
	}
	if ((i & 0x9FC00400) == 0x0F000000 || (i & 0xDFC00400) == 0x5F000000) {
		u32 U = BIT(i, 29), oo = BITS(i, 15, 12);
		bool scalar = (i & 0xDFC00400) == 0x5F000000;
		if (!U && oo == 1) {
			o->op = V_FMLA;
		} else if (!U && oo == 5) {
			o->op = V_FMLS;
		} else if (!U && oo == 9) {
			o->op = V_FMUL;
		} else if (U && oo == 9) {
			o->op = V_FMULX;
		} else {
			return false;
		}
		o->kind = scalar ? K_SE : K_VE;
		return true;
	}
	if ((i & 0x9FF00400) == 0x0F100400 || (i & 0xDFF00400) == 0x5F100400) {
		u32 U = BIT(i, 29), oo = BITS(i, 15, 11);
		bool scalar = (i & 0xDFF00400) == 0x5F100400;
		if (oo == 0x1c) {
			o->op = U ? U_UCVTF : U_SCVTF;
		} else if (oo == 0x1f) {
			o->op = U ? U_FCVTZU : U_FCVTZS;
		} else {
			return false;
		}
		o->kind = scalar ? K_SSH : K_VSH;
		return true;
	}
	if ((i & 0xBFF8FC00) == 0x0F00FC00) {
		o->kind = K_VIMM;
		return true;
	}
	return false;
}

static u64
vfpimm16(u32 imm8)
{
	u64 s = (imm8 >> 7) & 1, b = (imm8 >> 6) & 1, cd = (imm8 >> 4) & 3, efgh = imm8 & 15;
	/* sign : NOT(b) : b b : c d : efgh : 000000 */
	return (s << 15) | ((b ^ 1) << 14) | (b << 13) | (b << 12) | (cd << 10) | (efgh << 6);
}

static void
fp16_run(struct a64emu_cpu *c, u32 i, const struct fp16op *o)
{
	int rd = (int)BITS(i, 4, 0), rn = (int)BITS(i, 9, 5), rm = (int)BITS(i, 20, 16);
	struct fpc fc = { *c->fpcr, 0 };
	u32 Q = BIT(i, 30);
	int lanes = Q ? 8 : 4;
	u64 n[2] = { c->v[rn][0], c->v[rn][1] };
	u64 m[2] = { c->v[rm][0], c->v[rm][1] };
	u64 d[2] = { c->v[rd][0], c->v[rd][1] };
	u64 a0 = n[0] & 0xffff, b0 = m[0] & 0xffff;
	u64 r[2] = { 0, 0 };

	switch (o->kind) {
	case K_S1:
		switch (o->op) {
		case 0: r[0] = a0; break;
		case 1: r[0] = fp_abs(F16, a0); break;
		case 2: r[0] = fp_neg(F16, a0); break;
		case 3: r[0] = fp_sqrt(F16, a0, &fc); break;
		case 8: r[0] = fp_roundint(F16, a0, RM_N, false, &fc); break;
		case 9: r[0] = fp_roundint(F16, a0, RM_P, false, &fc); break;
		case 10: r[0] = fp_roundint(F16, a0, RM_M, false, &fc); break;
		case 11: r[0] = fp_roundint(F16, a0, RM_Z, false, &fc); break;
		case 12: r[0] = fp_roundint(F16, a0, RM_A, false, &fc); break;
		case 14: r[0] = fp_roundint(F16, a0, fp_rmode(&fc), true, &fc); break;
		case 15: r[0] = fp_roundint(F16, a0, fp_rmode(&fc), false, &fc); break;
		}
		vput(c, rd, r[0], 0);
		break;
	case K_CMP: {
		u32 opc = BITS(i, 4, 3);
		u32 f = fp_compare(F16, a0, (opc & 1) ? 0 : b0, (opc & 2) != 0, &fc);
		c->r->pstate = (c->r->pstate & 0x0FFFFFFF) | (f << 28);
		break;
	}
	case K_IMM:
		vput(c, rd, vfpimm16(BITS(i, 20, 13)), 0);
		break;
	case K_CCMP: {
		u32 f;
		if (cond_holds(c->r->pstate, BITS(i, 15, 12))) {
			f = fp_compare(F16, a0, b0, BIT(i, 4) != 0, &fc);
		} else {
			f = BITS(i, 3, 0);
		}
		c->r->pstate = (c->r->pstate & 0x0FFFFFFF) | (f << 28);
		break;
	}
	case K_S2: {
		u64 x;
		switch (o->op) {
		case 0: x = fp_mul(F16, a0, b0, false, &fc); break;
		case 1: x = fp_div(F16, a0, b0, &fc); break;
		case 2: x = fp_addsub(F16, a0, b0, false, &fc); break;
		case 3: x = fp_addsub(F16, a0, b0, true, &fc); break;
		case 4: x = fp_maxmin(F16, a0, b0, true, &fc); break;
		case 5: x = fp_maxmin(F16, a0, b0, false, &fc); break;
		case 6: x = fp_maxminnum(F16, a0, b0, true, &fc); break;
		case 7: x = fp_maxminnum(F16, a0, b0, false, &fc); break;
		default: x = fp_neg(F16, fp_mul(F16, a0, b0, false, &fc)); break;
		}
		vput(c, rd, x, 0);
		break;
	}
	case K_CSEL:
		vput(c, rd, cond_holds(c->r->pstate, BITS(i, 15, 12)) ? a0 : b0, 0);
		break;
	case K_FMA: {
		u64 ra = c->v[BITS(i, 14, 10)][0] & 0xffff, x = a0;
		u32 o1 = BIT(i, 21), o0 = BIT(i, 15);
		if (o1) {
			ra = fp_neg(F16, ra);
		}
		if (o1 != o0) {
			x = fp_neg(F16, x);
		}
		vput(c, rd, fp_muladd(F16, ra, x, b0, &fc), 0);
		break;
	}
	case K_F2I: {
		u32 rmode = BITS(i, 20, 19), opc = BITS(i, 18, 16);
		int M = BIT(i, 31) ? 64 : 32, rmd;
		bool uns = (opc & 1) != 0;
		if (opc >= 4) {
			rmd = RM_A;
		} else {
			rmd = rmode == 0 ? RM_N : (rmode == 1 ? RM_P : (rmode == 2 ? RM_M : RM_Z));
		}
		xset(c, rd, fp_tofixed(F16, a0, 0, uns, rmd, M, &fc));
		break;
	}
	case K_I2F: {
		int M = BIT(i, 31) ? 64 : 32;
		u64 v = xget(c, rn);
		vput(c, rd, fp_fromfixed(F16, v, M, 0, BITS(i, 18, 16) == 3, &fc), 0);
		break;
	}
	case K_FMOV_TOGEN:
		xset(c, rd, a0);
		break;
	case K_FMOV_FROMGEN:
		vput(c, rd, xget(c, rn) & 0xffff, 0);
		break;
	case K_F2X: {
		int M = BIT(i, 31) ? 64 : 32;
		xset(c, rd, fp_tofixed(F16, a0, 64 - (int)BITS(i, 15, 10), BITS(i, 18, 16) == 1, RM_Z, M, &fc));
		break;
	}
	case K_X2F: {
		int M = BIT(i, 31) ? 64 : 32;
		vput(c, rd, fp_fromfixed(F16, xget(c, rn), M, 64 - (int)BITS(i, 15, 10), BITS(i, 18, 16) == 3, &fc), 0);
		break;
	}
	case K_V3: {
		bool pairwise = o->op == V_FMAXNMP || o->op == V_FADDP || o->op == V_FMAXP || o->op == V_FMINNMP || o->op == V_FMINP;
		if (pairwise) {
			for (int e = 0; e < lanes / 2; e++) {
				vset(r, 1, e, bin16(o->op, 0, vlane(n, 1, 2 * e), vlane(n, 1, 2 * e + 1), &fc));
			}
			for (int e = 0; e < lanes / 2; e++) {
				vset(r, 1, e + lanes / 2, bin16(o->op, 0, vlane(m, 1, 2 * e), vlane(m, 1, 2 * e + 1), &fc));
			}
		} else {
			for (int e = 0; e < lanes; e++) {
				vset(r, 1, e, bin16(o->op, vlane(d, 1, e), vlane(n, 1, e), vlane(m, 1, e), &fc));
			}
		}
		vput(c, rd, r[0], Q ? r[1] : 0);
		break;
	}
	case K_S3:
		vput(c, rd, bin16(o->op, 0, a0, b0, &fc), 0);
		break;
	case K_V2:
		for (int e = 0; e < lanes; e++) {
			vset(r, 1, e, un16(o->op, vlane(n, 1, e), 0, 16, &fc));
		}
		vput(c, rd, r[0], Q ? r[1] : 0);
		break;
	case K_S2M:
		vput(c, rd, un16(o->op, a0, 0, 16, &fc), 0);
		break;
	case K_SP:
		vput(c, rd, bin16(o->op, 0, vlane(n, 1, 0), vlane(n, 1, 1), &fc), 0);
		break;
	case K_ACROSS: {
		/* FPReduce: a tree, as in the pseudocode */
		u64 t[8];
		int cnt = lanes;
		for (int e = 0; e < lanes; e++) {
			t[e] = vlane(n, 1, e);
		}
		while (cnt > 1) {
			for (int e = 0; e < cnt / 2; e++) {
				t[e] = bin16(o->op, 0, t[2 * e], t[2 * e + 1], &fc);
			}
			cnt /= 2;
		}
		vput(c, rd, t[0], 0);
		break;
	}
	case K_VE:
	case K_SE: {
		int rm4 = (int)BITS(i, 19, 16);
		int idx = (int)((BIT(i, 11) << 2) | (BIT(i, 21) << 1) | BIT(i, 20));
		u64 mm[2] = { c->v[rm4][0], c->v[rm4][1] };
		u64 el = vlane(mm, 1, idx);
		if (o->kind == K_SE) {
			vput(c, rd, bin16(o->op, d[0] & 0xffff, a0, el, &fc), 0);
		} else {
			for (int e = 0; e < lanes; e++) {
				vset(r, 1, e, bin16(o->op, vlane(d, 1, e), vlane(n, 1, e), el, &fc));
			}
			vput(c, rd, r[0], Q ? r[1] : 0);
		}
		break;
	}
	case K_VSH:
	case K_SSH: {
		int fbits = 32 - (int)BITS(i, 22, 16);
		if (o->kind == K_SSH) {
			vput(c, rd, un16(o->op, a0, fbits, 16, &fc), 0);
		} else {
			for (int e = 0; e < lanes; e++) {
				vset(r, 1, e, un16(o->op, vlane(n, 1, e), fbits, 16, &fc));
			}
			vput(c, rd, r[0], Q ? r[1] : 0);
		}
		break;
	}
	case K_VIMM: {
		u32 imm8 = (BITS(i, 18, 16) << 5) | BITS(i, 9, 5);
		u64 h = vfpimm16(imm8);
		u64 w = h | (h << 16) | (h << 32) | (h << 48);
		vput(c, rd, w, Q ? w : 0);
		break;
	}
	default:
		break;
	}
	*c->fpsr |= fc.flags;
}

/* ---- FCMA ---- */
static bool
fcma_valid(u32 i, int *kind)
{
	u32 size = BITS(i, 23, 22), Q = BIT(i, 30);
	if ((i & 0xBF20EC00) == 0x2E00E400) {   /* FCADD */
		if (size == 0 || (size == 3 && !Q)) {
			return false;
		}
		*kind = 0;
		return true;
	}
	if ((i & 0xBF20E400) == 0x2E00C400) {   /* FCMLA vector */
		if (size == 0 || (size == 3 && !Q)) {
			return false;
		}
		*kind = 1;
		return true;
	}
	if ((i & 0xBF009400) == 0x2F001000) {   /* FCMLA by element */
		if (size == 1) {
			if (BIT(i, 11) && !Q) {
				return false;
			}
		} else if (size == 2) {
			if (BIT(i, 21) || !Q) {
				return false;
			}
		} else {
			return false;
		}
		*kind = 2;
		return true;
	}
	return false;
}

static void
fcma_run(struct a64emu_cpu *c, u32 i, int kind)
{
	u32 size = BITS(i, 23, 22), Q = BIT(i, 30);
	int rd = (int)BITS(i, 4, 0), rn = (int)BITS(i, 9, 5), rm = (int)BITS(i, 20, 16);
	int f = (int)size - 1;
	int el = (int)size;     /* log2 bytes: 1, 2, 3 */
	int lanes = (Q ? 16 : 8) >> el;
	struct fpc fc = { *c->fpcr, 0 };
	u64 n[2] = { c->v[rn][0], c->v[rn][1] }, m[2] = { c->v[rm][0], c->v[rm][1] }, d[2] = { c->v[rd][0], c->v[rd][1] }, r[2] = { 0, 0 };

	if (kind == 0) {
		bool rot270 = BIT(i, 12);
		for (int e = 0; e < lanes; e += 2) {
			u64 m1, m3;
			if (!rot270) {
				m1 = fp_neg(f, vlane(m, el, e + 1));
				m3 = vlane(m, el, e);
			} else {
				m1 = vlane(m, el, e + 1);
				m3 = fp_neg(f, vlane(m, el, e));
			}
			vset(r, el, e, fp_addsub(f, vlane(n, el, e), m1, false, &fc));
			vset(r, el, e + 1, fp_addsub(f, vlane(n, el, e + 1), m3, false, &fc));
		}
	} else {
		u32 rot = kind == 1 ? BITS(i, 12, 11) : BITS(i, 14, 13);
		int idx = 0;
		if (kind == 2) {
			if (size == 1) {
				idx = (int)((BIT(i, 11) << 1) | BIT(i, 21));
			} else {
				idx = (int)BIT(i, 11);
			}
		}
		for (int e = 0; e < lanes; e += 2) {
			/* pairs: the by-element form takes the same pair of Vm for each pair, inside each 128-bit part */
			u64 mre, mim;
			if (kind == 1) {
				mre = vlane(m, el, e);
				mim = vlane(m, el, e + 1);
			} else {
				mre = vlane(m, el, 2 * idx);
				mim = vlane(m, el, 2 * idx + 1);
			}
			u64 nre = vlane(n, el, e), nim = vlane(n, el, e + 1);
			u64 a1, a2, b1, b2;     /* d.re += a1 x a2; d.im += b1 x b2 */
			switch (rot) {
			case 0:
				a1 = nre;
				a2 = mre;
				b1 = nre;
				b2 = mim;
				break;
			case 1:
				a1 = nim;
				a2 = fp_neg(f, mim);
				b1 = nim;
				b2 = mre;
				break;
			case 2:
				a1 = nre;
				a2 = fp_neg(f, mre);
				b1 = nre;
				b2 = fp_neg(f, mim);
				break;
			default:
				a1 = nim;
				a2 = mim;
				b1 = nim;
				b2 = fp_neg(f, mre);
				break;
			}
			vset(r, el, e, fp_muladd(f, vlane(d, el, e), a1, a2, &fc));
			vset(r, el, e + 1, fp_muladd(f, vlane(d, el, e + 1), b1, b2, &fc));
		}
	}
	vput(c, rd, r[0], Q ? r[1] : 0);
	*c->fpsr |= fc.flags;
}

/* ---- FHM ---- */
static bool
fhm_valid(u32 i, int *kind)
{
	if ((i & 0xBF60FC00) == 0x0E20EC00 || (i & 0xBF60FC00) == 0x2E20CC00) {
		*kind = 0;
		return true;
	}
	if ((i & 0xBFC0F400) == 0x0F800000 || (i & 0xBFC0F400) == 0x0F804000 ||
	    (i & 0xBFC0F400) == 0x2F808000 || (i & 0xBFC0F400) == 0x2F80C000) {
		*kind = 1;
		return true;
	}
	return false;
}

/* a half as a single, by bits: a NaN stays signalling or quiet; a denormal is flushed when FZ16 asks for it */
static u64
h2s_bits(u64 h, const struct fpc *c)
{
	u64 s = (h >> 15) & 1, e = (h >> 10) & 0x1f, fr = h & 0x3ff;
	u64 r = s << 31;
	if (e == 0x1f) {
		return r | 0x7f800000 | (fr << 13);
	}
	if (e == 0) {
		if (fr == 0 || (c->fpcr & FPCR_FZ16)) {
			return r;
		}
		int sh = __builtin_clzll(fr) - 53;      /* top bit of fr to bit 10 */
		fr <<= sh;
		return r | ((u64)(127 - 14 - sh) << 23) | ((fr & 0x3ff) << 13);
	}
	return r | ((e - 15 + 127) << 23) | (fr << 13);
}

static void
fhm_run(struct a64emu_cpu *c, u32 i, int kind)
{
	u32 Q = BIT(i, 30);
	int rd = (int)BITS(i, 4, 0), rn = (int)BITS(i, 9, 5);
	int lanes = Q ? 4 : 2;
	bool sub, upper;
	int rm, idx = -1;
	struct fpc fc = { *c->fpcr, 0 };
	if (kind == 0) {
		sub = BIT(i, 23);
		upper = BIT(i, 29);
		rm = (int)BITS(i, 20, 16);
	} else {
		sub = BIT(i, 14);
		upper = BIT(i, 29);
		rm = (int)BITS(i, 19, 16);
		idx = (int)((BIT(i, 11) << 2) | (BIT(i, 21) << 1) | BIT(i, 20));
	}
	u64 n[2] = { c->v[rn][0], c->v[rn][1] }, m[2] = { c->v[rm][0], c->v[rm][1] }, d[2] = { c->v[rd][0], c->v[rd][1] }, r[2] = { 0, 0 };
	int off = upper ? lanes : 0;
	for (int e = 0; e < lanes; e++) {
		u64 en = h2s_bits(vlane(n, 1, off + e), &fc);
		u64 em = h2s_bits(vlane(m, 1, idx >= 0 ? idx : off + e), &fc);
		if (sub) {
			en = fp_neg(F32, en);
		}
		vset(r, 2, e, fp_muladd(F32, vlane(d, 2, e), en, em, &fc));
	}
	vput(c, rd, r[0], Q ? r[1] : 0);
	*c->fpsr |= fc.flags;
}

/* ---- integer SIMD: DotProd, RDM ---- */
static inline u32
dot4(u32 a, u32 b, bool uns)
{
	u32 s = 0;
	for (int k = 0; k < 4; k++) {
		u32 x = (a >> (8 * k)) & 0xff, y = (b >> (8 * k)) & 0xff;
		if (uns) {
			s += x * y;
		} else {
			s += (u32)((int32_t)(int8_t)x * (int32_t)(int8_t)y);
		}
	}
	return s;
}

static void
dot_run(struct a64emu_cpu *c, u32 i)
{
	u32 Q = BIT(i, 30);
	bool uns = BIT(i, 29);
	int rd = (int)BITS(i, 4, 0), rn = (int)BITS(i, 9, 5), rm = (int)BITS(i, 20, 16);
	bool byelem = (i & 0x9FC0F400) == 0x0F80E000;
	u64 n[2] = { c->v[rn][0], c->v[rn][1] }, m[2] = { c->v[rm][0], c->v[rm][1] }, d[2] = { c->v[rd][0], c->v[rd][1] }, r[2] = { d[0], Q ? d[1] : 0 };
	int idx = (int)((BIT(i, 11) << 1) | BIT(i, 21));
	for (int e = 0; e < (Q ? 4 : 2); e++) {
		vset(r, 2, e, (u32)vlane(d, 2, e) + dot4((u32)vlane(n, 2, e), (u32)vlane(m, 2, byelem ? idx : e), uns));
	}
	vput(c, rd, r[0], r[1]);
}

static inline int64_t
sat_to(int64_t v, int bits, bool *sat)
{
	int64_t mx = (1LL << (bits - 1)) - 1, mn = -mx - 1;
	if (v > mx) {
		*sat = true;
		return mx;
	}
	if (v < mn) {
		*sat = true;
		return mn;
	}
	return v;
}

static inline u64
sqrdml(u64 d, u64 n, u64 m, int bits, bool sub, bool *sat)
{
	int sh = 64 - bits;
	/* signed lanes */
	int64_t ed = (int64_t)(d << sh) >> sh, en = (int64_t)(n << sh) >> sh, em = (int64_t)(m << sh) >> sh;
	__int128 acc = (__int128)ed << (bits - 1);
	__int128 pr = (__int128)en * em;
	acc = sub ? acc - pr : acc + pr;
	acc += (__int128)1 << (bits - 2);
	acc >>= bits - 1;
	int64_t v;
	int64_t mx = (1LL << (bits - 1)) - 1, mn = -mx - 1;
	if (acc > mx) {
		v = mx;
		*sat = true;
	} else if (acc < mn) {
		v = mn;
		*sat = true;
	} else {
		v = (int64_t)acc;
	}
	return (u64)v & (bits == 32 ? 0xffffffffULL : 0xffffULL);
}

static bool
rdm_valid(u32 i, int *kind)
{
	u32 size = BITS(i, 23, 22);
	if (size != 1 && size != 2) {
		return false;
	}
	if ((i & 0xBF20F400) == 0x2E008400) {
		*kind = 0;      /* vector */
		return BIT(i, 30) || true;
	}
	if ((i & 0xFF20F400) == 0x7E008400) {
		*kind = 1;      /* scalar */
		return true;
	}
	if ((i & 0xBF00D400) == 0x2F00D000) {
		*kind = 2;      /* vector, by element */
		return true;
	}
	if ((i & 0xFF00D400) == 0x7F00D000) {
		*kind = 3;      /* scalar, by element */
		return true;
	}
	return false;
}

static void
rdm_run(struct a64emu_cpu *c, u32 i, int kind)
{
	u32 size = BITS(i, 23, 22), Q = BIT(i, 30);
	int el = (int)size, bits = 8 << el;
	int rd = (int)BITS(i, 4, 0), rn = (int)BITS(i, 9, 5), rm = (int)BITS(i, 20, 16);
	bool sub, sat = false;
	int idx = -1;
	if (kind <= 1) {
		sub = BIT(i, 11);
	} else {
		sub = BIT(i, 13);
		if (size == 1) {
			rm = (int)BITS(i, 19, 16);
			idx = (int)((BIT(i, 11) << 2) | (BIT(i, 21) << 1) | BIT(i, 20));
		} else {
			idx = (int)((BIT(i, 11) << 1) | BIT(i, 21));
		}
	}
	u64 n[2] = { c->v[rn][0], c->v[rn][1] }, m[2] = { c->v[rm][0], c->v[rm][1] }, d[2] = { c->v[rd][0], c->v[rd][1] }, r[2] = { 0, 0 };
	bool scalar = kind == 1 || kind == 3;
	int lanes = scalar ? 1 : ((Q ? 16 : 8) >> el);
	for (int e = 0; e < lanes; e++) {
		vset(r, el, e, sqrdml(vlane(d, el, e), vlane(n, el, e), vlane(m, el, idx >= 0 ? idx : e), bits, sub, &sat));
	}
	vput(c, rd, r[0], (!scalar && Q) ? r[1] : 0);
	if (sat) {
		*c->fpsr |= FPSR_QC;
	}
}

/* ---- SHA3, SHA512 ---- */
static inline u64
ror64(u64 x, int n)
{
	n &= 63;
	return n ? (x >> n) | (x << (64 - n)) : x;
}
static inline u64
rol64(u64 x, int n)
{
	return ror64(x, 64 - n);
}

static bool
sha3_valid(u32 i)
{
	return (i & 0xFFE08000) == 0xCE000000 || (i & 0xFFE08000) == 0xCE200000 || (i & 0xFFE0F000) == 0xCE608000 ||
	       (i & 0xFFE00000) == 0xCE800000 || (i & 0xFFFFFC00) == 0xCEC08000 || (i & 0xFFFFFC00) == 0xCEC08400;
}

static void
sha3_run(struct a64emu_cpu *c, u32 i)
{
	int rd = (int)BITS(i, 4, 0), rn = (int)BITS(i, 9, 5), rm = (int)BITS(i, 20, 16), ra = (int)BITS(i, 14, 10);
	u64 n0 = c->v[rn][0], n1 = c->v[rn][1], m0 = c->v[rm][0], m1 = c->v[rm][1], d0 = c->v[rd][0], d1 = c->v[rd][1];
	u64 r0, r1;
	if ((i & 0xFFE08000) == 0xCE000000) {           /* EOR3 */
		r0 = n0 ^ m0 ^ c->v[ra][0];
		r1 = n1 ^ m1 ^ c->v[ra][1];
	} else if ((i & 0xFFE08000) == 0xCE200000) {    /* BCAX */
		r0 = n0 ^ (m0 & ~c->v[ra][0]);
		r1 = n1 ^ (m1 & ~c->v[ra][1]);
	} else if ((i & 0xFFE00000) == 0xCE800000) {    /* XAR */
		int sh = (int)BITS(i, 15, 10);
		r0 = ror64(n0 ^ m0, sh);
		r1 = ror64(n1 ^ m1, sh);
	} else if ((i & 0xFFFFFC00) == 0xCEC08000) {    /* SHA512SU0 */
#define S0(x) (ror64((x), 1) ^ ror64((x), 8) ^ ((x) >> 7))
		r0 = d0 + S0(d1);
		r1 = d1 + S0(n0);
	} else if ((i & 0xFFE0FC00) == 0xCE608C00) {    /* RAX1 */
		r0 = n0 ^ rol64(m0, 1);
		r1 = n1 ^ rol64(m1, 1);
	} else if ((i & 0xFFE0FC00) == 0xCE608800) {    /* SHA512SU1 */
#define S1(x) (ror64((x), 19) ^ ror64((x), 61) ^ ((x) >> 6))
		r0 = d0 + S1(n0) + m0;
		r1 = d1 + S1(n1) + m1;
	} else {
#define B1(x) (ror64((x), 14) ^ ror64((x), 18) ^ ror64((x), 41))
#define B0(x) (ror64((x), 28) ^ ror64((x), 34) ^ ror64((x), 39))
		if (BIT(i, 10) == 0) {  /* SHA512H: X = Vn, Y = Vm, W = Vd */
			u64 t = ((m1 & n0) ^ (~m1 & n1)) + B1(m1) + d1;
			u64 u = t + m0;
			r1 = t;
			r0 = ((u & m1) ^ (~u & n0)) + B1(u) + d0;
		} else {                /* SHA512H2 */
			u64 t = ((n0 & m1) ^ (n0 & m0) ^ (m1 & m0)) + B0(m0) + d1;
			r1 = t;
			r0 = ((t & m0) ^ (t & m1) ^ (m1 & m0)) + B0(t) + d0;
		}
	}
	vput(c, rd, r0, r1);
}

/* ---- PAC, RCpc, LSE ---- */
#define LP_RET  0
#define LP_BR   1
#define LP_BLR  2
static int
pac_kind(u32 i)
{
	if (i == 0xD65F0BFF || i == 0xD65F0FFF) {
		return 1;       /* RETAA RETAB */
	}
	if ((i & 0xFEFFF800) == 0xD61F0800) {   /* BRAA BRAB BRAAZ BRABZ: Z form when bit 24 is 0, Rm must be 31 */
		return (BIT(i, 24) || BITS(i, 4, 0) == 31) ? 2 : 0;
	}
	if ((i & 0xFEFFF800) == 0xD63F0800) {   /* BLRAA ... */
		return (BIT(i, 24) || BITS(i, 4, 0) == 31) ? 3 : 0;
	}
	if ((i & 0xFF200400) == 0xF8200400) {
		return 4;       /* LDRAA LDRAB */
	}
	if ((i & 0xFFFFC000) == 0xDAC10000) {   /* opcode 8-15 are the Z forms: Rn must be 31 */
		return (!BIT(i, 13) || BITS(i, 9, 5) == 31) ? 5 : 0;
	}
	if ((i & 0xFFFFFBE0) == 0xDAC143E0) {
		return 5;       /* XPACI XPACD: a plain pointer has nothing to strip */
	}
	if ((i & 0xFFE0FC00) == 0x9AC03000) {
		return 6;       /* PACGA */
	}
	return 0;
}

/* The access is at a real user address: no bit 55, inside the map. Returns the address without the top byte (TBI0). */
static bool
user_addr(const struct a64emu_cpu *c, u64 a, u32 size, u64 *va)
{
	if (c->kernel_va) {
		*va = a;
		return true;
	}
	u64 s = a & 0x00FFFFFFFFFFFFFFULL;
	if (BIT(a, 55) || s + size > c->limit || s + size < s) {
		return false;
	}
	*va = s;
	return true;
}

static enum a64emu_result
memerr(int e, u64 addr, bool write, struct a64emu_out *o)
{
	if (e == A64EMU_ERR_RETRY) {
		return A64EMU_RETRY;
	}
	o->addr = addr;
	o->write = write;
	return A64EMU_FAULT;
}

static enum a64emu_result
badaddr(u64 addr, bool write, struct a64emu_out *o)
{
	o->addr = addr;
	o->write = write;
	return A64EMU_FAULT;
}

static bool
lse_decode(u32 i, int *cls)
{
	if ((i & 0x3F200C00) == 0x38200000) {
		u32 o3 = BIT(i, 15), opc = BITS(i, 14, 12);
		if (!o3 || opc == 0) {
			*cls = A64E_LSE;
			return true;
		}
		if (opc == 4 && BITS(i, 20, 16) == 31 && BIT(i, 23) && !BIT(i, 22)) {
			*cls = A64E_RCPC;       /* LDAPR */
			return true;
		}
		return false;
	}
	if ((i & 0x3FA07C00) == 0x08A07C00) {
		*cls = A64E_LSE;
		return true;
	}
	if ((i & 0xBFA07C00) == 0x08207C00) {
		if ((BITS(i, 20, 16) & 1) || (BITS(i, 4, 0) & 1)) {
			return false;
		}
		*cls = A64E_CASP;
		return true;
	}
	return false;
}

typedef int (*casp_fn)(u64, u64, u64, u64, u64, u64 *);
static const casp_fn casp_fns[4] = { a64emu_casp, a64emu_casp_l, a64emu_casp_a, a64emu_casp_al };
static const a64emu_rmw_fn rmw_fns[4][4] = {
	{ a64emu_rmw_b, a64emu_rmw_b_l, a64emu_rmw_b_a, a64emu_rmw_b_al },
	{ a64emu_rmw_h, a64emu_rmw_h_l, a64emu_rmw_h_a, a64emu_rmw_h_al },
	{ a64emu_rmw_w, a64emu_rmw_w_l, a64emu_rmw_w_a, a64emu_rmw_w_al },
	{ a64emu_rmw_x, a64emu_rmw_x_l, a64emu_rmw_x_a, a64emu_rmw_x_al },
};
/*
 * FEAT_LSE2 (an A13 has it): an unaligned atomic inside one 16-byte block is single-copy atomic. LDXR cannot do that, LDXP on the block can:
 * the same exclusive monitor, so still atomic against user LL/SC.
 */
static int
lse2_run(u64 va, u32 size, u32 ord, u32 op, u64 val, u64 cmp, u64 *old)
{
	u64 base = va & ~15ULL, cur[2] = { 0, 0 }, want[2], got[2];
	u32 off = (u32)(va & 15), bytes = 1u << size;
	int e = casp_fns[ord](base, 0, 0, 0, 0, cur);
	if (e != 0) {
		return e;
	}
	for (int tries = 0; tries < 4096; tries++) {
		u64 v = 0, n = 0;
		int sh = 64 - (8 << size);
		u8 *cb = (u8 *)cur;
		for (u32 k = 0; k < bytes; k++) {
			v |= (u64)cb[off + k] << (8 * k);
		}
		int64_t sv = (int64_t)(v << sh) >> sh, sw = (int64_t)(val << sh) >> sh;
		switch (op) {
		case 0: n = v + val; break;
		case 1: n = v & ~val; break;
		case 2: n = v ^ val; break;
		case 3: n = v | val; break;
		case 4: n = sv > sw ? v : val; break;
		case 5: n = sv < sw ? v : val; break;
		case 6: n = v > val ? v : val; break;
		case 7: n = v < val ? v : val; break;
		case 8: n = val; break;
		default: n = v == cmp ? val : v; break;
		}
		want[0] = cur[0];
		want[1] = cur[1];
		u8 *wb = (u8 *)want;
		for (u32 k = 0; k < bytes; k++) {
			wb[off + k] = (u8)(n >> (8 * k));
		}
		e = casp_fns[ord](base, cur[0], cur[1], want[0], want[1], got);
		if (e != 0) {
			return e;
		}
		if (got[0] == cur[0] && got[1] == cur[1]) {
			*old = v;
			return 0;
		}
		cur[0] = got[0];
		cur[1] = got[1];
	}
	return A64EMU_ERR_RETRY;
}

static enum a64emu_result
lse_run(struct a64emu_cpu *c, u32 i, struct a64emu_out *o)
{
	u32 size = i >> 30;
	int rs = (int)BITS(i, 20, 16), rn = (int)BITS(i, 9, 5), rt = (int)BITS(i, 4, 0);
	u64 addr = xsp(c, rn);
	u32 bytes = 1u << size;
	u64 mask = size == 3 ? ~0ULL : (1ULL << (8 << size)) - 1;
	u64 old = 0, va;
	int e, dst;

	if (rn == 31 && (addr & 15)) {
		return A64EMU_SP_ALIGN;
	}
	if ((i & 0x3FA07C00) == 0x08A07C00) {   /* CAS: L = bit 22 is acquire, o0 = bit 15 is release */
		u32 ord = (BIT(i, 22) << 1) | BIT(i, 15);
		if ((addr & 15) + bytes > 16) {
			o->addr = addr;
			o->write = true;
			return A64EMU_ALIGN;
		}
		if (!user_addr(c, addr, bytes, &va)) {
			return badaddr(addr, true, o);
		}
		if (addr & (bytes - 1)) {
			e = lse2_run(va, size, ord, 9, xget(c, rt) & mask, xget(c, rs) & mask, &old);
		} else {
			e = rmw_fns[size][ord](va, 9, xget(c, rt) & mask, xget(c, rs) & mask, &old);
		}
		dst = rs;
	} else {
		u32 ord = (BIT(i, 23) << 1) | BIT(i, 22);
		u32 op = BIT(i, 15) ? 8 : BITS(i, 14, 12);
		if ((addr & 15) + bytes > 16) {
			o->addr = addr;
			o->write = true;
			return A64EMU_ALIGN;
		}
		if (!user_addr(c, addr, bytes, &va)) {
			return badaddr(addr, true, o);
		}
		if (addr & (bytes - 1)) {
			e = lse2_run(va, size, ord, op, xget(c, rs) & mask, 0, &old);
		} else {
			e = rmw_fns[size][ord](va, op, xget(c, rs) & mask, 0, &old);
		}
		dst = rt;
	}
	if (e != 0) {
		return memerr(e, addr, true, o);
	}
	xset(c, dst, old);
	return A64EMU_OK;
}

static enum a64emu_result
casp_run(struct a64emu_cpu *c, u32 i, struct a64emu_out *o)
{
	bool dbl = BIT(i, 30);
	int rs = (int)BITS(i, 20, 16), rn = (int)BITS(i, 9, 5), rt = (int)BITS(i, 4, 0);
	u32 ord = (BIT(i, 22) << 1) | BIT(i, 15);
	u32 bytes = dbl ? 16 : 8;
	u64 addr = xsp(c, rn), va;
	int e;

	if (rn == 31 && (addr & 15)) {
		return A64EMU_SP_ALIGN;
	}
	if (addr & (bytes - 1)) {
		o->addr = addr;
		o->write = true;
		return A64EMU_ALIGN;
	}
	if (!user_addr(c, addr, bytes, &va)) {
		return badaddr(addr, true, o);
	}
	if (dbl) {
		u64 old[2] = { 0, 0 };
		e = casp_fns[ord](va, xget(c, rs), rs == 31 ? 0 : xget(c, rs + 1), xget(c, rt), rt == 31 ? 0 : xget(c, rt + 1), old);
		if (e != 0) {
			return memerr(e, addr, true, o);
		}
		xset(c, rs, old[0]);
		xset(c, rs + 1, old[1]);
	} else {
		/* a pair of words is one single-copy atomic doubleword: CAS on the doubleword */
		u64 cmp = (xget(c, rs) & 0xffffffffULL) | (xget(c, rs + 1) << 32);
		u64 val = (xget(c, rt) & 0xffffffffULL) | (xget(c, rt + 1) << 32);
		u64 old = 0;
		e = rmw_fns[3][ord](va, 9, val, cmp, &old);
		if (e != 0) {
			return memerr(e, addr, true, o);
		}
		xset(c, rs, old & 0xffffffffULL);
		xset(c, rs + 1, old >> 32);
	}
	return A64EMU_OK;
}

/* LDAPR, LDAPUR*, STLUR, LDLAR, STLLR */
static bool
rcpc_valid(u32 i)
{
	if ((i & 0x3F200C00) == 0x19000000) {
		u32 size = i >> 30, opc = BITS(i, 23, 22);
		return !(opc >= 2 && (size == 3 || (size == 2 && opc == 3)));
	}
	return (i & 0x3FFFFC00) == 0x08DF7C00 || (i & 0x3FFFFC00) == 0x089F7C00;
}

static enum a64emu_result
rcpc_load(struct a64emu_cpu *c, u64 addr, u32 size, bool sx, bool to32, int rt, struct a64emu_out *o, bool must_align)
{
	u32 bytes = 1u << size;
	u64 v = 0, va;
	int e;
	if (!user_addr(c, addr, bytes, &va)) {
		return badaddr(addr, false, o);
	}
	if (addr & (bytes - 1)) {
		if (must_align && ((addr & 15) + bytes > 16)) {
			o->addr = addr;
			o->write = false;
			return A64EMU_ALIGN;
		}
		/* LSE2: unaligned inside 16 bytes. LDAR would fault: a plain load, then a barrier for the acquire */
		e = a64emu_load(va, size, &v);
		__asm__ volatile ("dmb ishld" : : : "memory");
	} else {
		e = a64emu_load_acq(va, size, &v);
	}
	if (e != 0) {
		return memerr(e, addr, false, o);
	}
	if (sx) {
		int sh = 64 - (8 << size);
		v = (u64)((int64_t)(v << sh) >> sh);
		if (to32) {
			v &= 0xffffffffULL;
		}
	}
	xset(c, rt, v);
	return A64EMU_OK;
}

static enum a64emu_result
rcpc_run(struct a64emu_cpu *c, u32 i, struct a64emu_out *o)
{
	u32 size = i >> 30;
	int rn = (int)BITS(i, 9, 5), rt = (int)BITS(i, 4, 0);
	u64 addr = xsp(c, rn);

	if (rn == 31 && (addr & 15)) {
		return A64EMU_SP_ALIGN;
	}
	if ((i & 0x3F200C00) == 0x38200000) {   /* LDAPR */
		return rcpc_load(c, addr, size, false, false, rt, o, true);
	}
	if ((i & 0x3FFFFC00) == 0x08DF7C00) {   /* LDLAR: as LDAR */
		return rcpc_load(c, addr, size, false, false, rt, o, true);
	}
	if ((i & 0x3FFFFC00) != 0x089F7C00) {
		int64_t off = (int64_t)BITS(i, 20, 12);
		if (off & 0x100) {
			off -= 0x200;
		}
		addr += (u64)off;
		u32 opc = BITS(i, 23, 22);
		if (opc == 1) {
			return rcpc_load(c, addr, size, false, false, rt, o, true);
		}
		if (opc >= 2) {
			return rcpc_load(c, addr, size, true, opc == 3, rt, o, true);
		}
	}
	/* STLUR, STLLR */
	{
		u32 bytes = 1u << size;
		u64 va;
		int e;
		if (!user_addr(c, addr, bytes, &va)) {
			return badaddr(addr, true, o);
		}
		if (addr & (bytes - 1)) {
			if ((addr & 15) + bytes > 16) {
				o->addr = addr;
				o->write = true;
				return A64EMU_ALIGN;
			}
			__asm__ volatile ("dmb ish" : : : "memory");
			e = a64emu_store(va, size, xget(c, rt));
		} else {
			e = a64emu_store_rel(va, size, xget(c, rt));
		}
		if (e != 0) {
			return memerr(e, addr, true, o);
		}
	}
	return A64EMU_OK;
}

/* ---- system ---- */
#define MRS_DIT  0xD53B42A0u
#define MSR_DIT  0xD51B42A0u
#define MRS_APPL 0xD53EF1A0u    /* S3_6_C15_C1_5 */
static bool
sys_valid(u32 i)
{
	return (i & 0xFFFFFFE0) == MRS_DIT || (i & 0xFFFFFFE0) == MSR_DIT || (i & 0xFFFFFFE0) == MRS_APPL ||
	       (i & 0xFFFFFEFF) == 0xD503405F || i == 0xD50330FF;
}

/* ---- the one decoder ---- */
int
a64emu_classify(u32 i)
{
	struct fp16op o;
	int k;
	if (pac_kind(i)) {
		return A64E_PAC;
	}
	if (lse_decode(i, &k)) {
		return k;
	}
	if (rcpc_valid(i)) {
		return A64E_RCPC;
	}
	if (fp16_decode(i, &o)) {
		return A64E_FP16;
	}
	if (fcma_valid(i, &k)) {
		return A64E_FCMA;
	}
	if (fhm_valid(i, &k)) {
		return A64E_FHM;
	}
	if ((i & 0x9FE0FC00) == 0x0E809400 || (i & 0x9FC0F400) == 0x0F80E000) {
		return A64E_DOTPROD;
	}
	if ((i & 0xFFFFFC00) == 0x1E7E0000) {
		return A64E_JSCVT;
	}
	if (sha3_valid(i)) {
		return A64E_SHA3;
	}
	if (rdm_valid(i, &k)) {
		return A64E_RDM;
	}
	if (sys_valid(i)) {
		return A64E_SYSREG;
	}
	return -1;
}

static enum a64emu_result
pac_run(struct a64emu_cpu *c, u32 i, int kind, struct a64emu_out *o, bool *branched)
{
	int rn = (int)BITS(i, 9, 5), rd = (int)BITS(i, 4, 0), rm = (int)BITS(i, 20, 16);
	(void)rm;
	switch (kind) {
	case 1:
		c->r->pc = c->r->x[30];
		*branched = true;
		return A64EMU_OK;
	case 3: {
		u64 t = xget(c, rn);
		c->r->x[30] = c->r->pc + 4;
		c->r->pc = t;
		*branched = true;
		return A64EMU_OK;
	}
	case 2:
		c->r->pc = xget(c, rn);
		*branched = true;
		return A64EMU_OK;
	case 4: {
		int64_t off = (int64_t)((BIT(i, 22) << 9) | BITS(i, 20, 12));
		if (off & 0x200) {
			off -= 0x400;
		}
		off *= 8;
		u64 base = xsp(c, rn), ea = base + (u64)off, v = 0, va;
		if (rn == 31 && (base & 15)) {
			return A64EMU_SP_ALIGN;
		}
		if (!user_addr(c, ea, 8, &va)) {
			return badaddr(ea, false, o);
		}
		int e = a64emu_load(va, 3, &v);
		if (e != 0) {
			return memerr(e, ea, false, o);
		}
		if (BIT(i, 11)) {
			if (rn == 31) {
				c->r->sp = ea;
			} else {
				c->r->x[rn] = ea;
			}
		}
		xset(c, rd, v);
		return A64EMU_OK;
	}
	case 5:
		return A64EMU_OK;       /* every pointer is plain on this CPU: the same rule as the lowering tool */
	default:
		xset(c, rd, 0);         /* PACGA: the lowering tool writes MOVZ Xd, #0; both must agree */
		return A64EMU_OK;
	}
}

enum a64emu_result
a64emu_run(struct a64emu_cpu *c, u32 i, struct a64emu_out *o)
{
	int cls = a64emu_classify(i), k;
	enum a64emu_result res = A64EMU_OK;
	bool branched = false;

	o->cls = cls;
	o->addr = 0;
	o->write = false;
	if (cls < 0 || (c->off & (1u << cls))) {
		return A64EMU_UNKNOWN;
	}
	switch (cls) {
	case A64E_PAC:
		res = pac_run(c, i, pac_kind(i), o, &branched);
		break;
	case A64E_LSE:
		res = lse_run(c, i, o);
		break;
	case A64E_CASP:
		res = casp_run(c, i, o);
		break;
	case A64E_RCPC:
		res = rcpc_run(c, i, o);
		break;
	case A64E_FP16: {
		struct fp16op op;
		(void)fp16_decode(i, &op);
		fp16_run(c, i, &op);
		break;
	}
	case A64E_FCMA:
		(void)fcma_valid(i, &k);
		fcma_run(c, i, k);
		break;
	case A64E_FHM:
		(void)fhm_valid(i, &k);
		fhm_run(c, i, k);
		break;
	case A64E_DOTPROD:
		dot_run(c, i);
		break;
	case A64E_JSCVT: {
		struct fpc fc = { *c->fpcr, 0 };
		int z;
		u32 w = fp_fjcvtzs(c->v[BITS(i, 9, 5)][0], &fc, &z);
		xset(c, (int)BITS(i, 4, 0), w);
		c->r->pstate = (c->r->pstate & 0x0FFFFFFF) | ((u32)z << 30);
		*c->fpsr |= fc.flags;
		break;
	}
	case A64E_SHA3:
		sha3_run(c, i);
		break;
	case A64E_RDM:
		(void)rdm_valid(i, &k);
		rdm_run(c, i, k);
		break;
	case A64E_SYSREG:
		if ((i & 0xFFFFFFE0) == MRS_DIT || (i & 0xFFFFFFE0) == MRS_APPL) {
			xset(c, (int)BITS(i, 4, 0), 0);
		}
		/* MSR DIT, MSR DIT #imm: this CPU has no DIT. SB: the exception entry and return stop speculation */
		break;
	default:
		return A64EMU_UNKNOWN;
	}
	if (res != A64EMU_OK) {
		return res;
	}
	if (!branched) {
		c->r->pc += 4;
	}
	/*
	 * A debugger's step: the trapped word did not complete, so the saved SPSR.SS is 1. The word is done now: with SS 0 the CPU takes the
	 * step exception at the next instruction, before it runs, with the PC there. One word, one step.
	 */
	c->r->pstate &= ~PSTATE_SS;
	return A64EMU_OK;
}

/* ---- known answers, for the check at start ---- */
struct selfcase {
	uint8_t cls;
	u32 word;
	u64 a_lo, a_hi, b_lo, b_hi;     /* v1, v2 */
	u64 want_lo, want_hi;           /* v0, or x0 in want_lo for words with a GPR result */
};
static const struct selfcase selfcases[] = {
	/* fadd h0, h1, h2: 1.0 + 1.0 = 2.0 */
	{ A64E_FP16, 0x1EE22820, 0x3c00, 0, 0x3c00, 0, 0x4000, 0 },
	/* fmul v0.4h, v1.4h, v2.4h: 2.0 x 3.0 = 6.0 in each lane */
	{ A64E_FP16, 0x2E421C20, 0x4000400040004000ULL, 0, 0x4200420042004200ULL, 0, 0x4600460046004600ULL, 0 },
	/* fcadd v0.2s, v1.2s, v2.2s, #90: (1, 2) + i x (3, 4) = (1 - 4, 2 + 3) = (-3, 5) */
	{ A64E_FCMA, 0x2E82E420, 0x400000003f800000ULL, 0, 0x4080000040400000ULL, 0, 0x40a00000c0400000ULL, 0 },
	/* sdot v0.2s, v1.8b, v2.8b: 1x1 + 2x1 + 3x1 + 4x1 = 10 */
	{ A64E_DOTPROD, 0x0E829420, 0x04030201ULL, 0, 0x01010101ULL, 0, 10, 0 },
	/* fjcvtzs w0, d1: 2^32 + 5 -> 5, out of range */
	{ A64E_JSCVT, 0x1E7E0020, 0x41F0000000500000ULL, 0, 0, 0, 5, 0 },
	/* fmlal v0.2s, v1.2h, v2.2h: 0 + 1.0 x 2.0 = 2.0f */
	{ A64E_FHM, 0x0E22EC20, 0x3c003c00ULL, 0, 0x40004000ULL, 0, 0x4000000040000000ULL, 0 },
	/* eor3 v0.16b, v1.16b, v2.16b, v0.16b */
	{ A64E_SHA3, 0xCE020020, 0xF0F0F0F0F0F0F0F0ULL, 1, 0x0F0F0F0F0F0F0F0FULL, 2, ~0ULL, 3 },
	/* sqrdmlah v0.8h, v1.8h, v2.8h: 0x4000 x 0x4000 x 2 >> 16 = 0x2000 */
	{ A64E_RDM, 0x6E428420, 0x4000400040004000ULL, 0x4000400040004000ULL, 0x4000400040004000ULL, 0x4000400040004000ULL, 0x2000200020002000ULL, 0x2000200020002000ULL },
	/* mrs x0, DIT */
	{ A64E_SYSREG, 0xD53B42A0, 0, 0, 0, 0, 0, 0 },
	/* xpacd x0 keeps x0 */
	{ A64E_PAC, 0xDAC147E0, 0, 0, 0, 0, 0x1234, 0 },
};

int
a64emu_selfcheck(int cls)
{
	int n = 0;
	for (unsigned k = 0; k < sizeof(selfcases) / sizeof(selfcases[0]); k++) {
		const struct selfcase *t = &selfcases[k];
		if (t->cls != cls) {
			continue;
		}
		n++;
		u64 v[32][2];
		for (int q = 0; q < 32; q++) {
			v[q][0] = v[q][1] = 0;
		}
		struct a64emu_regs r;
		for (int q = 0; q < 31; q++) {
			r.x[q] = 0;
		}
		r.sp = 0;
		r.pc = 0x1000;
		r.pstate = 0;
		u32 fpsr = 0, fpcr = 0;
		struct a64emu_cpu c = { &r, v, &fpsr, &fpcr, 0, 0, true };
		struct a64emu_out o;
		v[1][0] = t->a_lo;
		v[1][1] = t->a_hi;
		v[2][0] = t->b_lo;
		v[2][1] = t->b_hi;
		if (cls == A64E_PAC) {
			r.x[0] = 0x1234;
		}
		if (a64emu_run(&c, t->word, &o) != A64EMU_OK || r.pc != 0x1004) {
			return (int)k + 1;
		}
		if (cls == A64E_JSCVT || cls == A64E_SYSREG || cls == A64E_PAC) {
			if (r.x[0] != t->want_lo) {
				return (int)k + 1;
			}
		} else if (v[0][0] != t->want_lo || v[0][1] != t->want_hi) {
			return (int)k + 1;
		}
	}
	if (cls == A64E_LSE || cls == A64E_CASP || cls == A64E_RCPC) {
		/* the same asm as user memory, on a kernel cell */
		static volatile u64 cell[2] __attribute__((aligned(16)));
		u64 v[32][2];
		struct a64emu_regs r;
		for (int q = 0; q < 31; q++) {
			r.x[q] = 0;
		}
		r.sp = 0;
		r.pc = 0;
		r.pstate = 0;
		u32 fpsr = 0, fpcr = 0;
		struct a64emu_cpu c = { &r, v, &fpsr, &fpcr, 0, 0, true };
		struct a64emu_out o;
		cell[0] = 5;
		cell[1] = 7;
		r.x[0] = (u64)&cell[0];
		if (cls == A64E_LSE) {
			r.x[1] = 3;
			/* ldaddal x1, x2, [x0] */
			if (a64emu_run(&c, 0xF8E10002, &o) != A64EMU_OK || r.x[2] != 5 || cell[0] != 8) {
				return 100;
			}
			/* casal x2, x1, [x0]: old 5 does not match 8: no store, x2 = 8 */
			if (a64emu_run(&c, 0xC8E2FC01, &o) != A64EMU_OK || r.x[2] != 8 || cell[0] != 8) {
				return 101;
			}
		} else if (cls == A64E_CASP) {
			/* casp x2, x3, x4, x5, [x0]: the pair (5, 7) matches */
			r.x[2] = 5;
			r.x[3] = 7;
			r.x[4] = 11;
			r.x[5] = 13;
			if (a64emu_run(&c, 0x48227C04, &o) != A64EMU_OK || r.x[2] != 5 || r.x[3] != 7 || cell[0] != 11 || cell[1] != 13) {
				return 102;
			}
		} else {
			/* ldapr x1, [x0] */
			if (a64emu_run(&c, 0xF8BFC001, &o) != A64EMU_OK || r.x[1] != 5) {
				return 103;
			}
		}
		n++;
	}
	return n == 0 ? 999 : 0;
}
