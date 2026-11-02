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
	printf("gov-test: all checks passed\n");
	return 0;
}
