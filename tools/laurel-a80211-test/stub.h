/* Host stand-ins for what bsd/dev/redwood_apple80211.c takes from XNU. Only the test: scripts/laurel/test-apple80211.sh. */
#ifndef LAUREL_A80211_STUB_H
#define LAUREL_A80211_STUB_H
#include <errno.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/param.h>

#ifndef EAUTH
#define EAUTH 80        /* (XNU's number; Linux has none) */
#endif
typedef uint64_t user_addr_t;
typedef int errno_t;
typedef unsigned long u_long_t;
#define USER_ADDR_NULL ((user_addr_t)0)
#define __DECONST(type, var) ((type)(uintptr_t)(const void *)(var))

/* locks: the test has one thread */
#define LCK_GRP_DECLARE(name, label) int name __attribute__((unused))
#define LCK_MTX_DECLARE(name, group) int name __attribute__((unused))
#define lck_mtx_lock(l) ((void)(l))
#define lck_mtx_unlock(l) ((void)(l))
#define os_atomic_xchg(p, v, o) __atomic_exchange_n((p), (v), __ATOMIC_RELAXED)

/* memory: what is not asked to be zero is not zero, so that a field left unset shows */
enum { Z_WAITOK = 1, Z_ZERO = 2 };
static inline void *
kalloc_data(size_t size, int flags)
{
	void *p = malloc(size);

	if (p != NULL) {
		memset(p, flags & Z_ZERO ? 0 : 0xa5, size);
	}
	return p;
}
#define kfree_data(p, size) free(p)
static inline int
memset_s(void *p, size_t room, int c, size_t n)
{
	(void)room;
	memset(p, c, n);
	return 0;
}

/* the caller's memory is this process's: a user address is a pointer */
extern int stub_fault;
static inline int
copyin(user_addr_t from, void *to, size_t n)
{
	if (stub_fault) {
		return EFAULT;
	}
	memcpy(to, (const void *)(uintptr_t)from, n);
	return 0;
}
static inline int
copyout(const void *from, user_addr_t to, size_t n)
{
	if (stub_fault) {
		return EFAULT;
	}
	memcpy((void *)(uintptr_t)to, from, n);
	return 0;
}
static inline void
proc_selfname(char *name, int size)
{
	snprintf(name, (size_t)size, "wifid");
}

/* the log, kept: the test looks into it */
extern char stub_log[1 << 16];
extern size_t stub_log_at;
#define printf(...) (stub_log_at += (size_t)snprintf(stub_log + stub_log_at, sizeof(stub_log) - stub_log_at, __VA_ARGS__))

/* kernel events */
#define KEV_VENDOR_APPLE 1
#define KEV_IEEE80211_CLASS 6
struct kev_d_vectors {
	uint32_t data_length;
	void *data_ptr;
};
struct kev_msg {
	uint32_t vendor_code, kev_class, kev_subclass, event_code;
	struct kev_d_vectors dv[5];
};
int kev_post_msg(struct kev_msg *message);
#endif
