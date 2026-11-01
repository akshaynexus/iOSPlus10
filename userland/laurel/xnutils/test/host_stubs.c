/* Host test only: the phone's calls under helper.c. The power verbs never run on the host (the test does not call them, and this stub of
 * syscall would refuse them). */
#include <errno.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include "shim_sysctl.h"

int sysctlbyname(const char *name, void *old, size_t *oldlen, void *new_, size_t newlen) { (void)name; (void)old; (void)oldlen; (void)new_; (void)newlen; errno = ENOENT; return -1; }
int sysctl(int *mib, unsigned n, void *old, size_t *oldlen, void *new_, size_t newlen) { (void)mib; (void)n; (void)old; (void)oldlen; (void)new_; (void)newlen; errno = ENOENT; return -1; }
int proc_pidpath(int pid, void *b, uint32_t n) { (void)pid; (void)b; (void)n; return 0; }
long xt_no_syscall(long nr, ...) { (void)nr; errno = EPERM; return -1; }
char *collect(void) { static char t[] = "metal.mode=host test\n"; return t; }
