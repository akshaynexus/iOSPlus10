#!/bin/bash
# Host test of laurel 2998 + 2999 (LAUREL UCACHE): the word decoder that the kernel runs (osfmk/arm64/laurel_ucache_core.h, taken out of
# patches/laurel/xnu/2999-laurel-ucache-word.patch) against real instruction words: clang assembles the six EL0 cache maintenance forms,
# the test adds their xzr forms (Rt 31) and eleven words that must not match (DC ZVA: SCTLR.DZE's, not UCI's; IC IALLU, IC IALLUIS,
# DC ISW, DC CSW, DC CISW, TLBI, MSR, MRS, NOP, a load). Seconds; no device.
set -eu
REPO=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
python3 -I - "$REPO/patches/laurel/xnu/2999-laurel-ucache-word.patch" "$T/laurel_ucache_core.h" <<'PY'
import sys
out = []; take = False
for line in open(sys.argv[1]):
    if line.startswith('+++ b/osfmk/arm64/laurel_ucache_core.h'): take = True; continue
    if take and line.startswith('diff --git'): break
    if take and line.startswith('+') and not line.startswith('+++'): out.append(line[1:])
open(sys.argv[2], 'w').write(''.join(out))
PY
cat > "$T/t.s" <<'ASM'
	ic ivau, x3
	dc cvac, x7
	dc cvau, x7
	dc cvap, x7
	dc cvadp, x7
	dc civac, x7
	dc zva, x1
	ic iallu
	ic ialluis
	dc isw, x2
	dc csw, x2
	dc cisw, x2
	tlbi vmalle1
	msr tpidr_el0, x4
	mrs x4, ctr_el0
	nop
	ldr x0, [x1]
ASM
clang -target aarch64-linux-gnu -march=armv8.5-a -c "$T/t.s" -o "$T/t.o" 2>/dev/null || clang -target arm64-apple-ios16.0 -march=armv8.5-a -c "$T/t.s" -o "$T/t.o"
llvm-objcopy -O binary --only-section=.text "$T/t.o" "$T/t.bin" 2>/dev/null || llvm-objcopy -O binary --only-section=__TEXT,__text "$T/t.o" "$T/t.bin"
cat > "$T/t.c" <<'C'
#include <stdio.h>
#include <stdint.h>
#include "laurel_ucache_core.h"
int main(int argc, char **argv) {
	static const char *names[] = { "ic ivau", "dc cvac", "dc cvau", "dc cvap", "dc cvadp", "dc civac", "dc zva", "ic iallu", "ic ialluis",
	    "dc isw", "dc csw", "dc cisw", "tlbi vmalle1", "msr tpidr_el0", "mrs ctr_el0", "nop", "ldr" };
	static const int want[] = { 5, 10, 11, 12, 13, 14, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1 };
	static const unsigned want_rt[] = { 3, 7, 7, 7, 7, 7 };
	FILE *f = fopen(argv[1], "rb"); uint32_t w[17]; int bad = 0;
	if (fread(w, 4, 17, f) != 17) { printf("short read\n"); return 1; }
	for (int i = 0; i < 17; i++) {
		unsigned rt = 99; int crm = luc_cache_word(w[i], &rt);
		int ok = crm == want[i] && (crm < 0 || rt == want_rt[i]);
		printf("%-14s %08x -> crm %2d rt %2u %s\n", names[i], w[i], crm, rt, ok ? "ok" : "WRONG"); bad += !ok;
		if (want[i] >= 0) {     /* the xzr form: Rt 31 */
			uint32_t z = (w[i] & ~0x1fu) | 31; rt = 99; crm = luc_cache_word(z, &rt);
			ok = crm == want[i] && rt == 31;
			printf("%-14s %08x -> crm %2d rt %2u %s (xzr)\n", names[i], z, crm, rt, ok ? "ok" : "WRONG"); bad += !ok;
		}
	}
	printf("test-ucache: %s (%d wrong)\n", bad ? "FAIL" : "PASS", bad);
	return bad != 0;
}
C
cc -I"$T" -o "$T/t" "$T/t.c"
"$T/t" "$T/t.bin"
