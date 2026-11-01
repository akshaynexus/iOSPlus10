/*
 * NegroniCamera (iOSPlus10, Mi A3): the rule of the camera's memory guard, apart from Mach so that a host test runs it (tools/laurel-cam-test/cam7_test.c).
 * One line at each +MEMGUARD_STEP_MB of footprint from MEMGUARD_STEP_MB up. At the limit: the session's filter strip and new Metal pipelines stop, once. A new
 * session lifts this when the footprint is back under 3/4 of the limit.
 */
#ifndef CAMERA_MEM_GUARD_H
#define CAMERA_MEM_GUARD_H
#include <stdbool.h>
#include <stdint.h>

#define MEMGUARD_STEP_MB        256u
#define MEMGUARD_LIMIT_MB       768u    /* [V 2026-11-01] the kernel kills at about 2.6 GB compressed; [I] a working graph holds about 100 MB */

enum memguard_event { MEMGUARD_NONE, MEMGUARD_LINE, MEMGUARD_LIMIT, MEMGUARD_LIFTED, MEMGUARD_STILL_OVER };

struct memguard {
	uint64_t limit_mb, next_line_mb;
	bool over;
};

static inline void
memguard_init(struct memguard *g, uint64_t limit_mb)
{
	g->limit_mb = limit_mb;
	g->next_line_mb = MEMGUARD_STEP_MB;
	g->over = false;
}

/* each sample; a jump over several steps is one line */
static inline enum memguard_event
memguard_sample(struct memguard *g, uint64_t footprint_mb)
{
	bool line = footprint_mb >= g->next_line_mb;

	if (line) {
		g->next_line_mb = (footprint_mb / MEMGUARD_STEP_MB + 1) * MEMGUARD_STEP_MB;
	}
	if (!g->over && footprint_mb >= g->limit_mb) {
		g->over = true;
		return MEMGUARD_LIMIT;
	}
	return line ? MEMGUARD_LINE : MEMGUARD_NONE;
}

/* a new session */
static inline enum memguard_event
memguard_session(struct memguard *g, uint64_t footprint_mb)
{
	if (!g->over) {
		return MEMGUARD_NONE;
	}
	if (footprint_mb * 4 < g->limit_mb * 3) {
		g->over = false;
		g->next_line_mb = (footprint_mb / MEMGUARD_STEP_MB + 1) * MEMGUARD_STEP_MB;
		return MEMGUARD_LIFTED;
	}
	return MEMGUARD_STILL_OVER;
}
#endif
