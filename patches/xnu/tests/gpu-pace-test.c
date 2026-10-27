/*
 * Host test for patch 0389 (negroni_adreno.c pace_tick): the frame-pacing floor of the GPU governor.
 * pace_tick below is the patch's function (same code); the test drives it with 100 ms governor ticks of a
 * model GPU whose frames are late below a "needed" level, and checks: light UI = no floor; a late UI climbs
 * to the needed level and stays within one level of it; an idle pause drops the floor and the next burst
 * starts one under it; the thermal max wins; display off = no floor.
 *
 *   cc -O2 -Wall -o /tmp/gpupace patches/xnu/tests/gpu-pace-test.c && /tmp/gpupace
 */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>

#define MIN(a, b) ((a) < (b) ? (a) : (b))
#define MAX(a, b) ((a) > (b) ? (a) : (b))
static const uint32_t gpu_khz[] = { 0, 220000, 285000, 317000, 350000, 421000, 492000, 545000, 599000, 640000,
	                            734000, 791000, 818000 };
static uint32_t dcvs_level = 1;
static uint32_t negroni_thermal_gpu_cap(void) { return 12; }

/* ---- from the patch ---- */
#define PACE_LATE_PER_100MS     2
#define PACE_FAST_PER_100MS     6
#define PACE_HOLD_MS            500
#define PACE_PROBE_HOLD_MS      2000    /* a step down was late again: the next step down waits this long */
#define PACE_STEP_MS            200
#define PACE_IDLE_MS            300
#define PACE_FORGET_MS          10000
#define PACE_TOP_MS             5000
static bool pace_on = true;
static uint32_t pace_floor, pace_resume, pace_quiet_ms, pace_idle_ms, pace_top_ms;
static uint32_t pace_sec_late, pace_sec_swaps, pace_sec_raises, pace_sec_decays, pace_sec_resumes, pace_sec_max;
static bool pace_top_logged, pace_falling;
static uint32_t pace_hold_ms = PACE_HOLD_MS;

static uint32_t
pace_tick(uint32_t late, uint32_t sw, uint32_t ms, bool dark, uint32_t max)
{
	if (!pace_on) {
		return 0;
	}
	pace_sec_late += late;
	pace_sec_swaps += sw;
	if (dark) {
		pace_floor = pace_resume = pace_quiet_ms = pace_idle_ms = pace_top_ms = 0;
		pace_falling = false;
		return 0;
	}
	if (sw == 0) {
		pace_idle_ms += ms;
		if (pace_idle_ms >= PACE_IDLE_MS && pace_floor != 0) {
			pace_resume = pace_floor;
			pace_floor = pace_quiet_ms = pace_top_ms = 0;
			pace_falling = false;
		}
		if (pace_idle_ms >= PACE_FORGET_MS) {
			pace_resume = 0;
		}
		return pace_floor;
	}
	if (pace_idle_ms >= PACE_IDLE_MS && pace_resume > 1 && pace_floor < pace_resume - 1) {
		pace_floor = MIN(pace_resume - 1, max);
		pace_quiet_ms = 0;
		pace_falling = true;
		pace_sec_resumes++;
	}
	pace_idle_ms = 0;
	uint32_t per100 = late * 100 / MAX(ms, 1u);
	if (per100 >= PACE_LATE_PER_100MS) {
		uint32_t base = MAX(pace_floor, dcvs_level);
		uint32_t up = per100 >= PACE_FAST_PER_100MS ? 2 : 1;
		pace_floor = MIN(base + up, max);
		pace_quiet_ms = 0;
		pace_hold_ms = pace_falling ? PACE_PROBE_HOLD_MS : PACE_HOLD_MS;     /* the level under was too low */
		pace_falling = false;
		pace_sec_raises++;
		if (pace_floor >= max) {
			pace_top_ms += ms;
			if (pace_top_ms >= PACE_TOP_MS && !pace_top_logged) {
				pace_top_logged = true;
				printf("  (log) at the top allowed level %u (%u MHz, cap %u) for %u ms\n", max, gpu_khz[max] / 1000,
				    negroni_thermal_gpu_cap(), pace_top_ms);
			}
		} else {
			pace_top_ms = 0;
		}
	} else if (pace_floor != 0) {
		pace_top_ms = 0;
		pace_quiet_ms += ms;
		if (pace_quiet_ms >= (pace_falling ? PACE_STEP_MS : pace_hold_ms)) {
			pace_floor--;
			pace_quiet_ms = 0;
			pace_falling = true;
			pace_sec_decays++;
		}
	}
	if (pace_floor > max) {
		pace_floor = max;
	}
	pace_sec_max = MAX(pace_sec_max, pace_floor);
	return pace_floor;
}
/* ---- end ---- */

static int fails;
#define CHECK(c, ...) do { if (!(c)) { fails++; printf("FAIL: " __VA_ARGS__); printf("\n"); } } while (0)

/* one 100 ms tick of a model UI: the busy rule wants level 1; frames are late (late ticks per 100 ms) below need */
static uint32_t
tick(uint32_t need, uint32_t sw, uint32_t max, bool dark)
{
	uint32_t late = (need != 0 && dcvs_level < need) ? 2 + 2 * (need - dcvs_level) : 0;
	uint32_t want = 1, pace = pace_tick(late > 12 ? 12 : late, sw, 100, dark, max);
	if (pace > want) {
		want = pace;
	}
	if (want > max) {
		want = max;
	}
	dcvs_level = want;
	return late;
}

int
main(void)
{
	/* 1: light UI, never late: no floor */
	for (int i = 0; i < 50; i++) {
		tick(0, 12, 12, false);
	}
	CHECK(pace_floor == 0 && dcvs_level == 1, "light UI: floor %u level %u", pace_floor, dcvs_level);

	/* 2: heavy UI that needs level 7 (545 MHz): climbs within 1 s, then stays at 6..8 */
	uint32_t t_reach = 0, lo = 99, hi = 0, late_ticks = 0;
	for (uint32_t i = 0; i < 100; i++) {
		late_ticks += tick(7, 6, 12, false) != 0;
		if (!t_reach && dcvs_level >= 7) {
			t_reach = (i + 1) * 100;
		}
		if (i >= 20) {
			lo = MIN(lo, dcvs_level);
			hi = MAX(hi, dcvs_level);
		}
	}
	printf("heavy UI (needs 7): reached in %u ms, then levels %u..%u, late in %u of 100 ticks\n", t_reach, lo, hi, late_ticks);
	CHECK(t_reach && t_reach <= 1000, "reach %u ms", t_reach);
	CHECK(lo >= 6 && hi <= 9, "settle %u..%u", lo, hi);
	CHECK(late_ticks <= 30, "late ticks %u", late_ticks);

	/* 3: content gets light (needs 2): the floor comes down within ~3 s */
	uint32_t t_down = 0;
	for (uint32_t i = 0; i < 60; i++) {
		tick(2, 6, 12, false);
		if (!t_down && dcvs_level <= 3) {
			t_down = (i + 1) * 100;
		}
	}
	printf("lighter content (needs 2): floor at <= 3 after %u ms\n", t_down);
	CHECK(t_down && t_down <= 3000, "down %u ms", t_down);

	/* 4: back to heavy, then a pause (no swaps 500 ms): floor dropped; the next burst starts one under it */
	for (int i = 0; i < 30; i++) {
		tick(7, 6, 12, false);
	}
	uint32_t before = pace_floor;
	for (int i = 0; i < 5; i++) {
		tick(0, 0, 12, false);
	}
	CHECK(pace_floor == 0 && dcvs_level == 1, "pause: floor %u level %u", pace_floor, dcvs_level);
	tick(7, 6, 12, false);
	printf("pause: floor %u before, first burst tick at level %u (resume)\n", before, dcvs_level);
	CHECK(dcvs_level + 1 >= before && dcvs_level >= 5, "resume level %u (floor before %u)", dcvs_level, before);

	/* 5: thermal max 5 wins */
	for (int i = 0; i < 30; i++) {
		tick(9, 6, 5, false);
	}
	CHECK(dcvs_level <= 5 && pace_floor <= 5, "cap: level %u floor %u", dcvs_level, pace_floor);

	/* 6: display off: no floor */
	tick(9, 6, 12, true);
	CHECK(pace_floor == 0 && dcvs_level == 1, "dark: floor %u level %u", pace_floor, dcvs_level);

	/* 7: a slow 10 fps animation with one held tick per 100 ms: below the threshold, no floor */
	pace_floor = 0;
	dcvs_level = 1;
	for (int i = 0; i < 50; i++) {
		pace_tick(1, 1, 100, false, 12);
	}
	CHECK(pace_floor == 0, "10 fps animation: floor %u", pace_floor);

	printf(fails ? "FAIL (%d)\n" : "PASS\n", fails);
	return fails != 0;
}
