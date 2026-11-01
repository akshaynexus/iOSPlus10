/* Host mock: in order, on this thread */
#include <stddef.h>
#define QOS_CLASS_USER_INTERACTIVE 0x21
static inline void *dispatch_get_global_queue(long a, unsigned long b) { (void)a; (void)b; return NULL; }
static inline void dispatch_apply_f(size_t n, void *q, void *c, void (*f)(void *, size_t)) { (void)q; for (size_t i = 0; i < n; i++) f(c, i); }
