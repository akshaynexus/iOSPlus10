/*
 * Host stand-ins for the XNU headers that bsd/dev/laurel_cell.c (patch 2760) includes, so the test
 * compiles the exact kernel file. scripts/laurel/test-cell.sh makes sys/param.h, sys/systm.h,
 * sys/errno.h, sys/sysctl.h, kern/clock.h, kern/locks.h and pexpert/pexpert.h that include this file.
 */
#ifndef KSTUB_H
#define KSTUB_H
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <strings.h>

#ifndef ARM64_BOARD_CONFIG_SWEET
#define ARM64_BOARD_CONFIG_SWEET 1
#endif
#ifndef MIN
#define MIN(a, b)               ((a) < (b) ? (a) : (b))
#endif
#define __unused                __attribute__((unused))
#ifndef __printflike
#define __printflike(a, b)      __attribute__((format(__printf__, a, b)))
#endif

/* kernel printf -> captured by the test */
int kt_printf(const char *fmt, ...) __attribute__((format(__printf__, 1, 2)));
#define printf                  kt_printf

static inline size_t
kt_strlcpy(char *d, const char *s, size_t n)
{
	size_t l = strlen(s);
	if (n != 0) {
		size_t c = l < n - 1 ? l : n - 1;
		memcpy(d, s, c);
		d[c] = 0;
	}
	return l;
}
#define strlcpy                 kt_strlcpy

/* clock: the test moves kt_now_ns */
extern uint64_t kt_now_ns;
static inline void clock_get_uptime(uint64_t *t) { *t = kt_now_ns; }
static inline void absolutetime_to_nanoseconds(uint64_t t, uint64_t *ns) { *ns = t; }

/* locks: one thread in the test */
typedef struct { int unused; } lck_grp_t;
typedef struct { int unused; } lck_mtx_t;
#define LCK_GRP_DECLARE(n, s)   lck_grp_t n __unused
#define LCK_MTX_DECLARE(n, g)   lck_mtx_t n __unused
static inline void lck_mtx_lock(lck_mtx_t *m) { (void)m; }
static inline void lck_mtx_unlock(lck_mtx_t *m) { (void)m; }

/* sysctl: the handler is called by the test */
struct sysctl_oid { int unused; };
struct sysctl_req { char *out; size_t len; const char *newptr; size_t newlen; };
#define USER_ADDR_NULL          ((const char *)0)
#define SYSCTL_IN(r, p, l)      (memcpy((p), (r)->newptr, (l)), 0)
static inline int
kt_sysctl_out(struct sysctl_req *r, const void *p, size_t l)
{
	if (l > r->len) {
		return 12;
	}
	memcpy(r->out, p, l);
	return 0;
}
#define SYSCTL_OUT(r, p, l)     kt_sysctl_out((r), (p), (l))
#define SYSCTL_PROC(...)        struct kt_sysctl_unused
#define CTLTYPE_STRING          0
#define CTLFLAG_RD              0
#define CTLFLAG_RW              0
#define CTLFLAG_ANYBODY         0
#define CTLFLAG_LOCKED          0
#define OID_AUTO                0

/* boot-args */
int PE_parse_boot_argn(const char *name, void *val, int size);
#endif
