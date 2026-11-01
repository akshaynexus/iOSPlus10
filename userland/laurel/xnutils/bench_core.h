/* The bench's numbers, plain C, tested on the host (scripts/laurel/xnutils-test.sh). A row is one line of tab-separated text, so that two runs compare with any tool. */
#ifndef XT_BENCH_CORE_H
#define XT_BENCH_CORE_H
#include <stdio.h>
#include <stdlib.h>
#define XT_BENCH_HEADER "date\tstack\tsetting\tturnip\tglass\tscene\tclient_fps\tclient_p50_ms\tclient_p95_ms\tclient_max_ms\tpresent_fps\tpresent_p50_ms\tpresent_p95_ms\tpresent_max_ms\tpresents\n"

struct xt_client { double fps, p50, p95, max; };

static int
xt_cmp_double(const void *a, const void *b)
{
	const double x = *(const double *)a, y = *(const double *)b;

	return x < y ? -1 : x > y;
}

/* intervals in ms, sorted in place; nearest rank */
static inline struct xt_client
xt_client_summary(double *ms, size_t n)
{
	struct xt_client c = { 0, 0, 0, 0 };
	double total = 0;

	if (n == 0) {
		return c;
	}
	qsort(ms, n, sizeof(double), xt_cmp_double);
	for (size_t i = 0; i < n; i++) {
		total += ms[i];
	}
	c.fps = total > 0 ? (double)n * 1000.0 / total : 0;
	c.p50 = ms[(n + 1) / 2 - 1];
	c.p95 = ms[(n * 95 + 99) / 100 - 1];
	c.max = ms[n - 1];
	return c;
}
#endif
