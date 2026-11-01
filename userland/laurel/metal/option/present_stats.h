/* Frames of the compositor for XNUtils' bench: a histogram of ms from commit to GPU completion, one count per command buffer that wrote a screen-size surface (frontend patches 0002). Plain C, tested on the host (scripts/laurel/option-rule-test.sh). */
#ifndef NMTL_PRESENT_STATS_H
#define NMTL_PRESENT_STATS_H
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#define NMTL_PRESENT_BINS 128   /* 1 ms each; the last bin holds 127 ms and more */

struct nmtl_present_summary { uint64_t frames; unsigned p50, p95, max; };

/* the difference of two histogram readings: base was read at the bench's start */
static inline void nmtl_present_summarize(const uint64_t *now, const uint64_t *base, struct nmtl_present_summary *out)
{
	out->frames = 0;
	out->p50 = out->p95 = out->max = 0;
	for (unsigned i = 0; i < NMTL_PRESENT_BINS; i++) {
		const uint64_t n = now[i] - base[i];
		out->frames += n;
		if (n != 0)
			out->max = i;
	}
	uint64_t seen = 0;
	const uint64_t at50 = (out->frames + 1) / 2, at95 = (out->frames * 95 + 99) / 100;
	bool got50 = false;
	for (unsigned i = 0; i < NMTL_PRESENT_BINS && out->frames != 0; i++) {
		seen += now[i] - base[i];
		if (!got50 && seen >= at50) {
			out->p50 = i;
			got50 = true;
		}
		if (seen >= at95) {
			out->p95 = i;
			break;
		}
	}
}

/* KEY=VALUE lines that the helper's bench-end verb passes to the app */
static inline int nmtl_present_text(char *buf, size_t size, const struct nmtl_present_summary *s, double seconds, const char *stack)
{
	return snprintf(buf, size, "PRESENTS=%llu\nSECONDS=%.2f\nPRESENT_FPS=%.1f\nPRESENT_P50=%u\nPRESENT_P95=%u\nPRESENT_MAX=%u\nSTACK=%s\n", (unsigned long long)s->frames, seconds,
	    seconds > 0 ? (double)s->frames / seconds : 0.0, s->p50, s->p95, s->max, stack);
}
#endif
