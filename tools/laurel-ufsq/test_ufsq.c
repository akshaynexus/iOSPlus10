/*
 * Host test of the UFS read queue (patch 2971): the real bsd/dev/laurel_ufs_queue.h against a fake host: registers in memory, the doorbell
 * served by threads that read the real request descriptors and fill the real PRDT addresses. HOST ONLY: it says what the code does with a
 * host that follows UFSHCI, not what the phone's controller does.
 * Built by scripts/laurel/test-ufs-queue.sh, which cuts the register and descriptor definitions out of the patched sweet_ufs.c into ufs_defs.h.
 */
#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define __unused __attribute__((unused))
#define MIN(a, b) ((a) < (b) ? (a) : (b))
#define NSEC_PER_SEC 1000000000ull
#define NSEC_PER_USEC 1000ull
#define PAGE_MASK 4095ul
#define TRUE 1
#define KERN_SUCCESS 0
#define THREAD_UNINT 0
#define THREAD_WAITING 1
#define THREAD_CONTINUE_NULL NULL
#define TIMEOUT_URGENCY_SYS_CRITICAL 0
#define KMA_DATA 0
#define KMA_ZERO 0
#define KMA_PERMANENT 0
#define VM_KERN_MEMORY_IOKIT 0
#define Z_WAITOK 0
#define __builtin_arm_dsb(x) atomic_thread_fence(memory_order_seq_cst)
typedef uintptr_t vm_offset_t;
typedef uint64_t addr64_t;
typedef uint64_t ppnum_t;      /* here a page number of a host virtual address */
typedef void *event_t;
typedef void *thread_t;
typedef int wait_result_t;
typedef struct fake_buf { uint32_t resid; } *buf_t;
#define buf_setresid(b, r) ((b)->resid = (r))
#define ptoa_64(x) ((uint64_t)(x) << 12)
#define atop_64(x) ((uint64_t)(x) >> 12)
#define kernel_map NULL
#define kernel_pmap NULL
#define LCK_GRP_DECLARE(a, b) int a __attribute__((unused))
/* the kernel's mutex, as a pthread mutex */
#define LCK_MTX_DECLARE(a, b) pthread_mutex_t a = PTHREAD_MUTEX_INITIALIZER
#define lck_mtx_lock(m) pthread_mutex_lock(m)
#define lck_mtx_unlock(m) pthread_mutex_unlock(m)
#define kalloc_data(sz, fl) malloc(sz)
#define kfree_data(p, sz) free(p)

#include "ufs_defs.h"
/* same text as in the queue header, for the fake host above it */
#define REG_UICCMD      0x90
#define REG_UICARG2     0x98
#define REG_UICARG3     0x9c
#define HCS_UCRDY       (1u << 3)
#define IS_UCCS         (1u << 10)

static uint32_t regs[64];
static pthread_mutex_t hw = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t hw_cv = PTHREAD_COND_INITIALIZER;
static uint32_t pending, busy_tags;
static atomic_uint now_held, peak_held, bad_slot, bad_tag, doorbells_with_many;
static unsigned scripted_nutrs = 32;
/* faults */
static atomic_int fail_ocs_after = -1, hang_after = -1, set_full_after = -1, corrupt_slot = -1;
static atomic_uint served;

static struct {
	vm_offset_t regs, dma;
	uint64_t dma_pa, first_block, nblocks;
} su;

static uint8_t pattern(uint64_t lba, uint32_t off) { return (uint8_t)((lba * 131 + off / 7 + (off & 3)) ^ 0x5a); }

static inline uint32_t ufs_rd(uint32_t off)
{
	pthread_mutex_lock(&hw);
	uint32_t v = off == REG_UTRLDBR ? pending : regs[off / 4];
	pthread_mutex_unlock(&hw);
	return v;
}

static inline void ufs_wr(uint32_t off, uint32_t v)
{
	pthread_mutex_lock(&hw);
	if (off == REG_UTRLDBR) {
		if (__builtin_popcount(v) > 1) {
			doorbells_with_many++;
		}
		pending |= v;                   /* UFSHCI: a 0 changes nothing */
		pthread_cond_broadcast(&hw_cv);
	} else if (off == REG_UTRLCLR) {
		pending &= v;
	} else if (off == REG_IS) {
		regs[REG_IS / 4] &= ~v;
	} else if (off == REG_UICCMD) {
		regs[REG_UICARG2 / 4] = 0;
		regs[REG_UICARG3 / 4] = 3;
		regs[REG_IS / 4] |= IS_UCCS;
	} else {
		regs[off / 4] = v;
	}
	pthread_mutex_unlock(&hw);
}

/* one host thread: takes a rung slot, follows the descriptor, fills the data */
static void *
host_thread(void *arg)
{
	(void)arg;
	for (;;) {
		pthread_mutex_lock(&hw);
		uint32_t ready;
		while ((ready = pending & ~busy_tags) == 0) {
			pthread_cond_wait(&hw_cv, &hw);
		}
		unsigned slot = (unsigned)__builtin_ctz(ready);
		busy_tags |= 1u << slot;
		pthread_mutex_unlock(&hw);

		unsigned held = ++now_held, p = peak_held;
		while (held > p && !atomic_compare_exchange_weak(&peak_held, &p, held)) {
		}
		if (slot % 2 != 0) {
			bad_slot++;
		}
		struct utrd *u = (struct utrd *)(su.dma + DMA_UTRL) + slot;
		struct ucd *c = (struct ucd *)(uintptr_t)(((uint64_t)u->ucdbau << 32) | u->ucdba);
		if (c->cmd[3] != slot) {
			bad_tag++;
		}
		uint64_t lba = ((uint64_t)c->cmd[18] << 24) | (c->cmd[19] << 16) | (c->cmd[20] << 8) | c->cmd[21];
		uint32_t len = ((uint32_t)c->cmd[12] << 24) | (c->cmd[13] << 16) | (c->cmd[14] << 8) | c->cmd[15];
		uint32_t nb = ((uint32_t)c->cmd[23] << 8) | c->cmd[24];
		assert(c->cmd[16] == 0x28 && nb * 4096 == len);
		uint32_t at = 0, seg = u->prdt & 0xffff;
		for (uint32_t k = 0; k < seg; k++) {
			uint8_t *to = (uint8_t *)(uintptr_t)(((uint64_t)c->prdt[k].addr_hi << 32) | c->prdt[k].addr_lo);
			uint32_t n = c->prdt[k].dbc + 1;
			for (uint32_t b = 0; b < n; b++) {
				to[b] = pattern(lba + (at + b) / 4096, (at + b) % 4096);
			}
			at += n;
		}
		assert(at == len);
		usleep(100 + (lba % 200));      /* the flash */
		unsigned n = atomic_fetch_add(&served, 1);
		if (corrupt_slot >= 0 && (unsigned)corrupt_slot == slot) {
			((uint8_t *)(uintptr_t)(((uint64_t)c->prdt[0].addr_hi << 32) | c->prdt[0].addr_lo))[7] ^= 0xff;
		}
		if (hang_after >= 0 && n >= (unsigned)hang_after) {
			now_held--;
			continue;               /* this slot never completes; this thread is gone */
		}
		c->resp[0] = 0x21;
		c->resp[6] = 0;
		c->resp[7] = 0;
		u->dw2 = 0;
		if (fail_ocs_after >= 0 && n >= (unsigned)fail_ocs_after) {
			u->dw2 = 7;
		}
		if (set_full_after >= 0 && n == (unsigned)set_full_after) {
			c->resp[7] = 0x28;
		}
		now_held--;
		pthread_mutex_lock(&hw);
		pending &= ~(1u << slot);
		busy_tags &= ~(1u << slot);
		pthread_mutex_unlock(&hw);
	}
	return NULL;
}

/* slot 0 of the driver */
static int
ufs_read_blocks(uint64_t lba, uint32_t count)
{
	uint8_t *b = (uint8_t *)(su.dma + DMA_BOUNCE);
	for (uint32_t i = 0; i < count * 4096; i++) {
		b[i] = pattern(lba + i / 4096, i % 4096);
	}
	return 0;
}

/* time in nanoseconds, so the driver's conversions are the identity */
static uint64_t mach_absolute_time(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (uint64_t)t.tv_sec * NSEC_PER_SEC + (uint64_t)t.tv_nsec; }
static void nanoseconds_to_absolutetime(uint64_t ns, uint64_t *abs) { *abs = ns; }
static void absolutetime_to_nanoseconds(uint64_t abs, uint64_t *ns) { *ns = abs; }
static void delay(int us) { usleep((useconds_t)us); }
static void flush_dcache64(addr64_t a, unsigned l, int p) { (void)a; (void)l; (void)p; }
static bool ml_get_interrupts_enabled(void) { return true; }
static bool ml_at_interrupt_context(void) { return false; }
static int get_preemption_level(void) { return 0; }
static uint32_t boot_queue = 1;
static bool PE_parse_boot_argn(const char *n, void *o, int s) { (void)s; if (strcmp(n, "ufsqueue") == 0 && boot_queue != 1) { *(uint32_t *)o = boot_queue; return true; } return false; }
static int kmem_alloc_contig(void *m, vm_offset_t *a, size_t sz, unsigned long mask, ppnum_t mx, int b, int c, int d)
{
	(void)m; (void)mask; (void)mx; (void)b; (void)c; (void)d;
	*a = (vm_offset_t)aligned_alloc(4096, (sz + 4095) & ~4095ul);
	memset((void *)*a, 0, sz);
	return 0;
}
static ppnum_t pmap_find_phys(void *p, addr64_t va) { (void)p; return (ppnum_t)atop_64(va); }

/* wait/wake: a thread's sleep ends with a broadcast or after a short time, as the driver's timed sleeps do */
static pthread_mutex_t evm = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t evc = PTHREAD_COND_INITIALIZER;
static __thread int asserted;
static atomic_ulong wake_gen;
static __thread unsigned long seen_gen;
static int assert_wait(event_t e, int w) { (void)e; (void)w; asserted = 1; seen_gen = wake_gen; return THREAD_WAITING; }
static int assert_wait_deadline_with_leeway(event_t e, int w, int u, uint64_t dl, uint64_t lw) { (void)u; (void)dl; (void)lw; return assert_wait(e, w); }
static void thread_block(void *c)
{
	(void)c;
	struct timespec t;
	clock_gettime(CLOCK_REALTIME, &t);
	t.tv_nsec += 100000;
	if (t.tv_nsec >= 1000000000) { t.tv_sec++; t.tv_nsec -= 1000000000; }
	pthread_mutex_lock(&evm);
	if (wake_gen == seen_gen) {
		pthread_cond_timedwait(&evc, &evm, &t);
	}
	pthread_mutex_unlock(&evm);
	asserted = 0;
}
static void thread_wakeup_one(event_t e) { (void)e; pthread_mutex_lock(&evm); wake_gen++; pthread_cond_broadcast(&evc); pthread_mutex_unlock(&evm); }
static void thread_wakeup(event_t e) { (void)e; pthread_mutex_lock(&evm); wake_gen++; pthread_cond_broadcast(&evc); pthread_mutex_unlock(&evm); }
static void thread_deallocate(thread_t t) { (void)t; }
static int kernel_thread_start(void (*f)(void *, wait_result_t), void *a, thread_t *t)
{
	pthread_t p;
	*t = NULL;
	return pthread_create(&p, NULL, (void *(*)(void *))(void *)f, a);
}

static char printed[4096];
static pthread_mutex_t pm = PTHREAD_MUTEX_INITIALIZER;
#define printf(...) ( \
	pthread_mutex_lock(&pm), \
	snprintf(printed + strlen(printed), sizeof(printed) - strlen(printed), __VA_ARGS__), \
	pthread_mutex_unlock(&pm))

static LCK_GRP_DECLARE(sweet_ufs_grp, "sweet_ufs");
static LCK_MTX_DECLARE(sweet_ufs_lock, &sweet_ufs_grp);
#include "laurel_ufs_queue.h"
#undef printf

static atomic_uint async_done;
static void ufs_bp_io(buf_t bp) { (void)bp; async_done++; }

static int fails;
#define CHECK(c, ...) do { if (!(c)) { fails++; fprintf(stdout, "FAIL %d: ", __LINE__); fprintf(stdout, __VA_ARGS__); fprintf(stdout, "\n"); } } while (0)

static void
reset(void)
{
	static int threads;
	memset(&luq, 0, sizeof(luq));
	printed[0] = 0;
	fail_ocs_after = hang_after = set_full_after = corrupt_slot = -1;
	served = 0;
	peak_held = 0;
	pthread_mutex_lock(&hw);
	memset(regs, 0, sizeof(regs));
	pending = busy_tags = 0;
	regs[REG_CAP / 4] = scripted_nutrs - 1;
	regs[REG_HCS / 4] = HCS_UCRDY;
	pthread_mutex_unlock(&hw);
	su.dma = (vm_offset_t)aligned_alloc(4096, DMA_SIZE);
	memset((void *)su.dma, 0, DMA_SIZE);
	su.dma_pa = su.dma;
	su.first_block = 1000;
	su.nblocks = 100000;
	if (threads == 0) {
		for (; threads < 8; threads++) {
			pthread_t p;
			pthread_create(&p, NULL, host_thread, NULL);
		}
	}
}

struct reader { unsigned id, n; uint32_t bytes, skip; int bad; uint64_t ns; uint32_t fell_back; };

/* a reader as the driver's strategy: the queue, then slot 0 for what it did not do (here: counted) */
static void *
reader(void *arg)
{
	struct reader *r = arg;
	char *buf = malloc(r->bytes + 4096);
	struct fake_buf b;
	for (unsigned i = 0; i < r->n; i++) {
		uint64_t off = ((uint64_t)(r->id * 1000 + i * 37)) * 4096 + r->skip;
		uint32_t did = luq_read_range(off, buf, r->bytes, &b);
		if (did < r->bytes) {
			r->fell_back++;
		}
		for (uint32_t x = 0; x < did; x++) {
			uint64_t p = off + x;
			if ((uint8_t)buf[x] != pattern(su.first_block + p / 4096, (uint32_t)(p % 4096))) {
				r->bad++;
				break;
			}
		}
	}
	free(buf);
	return NULL;
}

static double
run(unsigned readers, unsigned n, uint32_t bytes, uint32_t skip, int *bad, uint32_t *fell)
{
	pthread_t t[16];
	struct reader r[16];
	uint64_t t0 = mach_absolute_time();
	for (unsigned i = 0; i < readers; i++) {
		r[i] = (struct reader){ .id = i, .n = n, .bytes = bytes, .skip = skip };
		pthread_create(&t[i], NULL, reader, &r[i]);
	}
	*bad = 0;
	*fell = 0;
	for (unsigned i = 0; i < readers; i++) {
		pthread_join(t[i], NULL);
		*bad += r[i].bad;
		*fell += r[i].fell_back;
	}
	return (double)(mach_absolute_time() - t0) / 1e9;
}

int
main(void)
{
	int bad;
	uint32_t fell;

	/* layout */
	CHECK(LUQ_DMA_SIZE < (8u << 20), "memory %u", LUQ_DMA_SIZE);
	CHECK(sizeof(struct utrd) == 32 && sizeof(struct ucd) == 1088, "descriptors %zu %zu", sizeof(struct utrd), sizeof(struct ucd));
	for (unsigned i = 0; i < LUQ_READ_SLOTS; i++) {
		CHECK(luq_hw(i) % 2 == 0 && luq_hw(i) >= 2 && luq_hw(i) < 16, "hw slot %u", luq_hw(i));
		/* each rung descriptor alone in a 64-byte cache line */
		CHECK(luq_hw(i) * 32 / 64 != (luq_hw(i) + 2) * 32 / 64, "line of slot %u", luq_hw(i));
	}

	/* start, one reader, then eight */
	reset();
	luq_start();
	CHECK(luq.on && luq.slots == 7, "queue on, 7 slots: %s", printed);
	CHECK(strstr(printed, "LAUREL UFS QUEUE: on: 7 read slots of 32") != NULL && strstr(printed, "gear 3") != NULL, "line: %s", printed);
	CHECK(doorbells_with_many >= 1, "self-check rings its slots together");
	double one = run(1, 200, 16384, 0, &bad, &fell);
	CHECK(bad == 0 && fell == 0, "1 reader: bad %d fell %u", bad, fell);
	peak_held = 0;
	double four = run(4, 200, 16384, 0, &bad, &fell);
	CHECK(bad == 0 && fell == 0, "4 readers: bad %d fell %u", bad, fell);
	unsigned held = peak_held;
	CHECK(held >= 3, "4 readers at once on the host: %u", held);
	double speedup = 4.0 * one / four;
	printf("ufsq-test (host only): 16 KiB reads, 1 reader %.2f s for 200, 4 readers %.2f s for 800: %.1f times the rate; at most %u at once\n", one, four, speedup, held);
	CHECK(speedup > 2.0, "4 readers did not scale: %.1f", speedup);
	CHECK(bad_slot == 0, "an odd slot was rung");
	CHECK(bad_tag == 0, "a task tag is not its slot");

	/* partial blocks and large reads */
	run(3, 30, 1000, 513, &bad, &fell);
	CHECK(bad == 0 && fell == 0, "unaligned: bad %d fell %u", bad, fell);
	run(2, 6, (1u << 20) + 4096, 512, &bad, &fell);
	CHECK(bad == 0 && fell == 0, "over one bounce: bad %d fell %u", bad, fell);

	/* more readers than slots: they wait for a slot */
	luq.waited = 0;
	run(16, 20, 4096, 0, &bad, &fell);
	CHECK(bad == 0 && fell == 0, "16 readers: bad %d fell %u", bad, fell);
	CHECK(luq.waited > 0 && luq.free_mask == (1u << 7) - 1 && luq.in_flight == 0, "slots back: waited %llu free %x in flight %u", (unsigned long long)luq.waited, luq.free_mask, luq.in_flight);

	/* read-ahead goes to the threads, the queue full means the caller does it */
	struct fake_buf bufs[LUQ_ASYNC_MAX + 8];
	async_done = 0;
	for (unsigned i = 0; i < 10; i++) {
		CHECK(luq_async_put(&bufs[i]), "put %u", i);
	}
	for (int w = 0; w < 200000 && async_done < 10; w++) {
		usleep(10);
		thread_wakeup_one((event_t)&luq.q_n);
	}
	CHECK(async_done == 10, "threads did %u of 10", async_done);

	/* TASK SET FULL: slot 0 for this read, the queue stays on */
	set_full_after = (int)served + 2;
	run(1, 10, 4096, 0, &bad, &fell);
	CHECK(bad == 0 && fell == 1 && luq.on, "device full: fell %u on %d", fell, luq.on);
	set_full_after = -1;

	/* an error: off, one line, the read goes to slot 0 */
	printed[0] = 0;
	fail_ocs_after = (int)served + 3;
	run(1, 10, 4096, 0, &bad, &fell);
	CHECK(bad == 0 && !luq.on && fell == 7, "error: on %d fell %u (3 reads before it, then all 7 through slot 0)", luq.on, fell);
	CHECK(strstr(printed, "LAUREL UFS QUEUE: off: a read failed") != NULL, "off line: %s", printed);
	CHECK(!luq_async_put(&bufs[0]), "no read-ahead with the queue off");
	struct fake_buf fb;
	char tmp[4096];
	CHECK(luq_read_range(0, tmp, 4096, &fb) == 0, "off: nothing through the queue");

	/* self-check: a slot gives other data */
	reset();
	corrupt_slot = 4;
	luq_start();
	CHECK(!luq.on && strstr(printed, "off: a read slot gave other data") != NULL, "wrong data: %s", printed);

	/* a timeout: off, and the slot that timed out is not used again */
	reset();
	luq_start();
	CHECK(luq.on, "on: %s", printed);
	luq.cmd_timeout = 20 * 1000 * 1000;
	printed[0] = 0;
	hang_after = (int)served;
	run(1, 1, 4096, 0, &bad, &fell);
	CHECK(!luq.on && fell == 1, "hang: on %d fell %u", luq.on, fell);
	CHECK(strstr(printed, "off: a read timed out") != NULL, "line: %s", printed);
	CHECK((luq.free_mask & 1) == 0, "the slot that timed out stays out: %x", luq.free_mask);
	hang_after = -1;

	/* review 2026-11-03: the device stalls under more readers than slots: all slots time out, no reader stays in the wait for a slot. A hang here ends the test by SIGALRM. */
	reset();
	luq_start();
	CHECK(luq.on, "on: %s", printed);
	luq.cmd_timeout = 20 * 1000 * 1000;
	hang_after = (int)served;
	alarm(30);
	run(12, 2, 4096, 0, &bad, &fell);
	alarm(0);
	CHECK(!luq.on && luq.in_flight == 0 && fell == 24, "stall: on %d in flight %u fell %u", luq.on, luq.in_flight, fell);
	hang_after = -1;

	/* few host slots; the kill switch */
	scripted_nutrs = 4;
	reset();
	luq_start();
	CHECK(!luq.on && strstr(printed, "off: the host has 4 slots") != NULL, "%s", printed);
	scripted_nutrs = 32;
	boot_queue = 0;
	reset();
	luq_start();
	CHECK(!luq.on && strstr(printed, "off: ufsqueue=0") != NULL, "%s", printed);

	if (fails) {
		fprintf(stdout, "ufsq-test: FAILED: %d\n", fails);
		return 1;
	}
	fprintf(stdout, "ufsq-test: PASS\n");
	fflush(stdout);
	_exit(0);
}
