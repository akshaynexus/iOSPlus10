/* Host test of laurel_flip_core.h: scripts/laurel/flip-test.sh */
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include "laurel_flip_core.h"

int
main(void)
{
	/* older swap: ids grow; 0 is no id; the wrap of 32 bits is still order */
	assert(!lfl_swap_older(5, 4));
	assert(!lfl_swap_older(5, 5));
	assert(lfl_swap_older(4, 5));
	assert(!lfl_swap_older(0, 5));
	assert(!lfl_swap_older(5, 0));
	assert(!lfl_swap_older(2, 0xfffffffeu));
	assert(lfl_swap_older(0xfffffffeu, 2));
	/* a model of the presenter and the timer: whatever the order of arrival, the panel's swap id never goes down */
	uint32_t shown = 0, seed = 1;
	for (int i = 0; i < 100000; i++) {
		seed = seed * 1103515245u + 12345u;
		uint32_t id = (uint32_t)i + 1 - ((seed >> 16) & 3);
		if (!lfl_swap_older(id, shown)) {
			assert(shown == 0 || (int32_t)(id - shown) >= 0);
			if (id != 0)
				shown = id;
		}
	}
	/* shown again: a surface with no submission since it was shown, not the one on the panel */
	assert(lfl_shown_again(10, 10, false));
	assert(!lfl_shown_again(10, 10, true));
	assert(!lfl_shown_again(11, 10, false));
	assert(!lfl_shown_again(10, 0, false));
	/* refusal: only a late frame, on the presenter, with the rule on */
	assert(lfl_refuse_not_drawn(false, true, true));
	assert(!lfl_refuse_not_drawn(true, true, true));
	assert(!lfl_refuse_not_drawn(false, false, true));
	assert(!lfl_refuse_not_drawn(false, true, false));
	/* the fence of a queued frame: its own, not the next frame's; none new since it was shown: read at the flip */
	assert(lfl_fence_for_flip(20, 10) == 20);
	assert(lfl_fence_for_flip(10, 10) == 0);
	assert(lfl_fence_for_flip(0, 0) == 0);
	{
		/* a model: frames with their submissions; the flip waits for its own fence, so N is on the panel before N + 1's GPU work ends */
		uint32_t at_swap[2] = { 0, 0 }, latest = 0, shown_fence = 0;
		for (uint32_t frame = 0; frame < 2; frame++) {
			latest = 100 + frame;                   /* the frame's submission */
			at_swap[frame] = lfl_fence_for_flip(latest, shown_fence);
		}
		assert(at_swap[0] == 100 && at_swap[1] == 101 && at_swap[0] < latest);
	}
	/* limits: below gpuWait's report (1000 ms) and the clock's stall rule (1500 ms); the queue outlasts two frames at the limit */
	assert(LFL_WAIT_PRESENTER_MS < 1000);
	assert(LFL_QUEUE_MS > 2 * LFL_WAIT_PRESENTER_MS);
	puts("flip-test: all passed");
	return 0;
}
