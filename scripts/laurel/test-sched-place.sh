#!/bin/sh
# laurel 3071: host test of osfmk/kern/laurel_sched_place.h (LAUREL SCHED PLACE), the exact rule the kernel runs: with xnu's bucket
# order (FIXPRI 0, FG 1, IN 2, DF 3, UT 4, BG 5) only UT and BG prefer the efficiency pset. Exit 0 = PASS.
set -eu
REPO=$(cd "$(dirname "$0")/../.." && pwd)
H=$(ls -d "$REPO"/out/laurel-kernel-ios26/src/xnu/osfmk/kern/laurel_sched_place.h 2>/dev/null || true)
[ -n "$H" ] || { H=$(mktemp -d)/laurel_sched_place.h; sed -n '/^+++ b\/osfmk\/kern\/laurel_sched_place.h/,$p' "$REPO/patches/laurel/xnu/3071-laurel-sched-place.patch" | sed '1,2d; s/^+//' > "$H"; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cat > "$T/t.c" <<'C'
#include <stdio.h>
#include "laurel_sched_place.h"
int main(void)
{
	const unsigned want[6] = { 0, 0, 0, 0, 1, 1 };    /* FIXPRI FG IN DF UT BG */
	int fails = 0;
	for (unsigned b = 0; b < 6; b++) {
		unsigned got = lsp_pset_for_bucket(b, 4, 5, 0, 1);
		if (got != want[b]) { printf("FAIL: bucket %u -> pset %u, want %u\n", b, got, want[b]); fails++; }
	}
	/* the boot pset may be 1 and the efficiency pset 0 on another board */
	if (lsp_pset_for_bucket(5, 4, 5, 1, 0) != 0 || lsp_pset_for_bucket(1, 4, 5, 1, 0) != 1) { printf("FAIL: swapped ids\n"); fails++; }
	printf("%s: test-sched-place\n", fails ? "FAIL" : "PASS");
	return fails ? 1 : 0;
}
C
cc -O2 -Wall -Wextra -I"$(dirname "$H")" -o "$T/t" "$T/t.c"
"$T/t"
