/*
 * Host test of the laurel GPU pool bookkeeping (patch 2156, iokit/Kernel/arm/laurel_gpu_pool_core.h).
 * Run: scripts/laurel/gpu-pool-test.sh (takes the header from the patch and the GPU_POOL_* sizes from 2150).
 *
 *   1. replay: the free range that the 2026-11-01 06:50:38 panic registers show (x8 = &pool_free[6]: start
 *      pool + 0x3f40000, size 0x160000), then an allocation of 0x140000: the old allocator (2150, copied below)
 *      gives a buffer across the 64 MiB chunk boundary; lgp_alloc passes the range over and gives one inside a chunk;
 *   2. the old allocator without a lock: (a) the torn read step by step (a free on one CPU between the size and the
 *      start loads of range_alloc on another) makes the panic's range and buffer; (b) 4 threads at once: how soon
 *      a bad buffer or range shows up (information only, it is a race);
 *   3. lgp_* under one mutex, 4 threads, random sizes: no buffer crosses a chunk or overlaps another, nothing
 *      refused, all memory back at the end, one free range per chunk again;
 *   4. bad frees: twice, wrong size, unaligned, outside, guard unit, across a chunk, inside a buffer: each refused
 *      and counted, the free list unchanged.
 */
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "gpu_pool_defs.h"              /* GPU_POOL_UNIT, GPU_POOL_CHUNK, GPU_POOL_MAX from patch 2150 */
#include "laurel_gpu_pool_core.h"

#define BASE    0xC0000000ull           /* LAUREL GPU: on: ... pool 0xc0000000+0x20000000 */
#define SIZE    0x20000000ull
#define UNITS   (SIZE / GPU_POOL_UNIT)
#define CHUNKS  (SIZE / GPU_POOL_CHUNK)

static int fails;
#define CHECK(c) do { if (!(c)) { printf("FAIL line %d: %s\n", __LINE__, #c); fails++; } } while (0)

static bool
crosses(uint64_t pa, uint64_t size)
{
	uint64_t off = pa - BASE;
	return (off & (GPU_POOL_CHUNK - 1)) + size > GPU_POOL_CHUNK - GPU_POOL_UNIT;
}

/* ---------------------------------------------------------------- the old allocator (2150), as it was */

static struct { uint64_t start, size; } old_free[2048];
static unsigned old_count;

static void
range_free(void *table, unsigned *count, unsigned max, uint64_t address, uint64_t size)
{
	struct r { uint64_t start, size; } *f = (struct r *)table;
	unsigned at;

	for (at = 0; at < *count && f[at].start < address; at++) {
	}
	if (at > 0 && f[at - 1].start + f[at - 1].size == address) {
		f[at - 1].size += size;
		if (at < *count && address + size == f[at].start) {
			f[at - 1].size += f[at].size;
			memmove(&f[at], &f[at + 1], (--*count - at) * sizeof(f[0]));
		}
	} else if (at < *count && address + size == f[at].start) {
		f[at].start = address;
		f[at].size += size;
	} else if (*count < max) {
		memmove(&f[at + 1], &f[at], (*count - at) * sizeof(f[0]));
		(*count)++;
		f[at].start = address;
		f[at].size = size;
	}
}

static uint64_t
range_alloc(void *table, unsigned *count, uint64_t size)
{
	struct r { uint64_t start, size; } *f = (struct r *)table;

	for (unsigned i = 0; i < *count; i++) {
		if (f[i].size >= size) {
			uint64_t address = f[i].start;
			f[i].start += size;
			f[i].size -= size;
			if (f[i].size == 0) {
				memmove(&f[i], &f[i + 1], (--*count - i) * sizeof(f[0]));
			}
			return address;
		}
	}
	return 0;
}

static void
old_seed(void)
{
	old_count = 0;
	for (uint64_t c = 0; c < CHUNKS; c++) {
		range_free(old_free, &old_count, 2048, BASE + c * GPU_POOL_CHUNK, GPU_POOL_CHUNK - GPU_POOL_UNIT);
	}
}

/* ---------------------------------------------------------------- workload */

/* sizes as on the phone: Mesa's GEM buffers (64 KiB .. 6 MiB, 1.25 MiB in the panic), backboardd screens */
static uint64_t
pick_size(unsigned *seed)
{
	static const uint64_t sizes[] = { 0x10000, 0x20000, 0x40000, 0x80000, 0x140000, 0x140000, 0x200000, 0x600000,
		                          0x4d0000 /* 720x1560 BGRA, bpr 3072, + 64 guard rows */ };
	return sizes[rand_r(seed) % (sizeof(sizes) / sizeof(sizes[0]))];
}

#define HELD 24

/* 2: the old allocator, no lock */
static volatile int old_seen;           /* 1: a buffer across a chunk; 2: two buffers on one unit; 3: a bad free range */
static volatile uint64_t old_seen_pa, old_seen_size;
static volatile long old_ops;
static int old_owner[UNITS];

static void
old_seen_at(int what, uint64_t pa, uint64_t size)
{
	if (__atomic_exchange_n(&old_seen, what, __ATOMIC_SEQ_CST) == 0) {
		old_seen_pa = pa;
		old_seen_size = size;
	}
}

static void *
old_worker(void *arg)
{
	int me = (int)(uintptr_t)arg;
	unsigned seed = (unsigned)me;
	uint64_t pa[HELD] = { 0 }, sz[HELD] = { 0 };

	for (long n = 0; n < 4000000 && !old_seen; n++) {
		unsigned i = (unsigned)rand_r(&seed) % HELD;
		if (pa[i] != 0) {
			for (uint64_t u = (pa[i] - BASE) / GPU_POOL_UNIT; u < (pa[i] + sz[i] - BASE) / GPU_POOL_UNIT && u < UNITS; u++) {
				__atomic_compare_exchange_n(&old_owner[u], &me, 0, false, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
				me = (int)(uintptr_t)arg;
			}
			range_free(old_free, &old_count, 2048, pa[i], sz[i]);
			pa[i] = 0;
		} else {
			sz[i] = pick_size(&seed);
			pa[i] = range_alloc(old_free, &old_count, sz[i]);
			if (pa[i] != 0 && (pa[i] < BASE || pa[i] - BASE >= SIZE || crosses(pa[i], sz[i]))) {
				old_seen_at(1, pa[i], sz[i]);
			} else if (pa[i] != 0) {
				for (uint64_t u = (pa[i] - BASE) / GPU_POOL_UNIT; u < (pa[i] + sz[i] - BASE) / GPU_POOL_UNIT; u++) {
					if (__atomic_exchange_n(&old_owner[u], me, __ATOMIC_SEQ_CST) != 0) {
						old_seen_at(2, pa[i], sz[i]);
					}
				}
			}
		}
		__atomic_add_fetch(&old_ops, 1, __ATOMIC_RELAXED);
	}
	return NULL;
}

/*
 * 2a: the torn read, step by step. topaz_gpu_pool_alloc's loop (disassembly of the panicked kernel) loads
 * f[i].size (ldr x14, [x8, #8]), compares, and only then loads f[i].start (ldr x0, [x8]) and stores both (stp).
 * A range_free on another CPU between the two loads that inserts a range in front of i shifts the table: f[i]
 * is then the range before. The store gives that range's start with the size of the one after it.
 */
static void
old_torn_replay(void)
{
	const uint64_t want = 0x140000;
	unsigned i;

	old_count = 0;
	range_free(old_free, &old_count, 2048, BASE + 0x3e00000, 0x20000);                    /* W: chunk 0, 128 KiB left */
	range_free(old_free, &old_count, 2048, BASE + GPU_POOL_CHUNK, GPU_POOL_CHUNK - GPU_POOL_UNIT);   /* X: chunk 1, all free */
	/* CPU A: range_alloc(0x140000): W is too small, X fits: i = 1, size loaded */
	for (i = 0; i < old_count && old_free[i].size < want; i++) {
	}
	uint64_t size_seen = old_free[i].size;
	/* CPU B: a buffer at pool + 0x100000 comes back (SweetSurface::free on the presenter thread): inserted at 0 */
	range_free(old_free, &old_count, 2048, BASE + 0x100000, 0x10000);
	/* CPU A goes on: start from f[1] (now W), the size it loaded before (X's) */
	uint64_t address = old_free[i].start;
	old_free[i].start = address + want;
	old_free[i].size = size_seen - want;
	printf("2a torn read (CPU A in range_alloc, CPU B in range_free): A gets pool+%#llx+%#llx (W had 0x20000 free);\n"
	    "   the table keeps pool+%#llx size %#llx: across the chunk end pool+0x4000000\n",
	    (unsigned long long)(address - BASE), (unsigned long long)want,
	    (unsigned long long)(old_free[i].start - BASE), (unsigned long long)old_free[i].size);
	CHECK(address == BASE + 0x3e00000 && old_free[i].start == BASE + 0x3f40000 && crosses(old_free[i].start, old_free[i].size));
	uint64_t next = range_alloc(old_free, &old_count, want);
	printf("   the next range_alloc(0x140000) gives pool+%#llx..pool+%#llx: the panic's buffer\n",
	    (unsigned long long)(next - BASE), (unsigned long long)(next - BASE + want));
	CHECK(next == BASE + 0x3f40000 && crosses(next, want));
}

/* 3: the new core under one mutex */
static struct lgp pool;
static pthread_mutex_t pool_lock = PTHREAD_MUTEX_INITIALIZER;
static int owner[UNITS];                /* which thread holds the unit (0: none), checked under the lock */
static volatile int new_bad;

static void *
new_worker(void *arg)
{
	int me = (int)(uintptr_t)arg;
	unsigned seed = (unsigned)me * 7919u;
	uint64_t pa[HELD] = { 0 }, sz[HELD] = { 0 };

	for (long n = 0; n < 300000 + HELD; n++) {
		bool last = n >= 300000;        /* the last HELD steps: give back what is still held */
		unsigned i = last ? (unsigned)(n - 300000) : (unsigned)rand_r(&seed) % HELD;
		pthread_mutex_lock(&pool_lock);
		if (pa[i] != 0) {
			for (uint64_t u = (pa[i] - BASE) / GPU_POOL_UNIT; u < (pa[i] + sz[i] - BASE) / GPU_POOL_UNIT; u++) {
				owner[u] = 0;
			}
			if (lgp_free(&pool, pa[i], sz[i]) != NULL) {
				new_bad++;
			}
			pa[i] = 0;
		} else if (!last) {
			sz[i] = pick_size(&seed);
			pa[i] = lgp_alloc(&pool, sz[i]);
			if (pa[i] != 0) {
				if (crosses(pa[i], sz[i]) || pa[i] < BASE || pa[i] + sz[i] > BASE + SIZE) {
					new_bad++;
				} else {
					for (uint64_t u = (pa[i] - BASE) / GPU_POOL_UNIT; u < (pa[i] + sz[i] - BASE) / GPU_POOL_UNIT; u++) {
						if (owner[u] != 0) {
							new_bad++;      /* two buffers on one unit */
						}
						owner[u] = me;
					}
				}
			}
		}
		pthread_mutex_unlock(&pool_lock);
	}
	return NULL;
}

static bool
pool_whole(const struct lgp *p)
{
	if (p->count != CHUNKS || p->free_bytes != CHUNKS * (GPU_POOL_CHUNK - GPU_POOL_UNIT)) {
		return false;
	}
	for (unsigned c = 0; c < CHUNKS; c++) {
		if (p->range[c].start != BASE + c * GPU_POOL_CHUNK || p->range[c].size != GPU_POOL_CHUNK - GPU_POOL_UNIT) {
			return false;
		}
	}
	return true;
}

/* 4: a bad free must change nothing but the refused count */
static void
refused(struct lgp *p, uint64_t pa, uint64_t size, const char *what)
{
	static struct lgp before;
	const char *why;

	memcpy(&before, p, sizeof(before));
	why = lgp_free(p, pa, size);
	CHECK(why != NULL);
	CHECK(p->refused == before.refused + 1);
	before.refused = p->refused;
	CHECK(memcmp(&before, p, sizeof(before)) == 0);
	printf("  bad free %-26s %#llx+%#llx: refused: %s\n", what, (unsigned long long)pa, (unsigned long long)size,
	    why ? why : "(taken!)");
}

/* laurel 2974: the 1 GiB pool at the bottom of the identity window, and where lgp_place puts it */
static void
big_pool(void)
{
	static struct lgp p;
	static uint64_t got[GPU_POOL_MAX / GPU_POOL_UNIT];
	const uint64_t base = 0x80000000ull, whole = GPU_POOL_MAX, chunks = whole / GPU_POOL_CHUNK;
	const uint64_t banks[2][2] = { { 0x80000000ull, 0x40000000ull }, { 0xC0000000ull, 0x100000000ull } };
	const uint64_t res[2][2] = { { 0x80000000ull, 0x40000000ull }, { 0xC0000000ull, 0x01000000ull } };
	const uint64_t kbase = 0xC1004000ull, kend = 0x1B5004000ull, mb = 0xC0000000ull, me = 0xC1000000ull;
	uint64_t b, s, n = 0;

	lgp_init(&p, base, whole);
	CHECK(p.count == chunks && p.free_bytes == chunks * (GPU_POOL_CHUNK - GPU_POOL_UNIT));
	/* every unit of every chunk but the guard, once; nothing above the pool, none across a chunk */
	for (;;) {
		uint64_t pa = lgp_alloc(&p, GPU_POOL_UNIT);
		if (pa == 0) {
			break;
		}
		CHECK(pa >= base && pa + GPU_POOL_UNIT <= base + whole && (pa & (GPU_POOL_CHUNK - 1)) != GPU_POOL_CHUNK - GPU_POOL_UNIT);
		got[n++] = pa;
	}
	CHECK(n == chunks * (GPU_POOL_CHUNK / GPU_POOL_UNIT - 1) && p.free_bytes == 0 && p.count == 0);
	CHECK(lgp_alloc(&p, GPU_POOL_UNIT) == 0);       /* empty: 0, the caller's kept buffers go next (RedwoodGPU redwood_gpu_pool_take) */
	/* every other unit back: more ranges than the table holds: the rest is lost and counted, nothing else breaks */
	for (uint64_t i = 0; i < n; i += 2) {
		CHECK(lgp_free(&p, got[i], GPU_POOL_UNIT) == NULL);
	}
	CHECK(p.count == LGP_RANGES && p.lost != 0 && p.refused == 0);
	printf("4 big pool: %llu MiB at %#llx: %llu units, %u of them lost when free ranges pass %u\n", (unsigned long long)(whole >> 20),
	    (unsigned long long)base, (unsigned long long)n, p.lost, LGP_RANGES);
	/* the merge rule still holds across all 16 chunks */
	lgp_init(&p, base, whole);
	for (uint64_t c = 0; c < chunks; c++) {
		uint64_t pa = lgp_alloc(&p, GPU_POOL_CHUNK - GPU_POOL_UNIT);
		CHECK(pa == base + c * GPU_POOL_CHUNK);
	}
	for (uint64_t c = chunks; c-- > 0;) {
		CHECK(lgp_free(&p, base + c * GPU_POOL_CHUNK, GPU_POOL_CHUNK - GPU_POOL_UNIT) == NULL);
	}
	CHECK(p.count == chunks);

	CHECK(lgp_place(res, 2, banks, 2, kbase, kend, mb, me, 0x08000000ull, GPU_POOL_MAX, &b, &s) && b == base && s == whole);
	/* kill switch: 512 MiB, the same base */
	CHECK(lgp_place(res, 2, banks, 2, kbase, kend, mb, me, 0x08000000ull, 0x20000000ull, &b, &s) && b == base && s == 0x20000000ull);
	/* kernel RAM over the top of the range: cut in front of it */
	CHECK(lgp_place(res, 2, banks, 2, 0xB1004000ull, kend, mb, me, 0x08000000ull, GPU_POOL_MAX, &b, &s) && b == base && s == 0x30000000ull);
	/* kernel RAM at the bottom: none (midmem) */
	CHECK(!lgp_place(res, 2, banks, 2, 0x81004000ull, 0xB1004000ull, mb, me, 0x08000000ull, GPU_POOL_MAX, &b, &s));
	/* the map of before: the old ADT still gives 512 MiB */
	const uint64_t old[2][2] = { { 0xC0000000ull, 0x20000000ull }, { 0xE0000000ull, 0x01000000ull } };
	CHECK(lgp_place(old, 2, banks, 2, 0xE1004000ull, 0x1AD004000ull, 0xE0000000ull, 0xE1000000ull, 0x08000000ull, GPU_POOL_MAX, &b, &s) && b == 0xC0000000ull && s == 0x20000000ull);
	/* a range across two banks: the modem pool cuts it to 768 MiB; with no pool at the bank edge it is refused */
	const uint64_t across[1][2] = { { 0x90000000ull, 0x40000000ull } };
	CHECK(lgp_place(across, 1, banks, 2, 0xE1004000ull, 0x1AD004000ull, mb, me, 0x08000000ull, GPU_POOL_MAX, &b, &s) && b == 0x90000000ull && s == 0x30000000ull);
	CHECK(!lgp_place(across, 1, banks, 2, 0xE1004000ull, 0x1AD004000ull, 0xE0000000ull, 0xE1000000ull, 0x08000000ull, GPU_POOL_MAX, &b, &s));
	printf("  lgp_place: 1 GiB at 0x80000000; kill switch 512 MiB; cut in front of kernel RAM; old ADT 512 MiB at 0xc0000000\n");
}

int
main(void)
{
	pthread_t t[4];
	struct timespec t0, t1;

	/* 1: the panic's free range */
	old_count = 1;
	old_free[0].start = BASE + 0x3f40000;
	old_free[0].size = 0x160000;
	uint64_t got = range_alloc(old_free, &old_count, 0x140000);
	printf("1 replay: free range pool+0x3f40000 size 0x160000 (panic x8/x14), allocation 0x140000:\n");
	printf("  old allocator: pool+%#llx, end pool+%#llx: %s\n", (unsigned long long)(got - BASE),
	    (unsigned long long)(got - BASE + 0x140000), crosses(got, 0x140000) ? "ACROSS the chunk boundary 0x4000000" : "inside");
	CHECK(got == BASE + 0x3f40000 && crosses(got, 0x140000));
	lgp_init(&pool, BASE, SIZE);
	pool.range[0].start = BASE + 0x3f40000;  /* the bad range in front of the good ones */
	pool.range[0].size = 0x160000;
	got = lgp_alloc(&pool, 0x140000);
	printf("  lgp_alloc:     pool+%#llx (%u range passed over): %s\n", (unsigned long long)(got - BASE), pool.skipped,
	    got != 0 && !crosses(got, 0x140000) ? "inside one chunk" : "BAD");
	CHECK(got != 0 && !crosses(got, 0x140000) && pool.skipped == 1);

	/* 2: the old allocator without a lock */
	old_torn_replay();
	old_seed();
	clock_gettime(CLOCK_MONOTONIC, &t0);
	for (int i = 0; i < 4; i++) {
		pthread_create(&t[i], NULL, old_worker, (void *)(uintptr_t)(i + 1));
	}
	for (int i = 0; i < 4; i++) {
		pthread_join(t[i], NULL);
	}
	clock_gettime(CLOCK_MONOTONIC, &t1);
	for (unsigned i = 0; i < old_count && !old_seen; i++) {
		if (old_free[i].start < BASE || crosses(old_free[i].start, old_free[i].size) ||
		    (i > 0 && old_free[i - 1].start + old_free[i - 1].size > old_free[i].start)) {
			old_seen_at(3, old_free[i].start, old_free[i].size);
		}
	}
	printf("2b old allocator, 4 threads, no lock: %ld operations in %.2f s: %s", old_ops,
	    (double)(t1.tv_sec - t0.tv_sec) + (double)(t1.tv_nsec - t0.tv_nsec) / 1e9,
	    old_seen == 1 ? "a buffer across a chunk" : old_seen == 2 ? "two buffers on one unit" :
	    old_seen == 3 ? "a free range across a chunk or over another" : "nothing seen (a race: no proof either way)");
	if (old_seen) {
		printf(" (%#llx+%#llx)", (unsigned long long)old_seen_pa, (unsigned long long)old_seen_size);
	}
	printf("\n");

	/* 3: lgp under one mutex */
	lgp_init(&pool, BASE, SIZE);
	CHECK(pool_whole(&pool));
	for (int i = 0; i < 4; i++) {
		pthread_create(&t[i], NULL, new_worker, (void *)(uintptr_t)(i + 1));
	}
	for (int i = 0; i < 4; i++) {
		pthread_join(t[i], NULL);
	}
	printf("3 lgp, 4 threads, one mutex, 1200000 operations: %d bad, %u refused, %u lost, %u passed over; %s\n", new_bad,
	    pool.refused, pool.lost, pool.skipped, pool_whole(&pool) ? "all back, one range per chunk" : "NOT all back");
	CHECK(new_bad == 0 && pool.refused == 0 && pool.lost == 0 && pool.skipped == 0 && pool_whole(&pool));

	/* 4: bad frees */
	printf("4 bad frees:\n");
	lgp_init(&pool, BASE, SIZE);
	uint64_t a = lgp_alloc(&pool, 0x140000), b = lgp_alloc(&pool, 0x4d0000);
	CHECK(a == BASE && b == BASE + 0x140000);
	refused(&pool, a, 0x130000, "smaller than given");
	refused(&pool, a, 0x150000, "larger than given");
	refused(&pool, a + 0x10000, 0x130000, "inside a buffer");
	refused(&pool, a + 0x1000, 0x140000, "unaligned");
	refused(&pool, BASE - 0x140000, 0x140000, "outside (below)");
	refused(&pool, BASE + SIZE, 0x10000, "outside (above)");
	refused(&pool, 0x1ad004000ull, 0x10000, "kernel RAM");
	refused(&pool, BASE + GPU_POOL_CHUNK - GPU_POOL_UNIT, GPU_POOL_UNIT, "the guard unit");
	refused(&pool, BASE + GPU_POOL_CHUNK - 0xC0000, 0x140000, "across a chunk (the panic)");
	refused(&pool, BASE + 0x1000000, 0x10000, "free memory");
	CHECK(lgp_free(&pool, a, 0x140000) == NULL);
	refused(&pool, a, 0x140000, "twice");
	CHECK(lgp_free(&pool, b, 0x4d0000) == NULL);
	CHECK(pool_whole(&pool) && pool.refused == 11);

	/* the free list only merges inside a chunk: fill chunk 0 to its guard, give it back in pieces */
	lgp_init(&pool, BASE, SIZE);
	uint64_t piece[1023];
	for (unsigned i = 0; i < 1023; i++) {
		piece[i] = lgp_alloc(&pool, GPU_POOL_UNIT);
		CHECK(piece[i] == BASE + i * GPU_POOL_UNIT);
	}
	CHECK(lgp_alloc(&pool, GPU_POOL_UNIT) == BASE + GPU_POOL_CHUNK);   /* chunk 0 full: the guard is never given */
	CHECK(lgp_free(&pool, BASE + GPU_POOL_CHUNK, GPU_POOL_UNIT) == NULL);
	for (unsigned i = 0; i < 1023; i++) {
		CHECK(lgp_free(&pool, piece[(i * 389) % 1023], GPU_POOL_UNIT) == NULL);
	}
	CHECK(pool_whole(&pool) && pool.refused == 0);

	big_pool();
	printf("%s\n", fails ? "gpu-pool-test: FAILED" : "gpu-pool-test: ok");
	return fails != 0;
}
