/*
 * laurel 3091: host test of the USB RX liveness rules (laurel_usb_check_core.h, taken from the patch by scripts/laurel/usb-check-test.sh). PASS = exit 0.
 */
#include <stdio.h>
#include <string.h>
#include "laurel_usb_check_core.h"

static int failures, checks;
#define CHECK(c, ...) do { checks++; if (!(c)) { failures++; printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)
#define S 1000000000ull

/* run the rules from t0 for secs seconds in 50 ms steps; frames arrive at the given times (0 = none); returns the actions in order */
static unsigned
run(struct luc *c, unsigned long long t0, unsigned secs, int configured, const unsigned long long *frames_at, unsigned nframes,
    enum luc_act *out, unsigned max, unsigned long long *rx)
{
	unsigned n = 0, fi = 0;
	for (unsigned long long now = t0; now <= t0 + secs * S; now += S / 20) {
		while (fi < nframes && frames_at[fi] <= now) { (*rx)++; fi++; }
		enum luc_act a = luc_step(c, now, configured, *rx);
		if (a != LUC_NONE && n < max) { out[n++] = a; }
		if (a == LUC_RESTART) { configured = 0; }     /* the restart drops the configuration; the host must set it again */
	}
	return n;
}

int main(void)
{
	struct luc c;
	enum luc_act acts[32];
	unsigned long long rx;
	unsigned n;

	CHECK(LUC_QUIET_S >= 20 && LUC_QUIET_S < 60, "the quiet window is longer than the host's 10 s keepalive and short enough to matter");
	CHECK(LUC_ASKS >= 2 && LUC_ASK_S >= 1, "more than one ask, a second between");

	/* 1. a live host: a frame every 10 s for 10 minutes: no action at all */
	memset(&c, 0, sizeof(c)); rx = 0;
	unsigned long long live[60]; for (unsigned i = 0; i < 60; i++) { live[i] = (i + 1) * 10 * S; }
	n = run(&c, 0, 600, 1, live, 60, acts, 32, &rx);
	CHECK(n == 0, "live host: %u actions", n);

	/* 2. no host (not configured) for an hour: nothing */
	memset(&c, 0, sizeof(c)); rx = 0;
	n = run(&c, 0, 3600, 0, NULL, 0, acts, 32, &rx);
	CHECK(n == 0, "no host: %u actions", n);

	/* 3. a silent host that answers ARP: one ask at 30 s, the reply ends it, and the next ask comes 30 s after the reply */
	memset(&c, 0, sizeof(c)); rx = 0;
	unsigned long long reply[2] = { 31 * S, 62 * S };
	n = run(&c, 0, 70, 1, reply, 2, acts, 32, &rx);
	CHECK(n == 4 && acts[0] == LUC_ASK && acts[1] == LUC_BACK && acts[2] == LUC_ASK && acts[3] == LUC_BACK,
	    "silent host that answers: %u actions (%d %d %d)", n, acts[0], acts[1], acts[2]);
	CHECK(c.recovered == 2 && c.rearms == 0 && c.asks == 2, "an answered ask is a recovery with no repair");

	/* 4. RX dead, host configured: the full ladder, then the panic, in a bounded time */
	memset(&c, 0, sizeof(c)); rx = 0;
	n = run(&c, 0, 120, 1, NULL, 0, acts, 32, &rx);
	CHECK(n == LUC_ASKS + 3, "dead RX: %u actions", n);
	for (unsigned i = 0; i < LUC_ASKS && i < n; i++) { CHECK(acts[i] == LUC_ASK, "action %u is an ask", i); }
	CHECK(n >= LUC_ASKS + 3 && acts[LUC_ASKS] == LUC_REARM && acts[LUC_ASKS + 1] == LUC_RESTART && acts[LUC_ASKS + 2] == LUC_PANIC,
	    "then re-arm, restart, panic");
	CHECK(c.asks == LUC_ASKS + 1 && c.rearms == 1 && c.restarts == 1, "counts: asks %u rearms %u restarts %u", c.asks, c.rearms, c.restarts);
	CHECK(c.stage == LUC_S_DEAD, "dead at the end");
	/* the time to the panic: quiet + asks + re-arm + restart wait (the host never configures again) */
	{
		struct luc d; memset(&d, 0, sizeof(d)); unsigned long long r = 0, at = 0;
		int configured = 1;
		for (unsigned long long now = 0; now <= 200 * S; now += S / 20) {
			enum luc_act a = luc_step(&d, now, configured, r);
			if (a == LUC_RESTART) { configured = 0; }
			if (a == LUC_PANIC) { at = now; break; }
		}
		unsigned long long want = (LUC_QUIET_S + LUC_ASKS * LUC_ASK_S + LUC_ASK_S + LUC_RESTART_WAIT_S) * S;
		CHECK(at >= want - S && at <= want + S, "panic at %llu s, wanted about %llu s", at / S, want / S);
		CHECK(at <= 90 * S, "a dead RX ends in a panic within 90 s");
	}

	/* 5. after the restart the host configures again (the restart itself worked) and answers: recovered, no panic */
	memset(&c, 0, sizeof(c)); rx = 0;
	n = 0;
	{
		unsigned long long r = 0; int configured = 1; unsigned seen_restart = 0;
		for (unsigned long long now = 0; now <= 50 * S; now += S / 20) {
			enum luc_act a = luc_step(&c, now, configured, r);
			if (a != LUC_NONE && n < 32) { acts[n++] = a; }
			if (a == LUC_RESTART) { configured = 0; seen_restart = 1; }
			else if (seen_restart == 1 && !configured && now >= 45 * S) { configured = 1; seen_restart = 2; }
			else if (seen_restart == 2 && a == LUC_ASK) { r++; seen_restart = 3; }     /* the reply to the ask after the restart */
		}
		CHECK(n == LUC_ASKS + 4 && acts[n - 1] == LUC_BACK && acts[n - 2] == LUC_ASK, "restart, host back, ask, reply: %u actions, last %d", n, acts[n - 1]);
		CHECK(c.stage == LUC_S_QUIET && c.recovered == 1, "quiet again");
		CHECK(strcmp(luc_stage_name(c.last_stage), "the ask after the gadget restart") == 0, "the line names the stage: %s", luc_stage_name(c.last_stage));
	}

	/* 6. the host leaves (cable out) during the asks: the check ends with no action; it comes back: a fresh quiet window */
	memset(&c, 0, sizeof(c)); rx = 0;
	n = run(&c, 0, 33, 1, NULL, 0, acts, 32, &rx);
	CHECK(n == 2 && acts[0] == LUC_ASK && acts[1] == LUC_ASK, "two asks by 33 s: %u", n);
	n = run(&c, 33 * S, 5, 0, NULL, 0, acts, 32, &rx);
	CHECK(n == 0 && c.stage == LUC_S_QUIET, "host gone: quiet, no action");
	n = run(&c, 38 * S, 25, 1, NULL, 0, acts, 32, &rx);
	CHECK(n == 0, "host back for 25 s: the window starts over (%u actions)", n);

	/* 7. a frame in the re-armed stage: back, and the counters say what it took */
	memset(&c, 0, sizeof(c)); rx = 0;
	unsigned long long late[1] = { 37 * S };
	n = run(&c, 0, 40, 1, late, 1, acts, 32, &rx);
	CHECK(n == LUC_ASKS + 2 && acts[LUC_ASKS] == LUC_REARM && acts[LUC_ASKS + 1] == LUC_BACK, "re-arm brought it back: %u actions", n);
	CHECK(strcmp(luc_stage_name(c.last_stage), "the RX re-arm") == 0, "names the re-arm");

	printf("usb-check: %d checks, %d failures\n", checks, failures);
	return failures ? 1 : 0;
}
