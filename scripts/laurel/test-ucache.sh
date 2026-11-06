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

# The built trees, when they exist (scripts/laurel/kernel-ios26-linux.sh): in sleh.c the hook must come before the emulator and the LSE path
# in handle_uncategorized and in handle_msr_trap, and in arm_init.c no laurel_ucache_apply() may run before arm_vm_init() (the common
# symbols are zeroed after that point: [V phone 2026-11-07 05:15]).
for tree in "$REPO/out/laurel-kernel-ios26/src/xnu" "$REPO/out/laurel-kernel-ios26/src/shadow" "$REPO/out/laurel-kernel/xnu-src/xnu-8796.141.3"; do
  [ -f "$tree/osfmk/arm64/sleh.c" ] || continue
  python3 -I - "$tree" <<'PY'
import re, sys
tree = sys.argv[1]
sleh = open(tree + "/osfmk/arm64/sleh.c", errors="replace").read()
init = open(tree + "/osfmk/arm/arm_init.c", errors="replace").read()
bad = 0
def body(src, name):
    i = src.index("\n" + name + "(")
    j = src.index("\n}\n", i)
    return src[i:j]
u = body(sleh, "handle_uncategorized")
for later in ("laurel_abi_trap(", "sweet_emulate_lse("):
    if later in u:
        ok = u.index("laurel_ucache_word(") < u.index(later)
        print(f"{tree.split('/')[-1]}: handle_uncategorized: laurel_ucache_word before {later[:-1]}: {'ok' if ok else 'WRONG'}"); bad += not ok
m = body(sleh, "handle_msr_trap")
if "laurel_abi_trap(" in m:
    ok = m.index("laurel_ucache_trap(") < m.index("laurel_abi_trap(")
    print(f"{tree.split('/')[-1]}: handle_msr_trap: laurel_ucache_trap before laurel_abi_trap: {'ok' if ok else 'WRONG'}"); bad += not ok
a = body(init, "arm_init")
first = a.find("laurel_ucache_apply()"); vmi = a.find("arm_vm_init(")
ok = first > 0 and vmi > 0 and first > vmi
print(f"{tree.split('/')[-1]}: arm_init: the first laurel_ucache_apply() comes after arm_vm_init(): {'ok' if ok else 'WRONG'} ({init.count('laurel_ucache_apply();')} calls in the file)"); bad += not ok
print("test-ucache tree check:", "PASS" if not bad else f"FAIL ({bad})")
sys.exit(1 if bad else 0)
PY
done
