/* The memory guard's rule (userland/camera/camera_mem_guard.h): lines by step, one limit, lift by a new session only under 3/4 of the limit. */
#include <assert.h>
#include <stdio.h>
#include "camera_mem_guard.h"

int
main(void)
{
	struct memguard g;

	memguard_init(&g, MEMGUARD_LIMIT_MB);
	assert(memguard_sample(&g, 100) == MEMGUARD_NONE);
	assert(memguard_sample(&g, 256) == MEMGUARD_LINE);
	assert(memguard_sample(&g, 300) == MEMGUARD_NONE);                      /* no line twice in one step */
	assert(memguard_sample(&g, 700) == MEMGUARD_LINE);                      /* a jump over steps: one line */
	assert(memguard_sample(&g, 767) == MEMGUARD_NONE);
	assert(memguard_session(&g, 767) == MEMGUARD_NONE);                     /* not over: nothing to lift */
	assert(memguard_sample(&g, 768) == MEMGUARD_LIMIT && g.over);
	assert(memguard_sample(&g, 770) == MEMGUARD_NONE);                      /* the limit once */
	assert(memguard_sample(&g, 1024) == MEMGUARD_LINE);                     /* still growing: named */
	assert(memguard_sample(&g, 2600) == MEMGUARD_LINE);
	assert(memguard_session(&g, 600) == MEMGUARD_STILL_OVER && g.over);     /* over 3/4 of 768 = 576 */
	assert(memguard_session(&g, 575) == MEMGUARD_LIFTED && !g.over);
	assert(memguard_sample(&g, 575) == MEMGUARD_NONE);                      /* its step, not a line from 256 up */
	assert(memguard_sample(&g, 800) == MEMGUARD_LIMIT);                     /* a later session can stop again */
	printf("cam7: memory guard rule OK\n");
	return 0;
}
