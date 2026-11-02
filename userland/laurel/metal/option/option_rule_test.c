/* Host test of option_rule.h: scripts/laurel/option-rule-test.sh */
#include <stdlib.h>
#include "option_rule.h"
#include "present_stats.h"
static int known(const char *n) { return !strcmp(n, "hot") || !strcmp(n, "native"); }
static int fails_seen;
static void want(const char *label, const char *got, const char *expect)
{
	if (strcmp(got, expect) != 0) {
		printf("FAIL %s: got %s, want %s\n", label, got, expect);
		fails_seen++;
	} else {
		printf("ok   %s: %s\n", label, got);
	}
}
int main(void)
{
	struct nmtl_option_state s;
	char why[160];
	memset(&s, 0, sizeof(s));
	want("missing setting", nmtl_option_choose(NULL, known, &s, 0, 0, 1, why, sizeof(why)), "default");
	want("empty setting", nmtl_option_choose("", known, &s, 0, 0, 1, why, sizeof(why)), "default");
	want("unknown option", nmtl_option_choose("junk", known, &s, 0, 0, 1, why, sizeof(why)), "default");
	if (why[0] == 0) { printf("FAIL unknown option has no reason\n"); fails_seen++; }
	/* the third option goes through the same rule: a reported failure returns it to the default at once */
	{
		struct nmtl_option_state n;
		memset(&n, 0, sizeof(n));
		want("native: first start", nmtl_option_choose("native", known, &n, 0, 0, 1, why, sizeof(why)), "native");
		want("native: reported failure: the default", nmtl_option_choose("native", known, &n, 0, 1, 1, why, sizeof(why)), "default");
		want("native: stays default until written again", nmtl_option_choose("native", known, &n, 0, 0, 1, why, sizeof(why)), "default");
	}
	want("first start", nmtl_option_choose("hot", known, &s, 0, 0, 1, why, sizeof(why)), "hot");
	want("second start, no ok: 1 fail", nmtl_option_choose("hot", known, &s, 0, 0, 1, why, sizeof(why)), "hot");
	want("third start, no ok: 2 fails, default", nmtl_option_choose("hot", known, &s, 0, 0, 1, why, sizeof(why)), "default");
	want("stays default in a crash loop", nmtl_option_choose("hot", known, &s, 0, 0, 1, why, sizeof(why)), "default");
	want("a client follows the failed state", nmtl_option_choose("hot", known, &s, 0, 0, 0, why, sizeof(why)), "default");
	want("setting default clears", nmtl_option_choose("default", known, &s, 0, 0, 1, why, sizeof(why)), "default");
	if (s.fails || s.pending) { printf("FAIL state not cleared\n"); fails_seen++; }
	want("chosen again", nmtl_option_choose("hot", known, &s, 0, 0, 1, why, sizeof(why)), "hot");
	want("a lit screen resets", nmtl_option_choose("hot", known, &s, 1, 0, 1, why, sizeof(why)), "hot");
	want("still fine after ok", nmtl_option_choose("hot", known, &s, 1, 0, 1, why, sizeof(why)), "hot");
	want("reported failure: at once", nmtl_option_choose("hot", known, &s, 0, 1, 1, why, sizeof(why)), "default");
	memset(&s, 0, sizeof(s));
	want("clients do not count", nmtl_option_choose("hot", known, &s, 0, 0, 0, why, sizeof(why)), "hot");
	want("clients do not count (2)", nmtl_option_choose("hot", known, &s, 0, 0, 0, why, sizeof(why)), "hot");
	if (s.fails) { printf("FAIL a client counted\n"); fails_seen++; }
	nmtl_option_state_read("garbage", &s);
	if (s.option[0]) { printf("FAIL garbage state kept\n"); fails_seen++; }
	nmtl_option_state_read("hot 1 1\n", &s);
	want("state text read", s.fails == 1 && s.pending == 1 ? "yes" : "no", "yes");
	{
		uint64_t base[NMTL_PRESENT_BINS] = { 0 }, now[NMTL_PRESENT_BINS] = { 0 };
		struct nmtl_present_summary p;
		char text[200];
		base[20] = 7;
		now[20] = 7 + 50;       /* 50 at 20 ms */
		now[33] = 45;           /* 45 at 33 ms */
		now[127] = 5;           /* 5 at 127 ms or more */
		nmtl_present_summarize(now, base, &p);
		snprintf(text, sizeof(text), "%llu %u %u %u", (unsigned long long)p.frames, p.p50, p.p95, p.max);
		want("histogram: frames p50 p95 max", text, "100 20 33 127");
		memcpy(now, base, sizeof(now));
		nmtl_present_summarize(now, base, &p);
		snprintf(text, sizeof(text), "%llu %u %u %u", (unsigned long long)p.frames, p.p50, p.p95, p.max);
		want("histogram: no frames", text, "0 0 0 0");
		nmtl_present_text(text, sizeof(text), &p, 0, "hot");
		want("no frames, no division by 0", strstr(text, "PRESENT_FPS=0.0") ? "yes" : "no", "yes");
	}
	printf("option-rule-test: %s\n", fails_seen ? "FAIL" : "PASS");
	return fails_seen != 0;
}
