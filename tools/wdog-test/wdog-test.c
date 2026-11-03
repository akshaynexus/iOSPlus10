/*
 * laurel 2986: host test of the watchdog's rules: the code of laurel_wdog_core.h, and a model of the hardware over the cases of docs/laurel_sprout/watchdog.md.
 * Time steps 100 ms. The model: a thread that runs (or stops), CPUs that answer (or stop), a counter reset by a pet.
 */
#include <stdio.h>
#include <string.h>
#include "laurel_wdog_core.h"

static int fails;
#define CHECK(c, ...) do { if (!(c)) { printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); fails++; } } while (0)

#define CPUS 8
struct sim {
	unsigned stuck_at[CPUS];        /* ms; 0: never */
	unsigned stall_from[CPUS], stall_ms[CPUS];      /* a CPU with interrupts off for a time */
	unsigned thread_stop_at;        /* ms; 0: never */
	unsigned thread_stall_from, thread_stall_ms;
	unsigned used;                  /* mask of CPUs in use */
};
struct end { unsigned bark, bite, pets; };

static struct end
run(const struct sim *s, unsigned until_ms)
{
	struct end e = { 0, 0, 0 };
	unsigned count_ms = 0, next_round = 0, sent[CPUS], level[CPUS];

	memset(sent, 0, sizeof(sent));
	memset(level, 0, sizeof(level));
	for (unsigned t = 100; t <= until_ms && !e.bite; t += 100) {
		count_ms += 100;
		/* a CPU that can take an interrupt answers an open signal */
		for (unsigned i = 0; i < CPUS; i++) {
			int off = (s->stuck_at[i] && t >= s->stuck_at[i]) ||
			    (s->stall_ms[i] && t >= s->stall_from[i] && t < s->stall_from[i] + s->stall_ms[i]);
			if (!off) {
				sent[i] = 0;
			}
		}
		int runs = !(s->thread_stop_at && t >= s->thread_stop_at) &&
		    !(s->thread_stall_ms && t >= s->thread_stall_from && t < s->thread_stall_from + s->thread_stall_ms);
		if (runs && t >= next_round) {
			unsigned silent[CPUS];
			unsigned char used[CPUS];

			next_round = t + LWD_PET_MS;
			for (unsigned i = 0; i < CPUS; i++) {
				used[i] = (s->used >> i) & 1;
				silent[i] = used[i] && sent[i] ? t - sent[i] : 0;
				(void)lwd_line(silent[i], &level[i]);
			}
			if (lwd_pet_ok(silent, used, CPUS)) {
				count_ms = 0;
				e.pets++;
			}
			for (unsigned i = 0; i < CPUS; i++) {
				if (!sent[i]) {
					sent[i] = t;
				}
			}
		}
		if (!e.bark && count_ms >= LWD_BARK_S * 1000) {
			e.bark = t;
		}
		if (count_ms >= LWD_BITE_S * 1000) {
			e.bite = t;
		}
	}
	return e;
}

int
main(void)
{
	struct sim s;
	struct end e;

	/* the hardware's field */
	CHECK(lwd_ticks(LWD_BARK_S) == 393180u, "bark %u", lwd_ticks(LWD_BARK_S));
	CHECK(lwd_ticks(LWD_BITE_S) == 655300u, "bite %u", lwd_ticks(LWD_BITE_S));
	CHECK(lwd_ticks(LWD_PANIC_S) <= LWD_COUNT_MAX, "panic field");
	CHECK(lwd_ticks(33) == LWD_COUNT_MAX, "33 s does not fit 20 bits");
	CHECK(LWD_BARK_S < LWD_BITE_S, "bark first");
	CHECK(LWD_PET_MS * 4 < LWD_BARK_S * 1000, "several pets before a bark");

	/* healthy for an hour: no bark */
	memset(&s, 0, sizeof(s)); s.used = 0xff;
	e = run(&s, 3600000);
	CHECK(!e.bark && !e.bite && e.pets > 3500, "healthy: bark %u bite %u pets %u", e.bark, e.bite, e.pets);

	/* the longest normal stalls: docs/laurel_sprout/watchdog.md: no bark */
	memset(&s, 0, sizeof(s)); s.used = 0xff; s.stall_from[5] = 30000; s.stall_ms[5] = 5000;     /* one CPU off 5 s: the UFS command limit, spun with interrupts off */
	e = run(&s, 120000);
	CHECK(!e.bark, "CPU off 5 s: bark at %u", e.bark);
	memset(&s, 0, sizeof(s)); s.used = 0xff;
	for (int i = 0; i < CPUS; i++) { s.stall_from[i] = 30000; s.stall_ms[i] = 1000; }           /* a stackshot, over-long: all CPUs 1 s */
	s.thread_stall_from = 30000; s.thread_stall_ms = 1000;
	e = run(&s, 120000);
	CHECK(!e.bark, "stackshot: bark at %u", e.bark);
	memset(&s, 0, sizeof(s)); s.used = 0xff; s.thread_stall_from = 10000; s.thread_stall_ms = 10000;   /* the thread itself 10 s late: under the bark */
	e = run(&s, 120000);
	CHECK(!e.bark, "thread 10 s late: bark at %u", e.bark);

	/* a CPU not in use (CPU 4 not alive in boot 6) stops nothing */
	memset(&s, 0, sizeof(s)); s.used = 0xef; s.stuck_at[4] = 100;
	e = run(&s, 120000);
	CHECK(!e.bark, "CPU not in use: bark at %u", e.bark);

	/* one stuck CPU: stock's case. Bark 20 s, bite 28 s after it stopped, within one round */
	memset(&s, 0, sizeof(s)); s.used = 0xff; s.stuck_at[5] = 60000;
	e = run(&s, 120000);
	CHECK(e.bark >= 60000 + 19000 && e.bark <= 60000 + 22000, "stuck CPU: bark at %u", e.bark);
	CHECK(e.bite >= 60000 + 27000 && e.bite <= 60000 + 30000, "stuck CPU: bite at %u", e.bite);
	printf("one stuck CPU at 60 s: bark at %u ms, bite at %u ms\n", e.bark, e.bite);

	/* all CPUs and the thread stop (13:46:59): the bite only needs the counter */
	memset(&s, 0, sizeof(s)); s.used = 0xff; s.thread_stop_at = 60000;
	for (int i = 0; i < CPUS; i++) { s.stuck_at[i] = 60000; }
	e = run(&s, 120000);
	CHECK(e.bite >= 60000 + 19000 && e.bite <= 60000 + 21000, "all stop: bite at %u", e.bite);
	printf("all CPUs stop at 60 s: bark at %u ms (no CPU takes it), bite at %u ms\n", e.bark, e.bite);

	/* lines: 2 s, 5 s, 10 s, then a line when it answers */
	unsigned level = 0;
	CHECK(lwd_line(1000, &level) == 0, "1 s");
	CHECK(lwd_line(2000, &level) == 1 && level == 1, "2 s");
	CHECK(lwd_line(3000, &level) == 0, "3 s");
	CHECK(lwd_line(5000, &level) == 1 && level == 2, "5 s");
	CHECK(lwd_line(10000, &level) == 1 && level == 3, "10 s");
	CHECK(lwd_line(60000, &level) == 0, "no more lines");
	CHECK(lwd_line(0, &level) == -1 && level == 0, "answers again");
	CHECK(lwd_line(0, &level) == 0, "quiet");
	level = 0;
	CHECK(lwd_line(12000, &level) == 1 && level == 3, "one line for a jump");

	printf(fails ? "FAILED: %d\n" : "PASS\n", fails);
	return fails != 0;
}
