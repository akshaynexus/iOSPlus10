/*
 * Host test of RedwoodGPU's rules: exactly the headers the kernel builds (patches 2975-2978), the kept and take code on the real pool bookkeeping (2156 + 2974).
 * Run: scripts/laurel/gpu-push-test.sh
 *   1. LAUREL GPU TIME: request numbers, order, whole entries, the kernel line stays under 255 bytes;
 *   2. the push rule: truth table, the old rule with the kill switch, a simulated cache: no dirty line at any submission;
 *   3. keep(): when it refuses, what it evicts, the byte limit;
 *   4. the take: too big and fragments lose nothing, only what the request needs, the window server's last; every plan against all subsets; random runs;
 *   5. a pool buffer with a user mapping: its bytes do not go back until the mapping has gone;
 *   6. table runs: every entry cleaned once, before the end; the surface list against a plain model.
 */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "gpu_pool_defs.h"
#include "laurel_gpu_pool_core.h"
#include "laurel_gpu_kept_core.h"
#include "laurel_gpu_time_core.h"
#include "laurel_gpu_push_core.h"
#include "laurel_gpu_table_core.h"

#define BASE    0x80000000ull
#define SIZE    0x40000000ull
#define MIB     (1ull << 20)
#define FLOOR   (64 * MIB)

static int fails;
#define CHECK(c) do { if (!(c)) { printf("FAIL line %d: %s\n", __LINE__, #c); fails++; } } while (0)

/* ---------------------------------------------------------------- 1 */
static void
test_time(void)
{
	uint64_t us[LGT_SLOTS];
	uint32_t calls[LGT_SLOTS];
	char s[LGT_TEXT], line[600];
	static const struct { uint32_t sel; const char *name; } map[] = {
		{0x09, "close"}, {0x40, "getparam"}, {0x41, "setparam"}, {0x42, "new"}, {0x43, "info"}, {0x44, "prep"}, {0x45, "fini"}, {0x46, "submit"},
		{0x47, "fence"}, {0x48, "madvise"}, {0x49, "userptr"}, {0x4a, "qnew"}, {0x4b, "qclose"}, {0x4c, "qquery"}, {0x7b, "who"}, {0x7c, "plane"},
		{0x7d, "drawn"}, {0x7e, "surface"}, {0x7f, "show"}, {0x1234, "other"}, {0x00, "other"}, {0x4d, "other"}, {0x7a, "other"}, {0x80, "other"},
	};

	for (unsigned i = 0; i < sizeof(map) / sizeof(map[0]); i++) {
		CHECK(lgt_slot(map[i].sel) < LGT_SLOTS);
		CHECK(strcmp(lgt_names[lgt_slot(map[i].sel)], map[i].name) == 0);
	}
	memset(us, 0, sizeof(us));
	memset(calls, 0, sizeof(calls));
	CHECK(lgt_text(s, sizeof(s), us, calls) == 0 && s[0] == '\0');
	calls[8] = 7; us[8] = 4200000;
	calls[3] = 683; us[3] = 950000;
	calls[0] = 1; us[0] = 10;
	CHECK(lgt_text(s, sizeof(s), us, calls) == 3);
	CHECK(strcmp(s, "fence 7/4200, new 683/950, close 1/0") == 0);
	/* the worst: all slots used, all numbers at their largest */
	for (unsigned i = 0; i < LGT_SLOTS; i++) {
		calls[i] = 4294967295u;
		us[i] = 18446744073709551615ull - i;
	}
	unsigned n = lgt_text(s, sizeof(s), us, calls);

	CHECK(n >= 1 && strlen(s) < LGT_TEXT);
	CHECK(s[strlen(s) - 1] != ',');
	/* realistic worst of one 5 s window: every slot up to 6 digits of calls and 5 digits of ms */
	for (unsigned i = 0; i < LGT_SLOTS; i++) {
		calls[i] = 999999;
		us[i] = 99999000 - i;
	}
	n = lgt_text(s, sizeof(s), us, calls);
	CHECK(n >= 4);
	snprintf(line, sizeof(line), "RedwoodGPU: a submission: %llu us before the lock, %llu us with it; the window server: %u requests, %llu us here in all; LAUREL GPU TIME: %s\n",
	    99999999ull, 99999999ull, 99999999u, 99999999ull, s);
	CHECK(strlen(line) <= 255);
	/* the line 2977 made longer */
	snprintf(line, sizeof(line), "RedwoodGPU: %u waits of %llu us, %u over before they began; %u IOSurfaces taken as buffers in %llu us each; "
	    "%u buffers, %llu MB; %u pushes, %u passed over; push us host %llu, surface %llu, own %llu\n",
	    999999u, 9999999ull, 999999u, 999999u, 999999ull, 8192u, 9999ull, 999999u, 999999u, 9999999ull, 9999999ull, 9999999ull);
	CHECK(strlen(line) <= 255);
}

/* ---------------------------------------------------------------- 2 */
/* the rule of patch 2158 + 2160's scan, as it was */
static enum lgf_what
old_rule(const struct lgf_own *b)
{
	if (!b->seen || !b->gpu_cached) {
		return LGF_SKIP;
	}
	if (b->seed_rule && b->same_place) {
		return LGF_CLEAN;
	}
	return LGF_PUSH;
}

static void
test_push_table(void)
{
	unsigned pushes = 0;

	for (unsigned bits = 0; bits < 128; bits++) {
		struct lgf_own b;
		bool after;
		enum lgf_what what;

		b.seed_rule = bits & 1;
		b.gpu_cached = bits & 2;
		b.seen = bits & 4;
		b.same_place = bits & 8;
		b.dirty = bits & 16;
		b.mapped_now = bits & 32;
		b.wc_now = bits & 64;
		b.rule_on = false;
		what = lgf_own_buffer(&b, &after);
		CHECK(what == old_rule(&b));
		CHECK(after == b.dirty);
		b.rule_on = true;
		what = lgf_own_buffer(&b, &after);
		/* the safety rule: cached memory the CPU may have written always goes out */
		if (b.gpu_cached && !(b.same_place && b.seed_rule) && !b.wc_now && (b.dirty || b.mapped_now)) {
			CHECK(what == LGF_PUSH);
			pushes++;
		} else {
			CHECK(what != LGF_PUSH);
		}
		/* a mapped cached buffer never comes out as clean */
		if (what == LGF_PUSH) {
			CHECK(after == b.mapped_now);
		}
	}
	CHECK(pushes != 0);

	unsigned attr[3] = { 0x6, 0x6, 0x6 };

	CHECK(lgf_all_pages_wc(attr, 3, LGF_WIMG_WCOMB, LGF_WIMG_MASK));
	attr[2] = 0;
	CHECK(!lgf_all_pages_wc(attr, 3, LGF_WIMG_WCOMB, LGF_WIMG_MASK));
	attr[2] = 0x106;                        /* other bits of the pmap's: only the mask counts */
	CHECK(lgf_all_pages_wc(attr, 3, LGF_WIMG_WCOMB, LGF_WIMG_MASK));
	CHECK(!lgf_all_pages_wc(attr, 0, LGF_WIMG_WCOMB, LGF_WIMG_MASK));
}

/*
 * A cached scattered buffer in a model of the cache. What the kernel does on each path is written as the kernel does it. line_dirty: the CPU wrote and it has not gone out: if it is set
 * at a submission after the rule ran, the GPU reads old bytes and a later eviction writes over what it drew: the failure of this test.
 */
static void
test_push_model(void)
{
	unsigned skipped = 0;

	srand(2977);
	for (unsigned run = 0; run < 2000; run++) {
		bool dirty = false, line_dirty = false, seen = false;
		int maps = 0;
		bool in_kept = false;

		for (unsigned step = 0; step < 200; step++) {
			switch (rand() % 6) {
			case 0:                 /* clientMemoryForType for a map */
				if (!in_kept) {
					seen = dirty = true;
					maps++;
				}
				break;
			case 1:                 /* a CPU write: only through a live map */
				if (maps > 0) {
					line_dirty = true;
				}
				break;
			case 2:                 /* IOConnectUnmapMemory64: goes through clientMemoryForType first */
				if (maps > 0 && !in_kept) {
					seen = dirty = true;
					maps--;
				}
				break;
			case 3:                 /* GEM close: kept, dirty goes with it. A map may stay (a client that does not unmap): it can still write */
				in_kept = true;
				break;
			case 4:                 /* given again: bzero(b) and the kept flags; seen starts again */
				if (in_kept) {
					in_kept = false;
					seen = false;
				}
				break;
			default: {              /* a submission that names it */
				struct lgf_own b = { true, true, true, seen, false, dirty, maps > 0, false };
				bool after;

				if (!in_kept) {
					enum lgf_what what = lgf_own_buffer(&b, &after);

					dirty = after;
					if (what == LGF_PUSH) {
						line_dirty = false;
					} else {
						skipped++;
					}
					CHECK(!line_dirty);
					/* the old rule loses this after given-again with a live map: that is why mapped_now, not seen */
				}
				break;
			}
			}
		}
	}
	CHECK(skipped != 0);                    /* (the rule does skip) */
}

/* ---------------------------------------------------------------- 3 */
static void
test_keep(void)
{
	struct lgk_slot s[48];
	unsigned evict[48], n;
	const uint64_t most = 160 * MIB, from = 256 << 10;
	int place;

	CHECK(lgk_may_keep(true, MIB, from, most / 4, true, true, false, true));
	CHECK(!lgk_may_keep(false, MIB, from, most / 4, true, true, false, true));              /* gpu_keep=0 */
	CHECK(!lgk_may_keep(true, from - 1, from, most / 4, true, true, false, true));          /* too small */
	CHECK(!lgk_may_keep(true, most / 4 + 1, from, most / 4, true, true, false, true));      /* too large */
	CHECK(!lgk_may_keep(true, MIB, from, most / 4, false, true, false, true));              /* not ours */
	CHECK(!lgk_may_keep(true, MIB, from, most / 4, true, true, false, false));              /* 2974: a short pool gets it back */
	CHECK(lgk_may_keep(true, MIB, from, most / 4, true, false, false, false));              /* (scattered: the pool does not matter) */
	CHECK(lgk_may_keep(true, MIB, from, most / 4, true, true, true, false));                /* (midmem) */

	memset(s, 0, sizeof(s));
	place = lgk_keep_pick(s, 48, 0, MIB, most, evict, &n);
	CHECK(place == 0 && n == 0);
	/* all places used: the oldest makes way */
	for (unsigned i = 0; i < 48; i++) {
		s[i].used = true;
		s[i].size = MIB;
		s[i].since = 1000 - i;
	}
	place = lgk_keep_pick(s, 48, 48 * MIB, MIB, most, evict, &n);
	CHECK(n == 1 && evict[0] == 47 && place == 47);
	/* the byte limit: as many of the oldest as it takes, no more */
	for (unsigned i = 0; i < 4; i++) {
		s[i].size = 39 * MIB;
		s[i].since = 10 + i;
	}
	for (unsigned i = 4; i < 48; i++) {
		s[i].used = false;
	}
	place = lgk_keep_pick(s, 48, 156 * MIB, 40 * MIB, most, evict, &n);
	CHECK(n == 1 && evict[0] == 0 && place == 0);
	CHECK(156 - 39 + 40 <= 160);
	place = lgk_keep_pick(s, 48, 156 * MIB, 4 * MIB, most, evict, &n);
	CHECK(n == 0 && place == 4);
	place = lgk_keep_pick(s, 48, 156 * MIB, 80 * MIB, most, evict, &n);     /* needs 76: two of 39 */
	CHECK(n == 2 && evict[0] == 0 && evict[1] == 1 && place == 0);
}

/* ---------------------------------------------------------------- 4: a pool and clients, the kernel's ops */
#define CLIENTS 4
#define KEPT    48
#define WS      0                       /* client 0 is the window server */
static struct lgp pool;
static struct lgk_item items[LGK_ITEMS];
static struct lgk_seg segs[LGK_SEGS];
static struct {
	uint64_t pa, size, since;
	bool used, mapped;
} kept[CLIENTS][KEPT];
static unsigned locks, drops, sweeps;
static uint64_t pool_size = SIZE;
static uint64_t clock_now = 1;

static bool opCanHold(void *c, uint64_t s) { (void)c; return lgk_pool_can_hold(pool_size, s); }
static uint64_t opAlloc(void *c, uint64_t s, void **va) { (void)c; (void)va; return lgp_alloc(&pool, lgk_units(s)); }
static void opLock(void *c) { (void)c; CHECK(locks == 0); locks++; }
static void opUnlock(void *c) { (void)c; CHECK(locks == 1); locks--; }
static bool opPlan(void *c, uint64_t s, struct lgk_item *it, unsigned n) { (void)c; return lgk_plan_fit(&pool, s, it, n, segs); }
static uint64_t opFree(void *c) { (void)c; return pool.free_bytes; }
static void opSweep(void *c) { (void)c; sweeps++; }

static unsigned
opCollect(void *c, struct lgk_item *it, unsigned most, bool window_server)
{
	unsigned n = 0;

	(void)c;
	CHECK(locks == 1);
	for (unsigned i = 0; i < CLIENTS; i++) {
		if (i == WS && !window_server) {
			continue;
		}
		for (unsigned j = 0; j < KEPT && n < most; j++) {
			if (kept[i][j].used && !kept[i][j].mapped) {
				it[n].pa = kept[i][j].pa;
				it[n].len = kept[i][j].size;
				it[n].since = kept[i][j].since;
				it[n].client = (uint16_t)i;
				it[n].slot = (uint16_t)j;
				it[n].chosen = false;
				n++;
			}
		}
	}
	return n;
}

static void
opDrop(void *c, const struct lgk_item *it)
{
	(void)c;
	CHECK(locks == 1);
	CHECK(kept[it->client][it->slot].used);
	kept[it->client][it->slot].used = false;
	CHECK(lgp_free(&pool, it->pa, lgk_units(it->len)) == NULL);
	drops++;
}

static const struct lgk_ops ops = { NULL, opCanHold, opAlloc, opLock, opUnlock, opCollect, opPlan, opFree, opDrop, opSweep };

static void
reset(void)
{
	lgp_init(&pool, BASE, SIZE);
	memset(kept, 0, sizeof(kept));
	drops = sweeps = 0;
	pool_size = SIZE;
	clock_now = 1;
}

static uint64_t
make_kept(unsigned client, uint64_t size)
{
	uint64_t pa = lgp_alloc(&pool, lgk_units(size));

	CHECK(pa != 0);
	for (unsigned j = 0; j < KEPT; j++) {
		if (!kept[client][j].used) {
			kept[client][j].used = true;
			kept[client][j].pa = pa;
			kept[client][j].size = size;
			kept[client][j].since = clock_now++;
			return pa;
		}
	}
	CHECK(!"no kept place");
	return pa;
}

static unsigned
kept_count(unsigned client)
{
	unsigned n = 0;

	for (unsigned j = 0; j < KEPT; j++) {
		n += kept[client][j].used;
	}
	return n;
}

static void
fill_all(void)
{
	while (lgp_alloc(&pool, GPU_POOL_UNIT) != 0) {
	}
}

static void
test_take_cases(void)
{
	struct lgk_result r;
	uint64_t pa;

	/* the review case: 70 MiB over the chunk's room, 800 MiB free, kept buffers of all: nothing goes */
	reset();
	make_kept(WS, 8 * MIB);
	make_kept(1, 8 * MIB);
	while (pool.free_bytes > 800 * MIB) {
		CHECK(lgp_alloc(&pool, 16 * MIB) != 0);
	}
	pa = lgk_take(&ops, items, 70 * MIB, NULL, true, &r);
	CHECK(pa == 0 && r.too_big && r.bytes == 0 && drops == 0);
	CHECK(kept_count(WS) == 1 && kept_count(1) == 1);
	CHECK(lgk_floor(&ops, items, 70 * MIB, FLOOR) == 0 && drops == 0);
	/* 64 MiB exactly: over the room too (a guard unit is out of each chunk) */
	CHECK(!lgk_pool_can_hold(SIZE, GPU_POOL_CHUNK));
	CHECK(lgk_pool_can_hold(SIZE, GPU_POOL_CHUNK - GPU_POOL_UNIT));
	CHECK(!lgk_pool_can_hold(0, MIB));
	CHECK(!lgk_pool_can_hold(SIZE, 0));

	/* room for it: no drop, no lock */
	reset();
	make_kept(1, 8 * MIB);
	pa = lgk_take(&ops, items, 8 * MIB, NULL, true, &r);
	CHECK(pa != 0 && r.bytes == 0 && drops == 0 && sweeps == 0);

	/*
	 * fragments: much free, no range of 2 MiB, and the kept buffers do not join with anything to make one: nothing goes. Each chunk: 1 MiB free, a live buffer, ...
	 */
	reset();
	{
		uint64_t hole[64];
		unsigned holes = 0;

		for (uint64_t a; (a = lgp_alloc(&pool, MIB)) != 0;) {
			if (holes < 64 && ((a - BASE) / MIB) % 2 == 0) {
				hole[holes++] = a;
			}
		}
		for (unsigned i = 0; i < holes; i++) {
			CHECK(lgp_free(&pool, hole[i], MIB) == NULL);
		}
		CHECK(pool.free_bytes >= 32 * MIB);
		pa = lgk_take(&ops, items, 2 * MIB, NULL, true, &r);
		CHECK(pa == 0 && r.no_help && r.bytes == 0 && drops == 0);
	}

	/* a kept buffer that does not touch a hole of enough size does not go; the one that helps goes, alone */
	reset();
	{
		uint64_t a0 = lgp_alloc(&pool, MIB);    /* chunk 0: [live][kept A][free 1 MiB][live][kept B][live]... */
		uint64_t a = make_kept(1, MIB);
		uint64_t f = lgp_alloc(&pool, MIB);
		uint64_t l = lgp_alloc(&pool, MIB);
		uint64_t b = make_kept(1, MIB);
		uint64_t l2 = lgp_alloc(&pool, MIB);

		(void)a0; (void)l; (void)l2;
		fill_all();
		CHECK(lgp_free(&pool, f, MIB) == NULL);
		pa = lgk_take(&ops, items, 2 * MIB, NULL, false, &r);
		CHECK(pa == a && r.bytes == MIB && drops == 1);
		CHECK(kept_count(1) == 1 && kept[1][1].used && kept[1][1].pa == b);
	}

	/* the cheapest set: a 2 MiB kept that fits alone stays when a 1 MiB next to a free 1 MiB does it */
	reset();
	{
		uint64_t big = make_kept(1, 2 * MIB);
		uint64_t l = lgp_alloc(&pool, MIB);
		uint64_t a = make_kept(1, MIB);
		uint64_t f = lgp_alloc(&pool, MIB);
		uint64_t l2 = lgp_alloc(&pool, MIB);

		(void)l; (void)l2; (void)a;
		fill_all();
		CHECK(lgp_free(&pool, f, MIB) == NULL);
		pa = lgk_take(&ops, items, 2 * MIB, NULL, false, &r);
		CHECK(pa != 0 && r.bytes == MIB && drops == 1);
		CHECK(kept[1][0].used && kept[1][0].pa == big);
	}

	/* several together, and across a chunk they do not join */
	reset();
	{
		uint64_t off = GPU_POOL_CHUNK - GPU_POOL_UNIT - MIB;
		uint64_t l = lgp_alloc(&pool, off);     /* chunk 0 ends with a kept of 1 MiB, chunk 1 starts with a kept of 1 MiB */
		uint64_t a = make_kept(1, MIB);

		(void)l;
		CHECK(a == BASE + off);
		uint64_t b = make_kept(1, MIB);

		CHECK(b == BASE + GPU_POOL_CHUNK);
		fill_all();
		pa = lgk_take(&ops, items, 2 * MIB, NULL, false, &r);
		CHECK(pa == 0 && r.no_help && drops == 0);
	}
	reset();
	{
		uint64_t a = make_kept(1, MIB), b = make_kept(2, MIB), c = make_kept(3, MIB);

		(void)a; (void)b; (void)c;
		fill_all();
		pa = lgk_take(&ops, items, 3 * MIB, NULL, false, &r);
		CHECK(pa == a && r.bytes == 3 * MIB && drops == 3);
	}

	/* the window server: not for others, last for itself */
	reset();
	{
		uint64_t ws = make_kept(WS, 2 * MIB);
		uint64_t l = lgp_alloc(&pool, MIB);
		uint64_t o = make_kept(1, 2 * MIB);

		(void)l;
		fill_all();
		/* (lgk_take: the others' first) */
		pa = lgk_take(&ops, items, 2 * MIB, NULL, true, &r);
		CHECK(pa == o && kept_count(WS) == 1 && kept_count(1) == 0);
		/* another client: not the window server's, whatever the need */
		pa = lgk_take(&ops, items, 2 * MIB, NULL, false, &r);
		CHECK(pa == 0 && r.no_help && kept_count(WS) == 1);
		/* its own request: its own too */
		pa = lgk_take(&ops, items, 2 * MIB, NULL, true, &r);
		CHECK(pa == ws && kept_count(WS) == 0);
	}

	/* the floor: only what the request needs, oldest first; all not enough: nothing */
	reset();
	{
		make_kept(1, 8 * MIB);
		make_kept(2, 8 * MIB);
		make_kept(3, 8 * MIB);
		make_kept(WS, 8 * MIB);
		while (pool.free_bytes >= FLOOR + 16 * MIB) {
			CHECK(lgp_alloc(&pool, MIB) != 0);
		}
		uint64_t before = pool.free_bytes, bytes = lgk_floor(&ops, items, MIB, FLOOR);

		CHECK(pool.free_bytes >= FLOOR + MIB);
		CHECK(bytes == 8 * MIB || before >= FLOOR + MIB);
		CHECK(!kept[1][0].used || before >= FLOOR + MIB);       /* the oldest went */
		CHECK(kept[3][0].used);                                 /* not all */
		CHECK(kept[WS][0].used);                                /* never the window server's */
	}
	reset();
	{
		make_kept(1, MIB);
		make_kept(WS, 8 * MIB);
		fill_all();
		CHECK(lgk_floor(&ops, items, MIB, FLOOR) == 0 && drops == 0 && kept_count(1) == 1);
	}
	/* a kept buffer with a live map is no candidate: it does not count as room */
	reset();
	{
		uint64_t a = make_kept(1, 2 * MIB);

		kept[1][0].mapped = true;
		(void)a;
		fill_all();
		pa = lgk_take(&ops, items, 2 * MIB, NULL, true, &r);
		CHECK(pa == 0 && r.no_help && drops == 0 && kept[1][0].used);
	}
}

/* every plan against all subsets of up to 12 candidates, on random pools */
static void
test_plan_exhaustive(void)
{
	srand(2976);
	for (unsigned run = 0; run < 400; run++) {
		reset();
		pool_size = SIZE;
		/* one chunk: live, kept and free in random runs of 1-4 units x 16 */
		uint64_t at = BASE;
		unsigned n = 0;
		struct lgk_item it[12];
		struct { uint64_t pa, len; } frees[64];
		unsigned nf = 0;

		while (at + 4 * MIB < BASE + 4 * 16 * MIB && n < 12) {
			uint64_t len = (1 + (uint64_t)(rand() % 4)) * GPU_POOL_UNIT * 16;
			int kind = rand() % 3;
			uint64_t pa = lgp_alloc(&pool, len);

			CHECK(pa == at);
			if (kind == 0) {
				it[n].pa = pa;
				it[n].len = len;
				it[n].since = (uint64_t)rand() % 1000;
				it[n].client = 1;
				it[n].slot = (uint16_t)n;
				it[n].chosen = false;
				n++;
			} else if (kind == 1 && nf < 64) {
				frees[nf].pa = pa;
				frees[nf].len = len;
				nf++;
			}
			at += len;
		}
		fill_all();
		for (unsigned i = 0; i < nf; i++) {
			CHECK(lgp_free(&pool, frees[i].pa, frees[i].len) == NULL);
		}
		uint64_t size = (1 + (uint64_t)(rand() % 12)) * GPU_POOL_UNIT * 16;
		bool direct = false;

		for (unsigned i = 0; i < pool.count; i++) {
			direct |= pool.range[i].size >= size;
		}
		if (direct) {
			continue;                       /* (lgk_take does not plan then) */
		}
		/* brute force: the least kept bytes of any subset that makes a range of the size */
		static struct lgp copy;
		uint64_t best = UINT64_MAX;

		for (unsigned mask = 0; mask < (1u << n); mask++) {
			uint64_t bytes = 0;

			memcpy(&copy, &pool, sizeof(copy));
			for (unsigned i = 0; i < n; i++) {
				if (mask & (1u << i)) {
					CHECK(lgp_free(&copy, it[i].pa, it[i].len) == NULL);
					bytes += it[i].len;
				}
			}
			if (bytes < best && lgp_alloc(&copy, size) != 0) {
				best = bytes;
			}
		}
		bool found = lgk_plan_fit(&pool, size, it, n, segs);

		CHECK(found == (best != UINT64_MAX));
		if (found) {
			uint64_t bytes = 0;

			for (unsigned i = 0; i < n; i++) {
				if (it[i].chosen) {
					bytes += it[i].len;
					CHECK(lgp_free(&pool, it[i].pa, it[i].len) == NULL);
				}
			}
			CHECK(bytes == best);
			CHECK(lgp_alloc(&pool, size) != 0);     /* the promise */
		} else {
			for (unsigned i = 0; i < n; i++) {
				CHECK(!it[i].chosen);
			}
		}
	}
}

/* many clients, random: no kept buffer goes when the request still fails; the books add up at the end */
static void
test_take_random(void)
{
	struct { uint64_t pa, size; } live[4096];
	unsigned lives = 0;

	reset();
	srand(29760);
	for (unsigned step = 0; step < 200000; step++) {
		int what = rand() % 100;
		uint64_t size = lgk_units(((uint64_t)(rand() % 64) + 1) * (64u << 10) * (1 + rand() % 8));

		if (what < 55 && lives < 4096) {
			struct lgk_result r;
			bool all = rand() % 2;
			unsigned before = kept_count(0) + kept_count(1) + kept_count(2) + kept_count(3);
			unsigned ws_before = kept_count(WS);
			uint64_t pa = lgk_take(&ops, items, size, NULL, all, &r);
			unsigned after = kept_count(0) + kept_count(1) + kept_count(2) + kept_count(3);

			CHECK(locks == 0);
			if (!all) {
				CHECK(kept_count(WS) == ws_before);
			}
			if (pa == 0) {
				CHECK(after == before);         /* no request failed and took kept buffers with it */
				CHECK(r.bytes == 0);
			} else {
				CHECK(lgp_is_out(&pool, pa, size));
				live[lives].pa = pa;
				live[lives].size = size;
				lives++;
			}
		} else if (what < 85 && lives != 0) {
			unsigned i = (unsigned)rand() % lives;
			unsigned client = (unsigned)rand() % CLIENTS;
			bool placed = false;

			if (rand() % 2) {               /* closed and kept */
				for (unsigned j = 0; j < KEPT && !placed; j++) {
					if (!kept[client][j].used) {
						kept[client][j].used = true;
						kept[client][j].pa = live[i].pa;
						kept[client][j].size = live[i].size;
						kept[client][j].since = clock_now++;
						kept[client][j].mapped = false;
						placed = true;
					}
				}
			}
			if (!placed) {
				CHECK(lgp_free(&pool, live[i].pa, live[i].size) == NULL);
			}
			live[i] = live[--lives];
		} else if (what >= 98) {
			(void)lgk_floor(&ops, items, size, FLOOR);
			CHECK(locks == 0);
		}
	}
	for (unsigned i = 0; i < lives; i++) {
		CHECK(lgp_free(&pool, live[i].pa, live[i].size) == NULL);
	}
	for (unsigned c = 0; c < CLIENTS; c++) {
		for (unsigned j = 0; j < KEPT; j++) {
			if (kept[c][j].used) {
				CHECK(lgp_free(&pool, kept[c][j].pa, kept[c][j].size) == NULL);
			}
		}
	}
	CHECK(pool.refused == 0 && pool.lost == 0);
	CHECK(pool.free_bytes == (SIZE / GPU_POOL_CHUNK) * (GPU_POOL_CHUNK - GPU_POOL_UNIT));
}

/* ---------------------------------------------------------------- 5 */
static int fake_retains[8];
static unsigned backs;
static uint64_t back_pa[8];

static int
retains_of(void *memory)
{
	return fake_retains[(intptr_t)memory];
}

static void
back(struct lgk_mapped *m)
{
	back_pa[backs++] = m->address;
	CHECK(lgp_free(&pool, m->address, m->span) == NULL);
	free(m);
}

static struct lgk_mapped *
wait_on(struct lgk_mapped *head, intptr_t memory, uint64_t pa, uint64_t span)
{
	struct lgk_mapped *m = malloc(sizeof(*m));

	m->next = head;
	m->memory = (void *)memory;
	m->address = pa;
	m->span = span;
	return m;
}

static void
test_mapped(void)
{
	struct lgk_mapped *head = NULL;

	CHECK(!lgk_held_by_map(true, false, 1));        /* Turnip's way: the map went first */
	CHECK(lgk_held_by_map(true, false, 2));         /* a map (or a request on its way to one) */
	CHECK(!lgk_held_by_map(true, true, 2));         /* kernel memory: the map holds the pages itself */
	CHECK(!lgk_held_by_map(false, false, 2));       /* not pool memory */
	reset();
	/* A client's buffer, mapped, closed with the map there; the pool is full otherwise: another client asks */
	uint64_t a = lgp_alloc(&pool, 2 * MIB), b = lgp_alloc(&pool, 2 * MIB);

	fill_all();
	fake_retains[1] = 2;
	fake_retains[2] = 3;
	head = wait_on(head, 1, a, 2 * MIB);
	head = wait_on(head, 2, b, 2 * MIB);
	backs = 0;
	CHECK(lgk_mapped_sweep(&head, retains_of, back) == 0);
	CHECK(lgp_alloc(&pool, 2 * MIB) == 0);          /* the mapped bytes are not given to anybody */
	fake_retains[2] = 1;                            /* one map has gone: only that one comes back */
	CHECK(lgk_mapped_sweep(&head, retains_of, back) == 1);
	CHECK(backs == 1 && back_pa[0] == b && head != NULL && head->address == a);
	fake_retains[1] = 1;
	CHECK(lgk_mapped_sweep(&head, retains_of, back) == 1);
	CHECK(backs == 2 && head == NULL);
	CHECK(lgp_alloc(&pool, 2 * MIB) != 0);
	CHECK(lgk_mapped_sweep(&head, retains_of, back) == 0);
}

/* ---------------------------------------------------------------- 6 */
static void
test_tables(void)
{
	/* a model of table writes: runs and jumps; each entry cleaned exactly once, none before it is written */
	srand(2978);
	for (unsigned run = 0; run < 2000; run++) {
		static uint8_t written[4096], cleaned[4096];
		struct lgt_run r = { 0, 0 };
		uint64_t from, to, entry = 0;

		memset(written, 0, sizeof(written));
		memset(cleaned, 0, sizeof(cleaned));
		for (unsigned step = 0; step < 200 && entry < 4000; step++) {
			entry += rand() % 8 == 0 ? (uint64_t)(rand() % 16) + 2 : 1;
			written[entry] = 1;
			if (lgt_run_add(&r, 0x1000 + entry * 8, 8, &from, &to)) {
				for (uint64_t a = from; a < to; a += 8) {
					CHECK(written[(a - 0x1000) / 8] && !cleaned[(a - 0x1000) / 8]);
					cleaned[(a - 0x1000) / 8] = 1;
				}
			}
		}
		while (lgt_run_end(&r, &from, &to)) {
			for (uint64_t a = from; a < to; a += 8) {
				CHECK(written[(a - 0x1000) / 8] && !cleaned[(a - 0x1000) / 8]);
				cleaned[(a - 0x1000) / 8] = 1;
			}
		}
		CHECK(memcmp(written, cleaned, sizeof(written)) == 0);
	}
	/* 2048 adjacent entries: one range */
	{
		struct lgt_run r = { 0, 0 };
		uint64_t from = 0, to = 0;
		unsigned ranges = 0;

		for (uint64_t i = 0; i < 2048; i++) {
			ranges += lgt_run_add(&r, 0x1000 + i * 8, 8, &from, &to);
		}
		ranges += lgt_run_end(&r, &from, &to);
		CHECK(ranges == 1 && from == 0x1000 && to == 0x1000 + 2048 * 8);
		CHECK(!lgt_run_end(&r, &from, &to));
	}
	/* the list against a plain model */
	{
		static uint16_t handles[8192], at[8192];
		static bool in[8193];
		uint32_t count = 0, model = 0;

		srand(29780);
		for (unsigned step = 0; step < 500000; step++) {
			uint32_t h = 1 + (uint32_t)rand() % 8192;

			if (in[h]) {
				lgt_list_remove(handles, at, &count, h);
				in[h] = false;
				model--;
			} else {
				lgt_list_add(handles, at, &count, h);
				in[h] = true;
				model++;
			}
			CHECK(count == model);
			if (step % 50000 == 0) {
				unsigned seen = 0;

				for (uint32_t i = 0; i < count; i++) {
					CHECK(in[handles[i]] && at[handles[i] - 1] == i);
					seen++;
				}
				CHECK(seen == model);
			}
		}
	}
}

int
main(void)
{
	test_time();
	test_push_table();
	test_push_model();
	test_keep();
	test_take_cases();
	test_plan_exhaustive();
	test_take_random();
	test_mapped();
	test_tables();
	printf("gpu-push-test: %s\n", fails ? "FAILED" : "ok");
	return fails != 0;
}
