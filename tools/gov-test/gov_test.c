/*
 * Host test of the Mi A3 CPU governor decision (bsd/dev/laurel_gov_core.h, patch 2890). HOST ONLY: it says what the decision
 * code does with a modelled load, not what the phone does. Model: one core idle, then 100 % busy from t = 0; rows as logged by
 * the OSM table of the Mi A3 Gold cluster are not needed: row 0 and a cap of 7 (topaz line "gold 0->7").
 * Old = the 2303 rule (100 ms tick, 300 ms window, > 90 %: cap, > 70 %: +1), kept here for the comparison only.
 */
#include <stdio.h>
#include <assert.h>
#include "laurel_gov_core.h"

static unsigned
old_next(unsigned busy, unsigned row, unsigned cap, unsigned *low)
{
	if (busy > 90) { *low = 0; return cap; }
	if (busy > 70) { *low = 0; return row < cap ? row + 1 : cap; }
	if (busy < 30) { if (++*low >= 3 && row > 0) { *low = 0; return row - 1; } return row; }
	*low = 0;
	return row;
}

int
main(void)
{
	const unsigned cap = 7;
	unsigned row = 0, low = 0, ms = 0, first = 0, top = 0;
	unsigned full = 0;

	while (row < cap && ms < 2000) {
		ms += 100;
		full = full < 3 ? full + 1 : 3;
		row = old_next(full * 100 / 3, row, cap, &low);
		if (row && !first) { first = ms; }
	}
	top = ms;
	printf("gov-test (host only): 100 %% load from idle, old: first raise %u ms, top row %u ms\n", first, top);
	assert(top == 300);

	row = 0; low = 0; ms = 0; first = 0; full = 0;
	while (row < cap && ms < 2000) {
		ms += LGOV_TICK_MS;
		full = full < LGOV_WINDOW ? full + 1 : LGOV_WINDOW;
		row = lgov_next(full * 100 / LGOV_WINDOW, 100, row, 0, cap, 0, &low);
		if (row && !first) { first = ms; }
	}
	printf("gov-test (host only): 100 %% load from idle, new: first raise %u ms, top row %u ms\n", first, ms);
	assert(ms == LGOV_TICK_MS && first == LGOV_TICK_MS);

	/* one tick not full, no jump: a light load does not reach the cap */
	low = 0;
	assert(lgov_next(10, 50, 1, 0, cap, 0, &low) == 1);
	assert(lgov_next(10, LGOV_JUMP_TICK, 1, 0, cap, 0, &low) == cap);
	assert(lgov_next(10, LGOV_JUMP_TICK - 1, 1, 0, cap, 0, &low) == 1);
	/* the thermal cap wins over the jump */
	assert(lgov_next(10, 100, 1, 0, 4, 0, &low) == 4);

	/* a touch: the hold row at the next tick, before any load shows */
	low = 0;
	row = lgov_next(0, 0, 0, 0, cap, cap, &low);
	assert(row == cap);
	printf("gov-test (host only): touch hold: top row at the next tick (at most %u ms, or at once by the wakeup)\n", LGOV_TICK_MS);

	/* the cap wins over everything: floor and hold above a low cap */
	low = 0;
	assert(lgov_next(100, 100, 0, 0, 2, 0, &low) == 2);
	assert(lgov_next(0, 0, 5, 0, 2, 7, &low) == 2);
	assert(lgov_next(0, 0, 5, 3, 2, 0, &low) == 2);

	/* down: one row after LGOV_DOWN_TICKS below LGOV_LO, not sooner; a busy tick restarts the count */
	low = 0;
	row = 5;
	for (unsigned i = 0; i + 1 < LGOV_DOWN_TICKS; i++) { row = lgov_next(0, 0, row, 0, cap, 0, &low); assert(row == 5); }
	row = lgov_next(0, 0, row, 0, cap, 0, &low);
	assert(row == 4 && low == 0);
	row = lgov_next(0, 0, row, 0, cap, 0, &low);
	assert(low == 1);
	(void)lgov_next(40, 40, row, 0, cap, 0, &low);
	assert(low == 0);

	/* the middle band holds the row and never falls below the floor */
	low = 0;
	assert(lgov_next(50, 50, 3, 0, cap, 0, &low) == 3);
	assert(lgov_next(70, 70, 3, 0, cap, 0, &low) == 5);
	assert(lgov_next(0, 0, 0, 0, cap, 0, &low) == 0);
	/*
	 * laurel 3020: the rows a UI event holds. Tables as the Mi A3 logs them (LAUREL CPUFREQ rows_line):
	 * silver 300 614 864 1017 1305 1420 1612 1804, gold 300 652 902 1056 1401 1536 1804 2016.
	 */
	{
		static const unsigned silver[8] = { 300000, 614400, 864000, 1017600, 1305600, 1420800, 1612800, 1804800 };
		static const unsigned gold[8] = { 300000, 652800, 902400, 1056000, 1401600, 1536000, 1804800, 2016000 };
		static const unsigned low_table[3] = { 300000, 614400, 864000 };

		assert(lgov_hold(1, 1, 0, gold, 8, 7) == 7);            /* touch: gold cap */
		assert(lgov_hold(0, 1, 0, silver, 8, 7) == 7);          /* touch: silver cap */
		assert(lgov_hold(1, 0, 1, gold, 8, 7) == 7);            /* motion: gold cap */
		assert(lgov_hold(0, 0, 1, silver, 8, 7) == 5);          /* motion: silver 1420 MHz, the lowest row >= 1400 */
		assert(silver[lgov_hold(0, 0, 1, silver, 8, 7)] >= LGOV_SILVER_MOTION_KHZ);
		assert(lgov_hold(0, 0, 1, silver, 8, 3) == 3);          /* a thermal cap under it wins */
		assert(lgov_hold(1, 0, 1, gold, 8, 2) == 2);
		assert(lgov_hold(0, 0, 1, low_table, 3, 2) == 2);       /* no row that high: the cap */
		assert(lgov_hold(0, 0, 0, silver, 8, 7) == 0);          /* still screen: nothing held */
		assert(lgov_hold(1, 0, 0, gold, 8, 7) == 0);
		/* the hold goes through lgov_next unchanged: an idle core takes the hold row at once, the cap still wins */
		low = 0;
		assert(lgov_next(0, 0, 0, 0, 7, lgov_hold(0, 0, 1, silver, 8, 7), &low) == 5);
		assert(lgov_next(0, 0, 0, 0, 4, lgov_hold(0, 0, 1, silver, 8, 4), &low) == 4);
		/* after the hold: the down rule, LGOV_DOWN_TICKS of a quiet core per row */
		row = 7;
		for (unsigned i = 0; i < LGOV_DOWN_TICKS; i++) { row = lgov_next(0, 0, row, 0, 7, 0, &low); }
		assert(row == 6);
		printf("gov-test (host only): motion hold: gold cap, silver %u MHz (row %u), %u ms after the last frame; touch: both caps %u ms\n",
		    silver[5] / 1000, 5u, LGOV_MOTION_MS, LGOV_TOUCH_MS);
	}
	printf("gov-test: all checks passed\n");
	return 0;
}
