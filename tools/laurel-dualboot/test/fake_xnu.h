/*
 * Just enough of XNU for the real bsd/dev/sweet_ufs.c to build on the host: scripts/laurel/test-dualboot.sh renames its ufs_scsi and gives a
 * fake one over a RAM disk, so every path above the SCSI command (GPT, self-check, mapping, fence, strategy, console log) is the kernel's own code.
 */
#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <setjmp.h>
#include <sys/types.h>

#define ARM64_BOARD_CONFIG_SWEET 1
#define __unused __attribute__((unused))
#define MIN(a, b) ((a) < (b) ? (a) : (b))
#define assert(x) do { if (!(x)) { fprintf(stderr, "assert: %s\n", #x); abort(); } } while (0)
#define __builtin_arm_dsb(x) ((void)0)
#define NSEC_PER_SEC 1000000000ull
#define NSEC_PER_USEC 1000ull
#define DEV_BSIZE 512
#define INT_MAX 2147483647
#define PAGE_MASK 4095ul
#define PZERO 22
#define KERN_SUCCESS 0
#define kSuccess 0
#define THREAD_UNINT 0
#define THREAD_WAITING 1
#define THREAD_CONTINUE_NULL ((void (*)(void *, int))0)
#define TIMEOUT_URGENCY_SYS_CRITICAL 0
#define VM_KERN_MEMORY_IOKIT 0
#define KMA_DATA 0
#define KMA_ZERO 0
#define KMA_PERMANENT 0
#define Z_WAITOK 0
#define FWRITE 2
#define B_READ 1
#define B_WRITE 0
#define D_DISK 2
#define DEVFS_BLOCK 0
#define DEVFS_CHAR 1
#define UID_ROOT 0
#define GID_OPERATOR 5
#define CTLFLAG_RD 0
#define CTLFLAG_LOCKED 0
#define OID_AUTO 0
#define SYSCTL_INT(...) extern int fake_sysctl_unused
#define kalloc_data(sz, fl) aligned_alloc(16, ((sz) + 15) & ~15ul)
#define DKIOCGETBLOCKSIZE 1
#define DKIOCSETBLOCKSIZE 2
#define DKIOCGETPHYSICALBLOCKSIZE 3
#define DKIOCGETBLOCKCOUNT 4
#define DKIOCISWRITABLE 5
#define DKIOCSYNCHRONIZE 6
#define DKIOCSYNCHRONIZECACHE 7
#define DKIOCGETMAXBLOCKCOUNTREAD 8
#define DKIOCGETMAXBLOCKCOUNTWRITE 9
#define DKIOCGETMAXSEGMENTCOUNTREAD 10
#define DKIOCGETMAXSEGMENTCOUNTWRITE 11
#define DKIOCISSOLIDSTATE 12
#define relaxed __ATOMIC_RELAXED
#define os_atomic_add_orig(p, v, m) __c11_atomic_fetch_add((p), (v), (m))
#define os_atomic_load(p, m) __c11_atomic_load((p), (m))
#define LCK_GRP_DECLARE(a, b) int a __attribute__((unused))
#define LCK_MTX_DECLARE(a, b) int a
#define makedev(ma, mi) (((ma) << 24) | (mi))
#define panic(...) do { printf("PANIC: " __VA_ARGS__); printf("\n"); abort(); } while (0)
typedef unsigned int ppnum_t;
typedef int kern_return_t;
#define TRUE 1
typedef uint64_t addr64_t;
typedef void *pmap_t;
typedef void *thread_t;
typedef void *event_t;
typedef int wait_result_t;
typedef void (*thread_continue_t)(void *, wait_result_t);
typedef uintptr_t vm_offset_t;
typedef uintptr_t vm_size_t;
typedef void *DTEntry;
typedef struct fake_buf *buf_t;
struct proc;
struct uio;
struct fake_buf { int64_t blkno; uint32_t count, resid; int flags, error, done; char *data; };
extern pmap_t kernel_pmap;
extern void *kernel_map;
#define ptoa_64(x) ((uint64_t)(x) << 12)
#define atop_64(x) ((uint64_t)(x) >> 12)
struct bdevsw { void *d_open, *d_close; void (*d_strategy)(buf_t); void *d_ioctl, *d_dump; int (*d_psize)(dev_t); int d_type; };
struct cdevsw { void *d_open, *d_close, *d_read, *d_write, *d_ioctl, *d_stop, *d_reset, *d_ttys, *d_select, *d_mmap, *d_strategy, *d_reserved_1, *d_reserved_2; int d_type; };
#define eno_dump NULL
#define eno_stop NULL
#define eno_reset NULL
#define eno_select NULL
#define eno_mmap NULL
#define eno_strat NULL
#define eno_getc NULL
#define eno_putc NULL
/* the boot and the machine: test_kernel.c */
int SecureDTLookupEntry(void *, const char *, DTEntry *);
int SecureDTGetProperty(DTEntry, const char *, void const **, unsigned int *);
bool PE_parse_boot_argn(const char *, void *, int);
void lck_mtx_lock(int *);
void lck_mtx_unlock(int *);
int kmem_alloc_contig(void *, vm_offset_t *, size_t, unsigned long, ppnum_t, int, int, int);
int bdevsw_add(int, const struct bdevsw *);
int cdevsw_add_with_bdev(int, const struct cdevsw *, int);
void *devfs_make_node(dev_t, int, int, int, int, const char *, ...);
int tsleep(void *, int, const char *, int);
uint64_t mach_absolute_time(void);
void nanoseconds_to_absolutetime(uint64_t, uint64_t *);
void absolutetime_to_nanoseconds(uint64_t, uint64_t *);
void clock_interval_to_deadline(unsigned, unsigned long long, uint64_t *);
int assert_wait_deadline(void *, int, uint64_t);
int assert_wait_deadline_with_leeway(void *, int, int, uint64_t, uint64_t);
void thread_block(void *);
void delay(int);
bool ml_get_interrupts_enabled(void);
bool ml_at_interrupt_context(void);
void flush_dcache64(addr64_t, unsigned, int);
void clean_dcache64(addr64_t, unsigned, int);
int physio(void (*)(buf_t), void *, dev_t, int, void *, struct uio *, int);
void minphys(void);
static inline void fake_buf_setresid(buf_t b, uint32_t r) { b->resid = r; }
#define buf_blkno(b) ((b)->blkno)
#define buf_count(b) ((b)->count)
#define buf_flags(b) ((b)->flags)
#define buf_setresid(b, r) fake_buf_setresid((b), (r))
#define buf_seterror(b, e) ((b)->error = (e))
#define buf_biodone(b) ((b)->done = 1)
#define buf_map(b, p) (*(p) = (b)->data, 0)
#define buf_unmap(b) ((void)0)
