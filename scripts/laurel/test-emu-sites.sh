#!/bin/sh
# laurel 3070: host test of osfmk/arm64/laurel_emu_sites.h (LAUREL EMU SITES), the exact table the kernel runs: a site counts, a second
# site in the same slot takes the next probe, a full probe run counts as "other", the minute's top is sorted and shows deltas, the
# comm is cut at 16, the unslid pc is pc - slide (0 with no slide), 8 threads on one site lose no count. Exit 0 = PASS.
set -eu
REPO=$(cd "$(dirname "$0")/../.." && pwd)
H=$(ls -d "$REPO"/out/laurel-kernel-ios26/src/xnu/osfmk/arm64/laurel_emu_sites.h 2>/dev/null || true)
[ -n "$H" ] || { H=$(mktemp -d)/laurel_emu_sites.h; sed -n '/^+++ b\/osfmk\/arm64\/laurel_emu_sites.h/,$p' "$REPO/patches/laurel/xnu/3070-laurel-emu-sites.patch" | sed '1,2d; s/^+//' > "$H"; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cat > "$T/t.c" <<'C'
#include <stdio.h>
#include <string.h>
#include <pthread.h>
#include "laurel_emu_sites.h"
static struct les_table t;
static int fails;
#define CHECK(c, m) do { if (!(c)) { printf("FAIL: %s\n", m); fails++; } } while (0)
static void *hammer(void *a) { for (int i = 0; i < 100000; i++) les_note(&t, 0x1000, 0x1e2041c0, 4, "SpringBoard", 0x100); return a; }
int main(void)
{
	unsigned top[LES_TOP], used;
	uint64_t d[LES_TOP];
	/* sites */
	for (int i = 0; i < 10; i++) les_note(&t, 0x1a2b3c4d8ULL, 0x1e2041c0u, 4, "backboardd", 0x1ca74000ULL);
	for (int i = 0; i < 3; i++) les_note(&t, 0x100000ULL, 0xc8a00000u, 1, "a-name-that-is-longer-than-sixteen", 0);
	les_note(&t, 0x200000ULL, 0x1u, 0, "x", 0x300000ULL);  /* pc below the slide: unslid 0 */
	unsigned n = les_top(&t, top, d, &used);
	CHECK(n == 3 && used == 3, "3 sites");
	CHECK(d[0] == 10 && t.s[top[0]].pc == 0x1a2b3c4d8ULL && t.s[top[0]].unslid == 0x1a2b3c4d8ULL - 0x1ca74000ULL && t.s[top[0]].cls == 4, "hottest first, unslid");
	CHECK(d[1] == 3 && strcmp(t.s[top[1]].comm, "a-name-that-is-l") == 0, "comm cut at 16");
	CHECK(d[2] == 1 && t.s[top[2]].unslid == 0, "no unslid below the slide");
	/* the next minute: deltas only */
	les_note(&t, 0x100000ULL, 0xc8a00000u, 1, "a", 0);
	n = les_top(&t, top, d, &used);
	CHECK(n == 1 && d[0] == 1 && t.s[top[0]].pc == 0x100000ULL && used == 3, "delta of the minute");
	/* collisions: LES_PROBE pcs in one slot run, the next is other */
	memset(&t, 0, sizeof(t));
	unsigned h = les_hash(0x4000); unsigned found = 0; uint64_t pcs[LES_PROBE + 1];
	for (uint64_t pc = 0x4000; found < LES_PROBE + 1; pc += 4) if (les_hash(pc) == h) pcs[found++] = pc;
	for (unsigned i = 0; i < LES_PROBE; i++) les_note(&t, pcs[i], 0, 1, "c", 0);
	CHECK(t.other == 0, "probe run holds LES_PROBE pcs");
	les_note(&t, pcs[LES_PROBE], 0, 1, "c", 0);
	CHECK(t.other == 1, "one more in that run is other");
	/* more than LES_TOP sites: the top is the LES_TOP largest, sorted */
	memset(&t, 0, sizeof(t));
	for (unsigned s = 0; s < 12; s++) for (unsigned k = 0; k <= s; k++) les_note(&t, 0x8000 + s * 64, 0, 2, "m", 0);
	n = les_top(&t, top, d, &used);
	CHECK(n == LES_TOP && used == 12 && d[0] == 12 && d[1] == 11 && d[2] == 10 && d[3] == 9, "top 4 of 12, sorted");
	/* threads */
	memset(&t, 0, sizeof(t));
	pthread_t th[8];
	for (int i = 0; i < 8; i++) pthread_create(&th[i], NULL, hammer, NULL);
	for (int i = 0; i < 8; i++) pthread_join(th[i], NULL);
	n = les_top(&t, top, d, &used);
	CHECK(n == 1 && d[0] == 800000 && used == 1 && t.other == 0 && strcmp(t.s[top[0]].comm, "SpringBoard") == 0, "8 threads, one site, no lost count");
	printf("%s: test-emu-sites\n", fails ? "FAIL" : "PASS");
	return fails ? 1 : 0;
}
C
cc -O2 -Wall -Wextra -I"$(dirname "$H")" -pthread -o "$T/t" "$T/t.c"
"$T/t"
