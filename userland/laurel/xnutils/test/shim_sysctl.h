/* Host test only (scripts/laurel/xnutils-test.sh): what helper.c takes from <sys/sysctl.h>; the host has no such calls. */
#include <stddef.h>
#include <sys/types.h>
#define CTL_KERN 1
#define KERN_PROC 14
#define KERN_PROC_ALL 0
struct kinfo_proc { struct { char p_comm[17]; int p_pid; } kp_proc; };
int sysctlbyname(const char *name, void *old, size_t *oldlen, void *new_, size_t newlen);
int sysctl(int *mib, unsigned n, void *old, size_t *oldlen, void *new_, size_t newlen);
