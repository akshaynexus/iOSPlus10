#!/bin/bash
# Host test of laurel 2998 (LAUREL UCACHE): the ISS that the kernel matches for each EL0 cache instruction equals the fields of the real
# instruction. clang assembles `ic ivau, x3` and the five `dc` forms; the test reads op1, CRn, CRm, op2 and Rt from the 32-bit word and
# builds the ESR ISS as the architecture does for a trapped SYS instruction (Op0 [21:20], Op2 [19:17], Op1 [16:14], CRn [13:10], Rt [9:5],
# CRm [4:1], direction [0]); the kernel's LUC_SYS_CACHE(crm) with Rt masked must be equal. Seconds; no device.
set -eu
REPO=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cat > "$T/t.s" <<'ASM'
	ic ivau, x3
	dc cvac, x7
	dc cvau, x7
	dc cvap, x7
	dc cvadp, x7
	dc civac, x7
ASM
clang -target aarch64-linux-gnu -march=armv8.5-a -c "$T/t.s" -o "$T/t.o" 2>/dev/null || clang -target arm64-apple-ios16.0 -march=armv8.5-a -c "$T/t.s" -o "$T/t.o"
llvm-objcopy -O binary --only-section=.text "$T/t.o" "$T/t.bin" 2>/dev/null || llvm-objcopy -O binary --only-section=__TEXT,__text "$T/t.o" "$T/t.bin"
python3 -I - "$T/t.bin" <<'PY'
import struct, sys
words = struct.unpack('<6I', open(sys.argv[1], 'rb').read()[:24])
crms = [5, 10, 11, 12, 13, 14]
names = ['ic ivau', 'dc cvac', 'dc cvau', 'dc cvap', 'dc cvadp', 'dc civac']
def kernel_match(crm): return (1 << 20) | (1 << 17) | (3 << 14) | (7 << 10) | (crm << 1)   # LUC_SYS_CACHE(crm)
mask = 0x003ffc1f
bad = 0
for w, crm, n in zip(words, crms, names):
    # SYS: 1101 0101 0000 1 op1(3) CRn(4) CRm(4) op2(3) Rt(5)
    assert (w >> 21) == 0b11010101000, hex(w)
    op1, crn, icrm, op2, rt = (w >> 16) & 7, (w >> 12) & 0xF, (w >> 8) & 0xF, (w >> 5) & 7, w & 0x1F
    iss = (1 << 20) | (op2 << 17) | (op1 << 14) | (crn << 10) | (rt << 5) | (icrm << 1)
    ok = (iss & mask) == kernel_match(crm) and icrm == crm
    print(f"{n:9} word {w:08x} op1 {op1} CRn {crn} CRm {icrm} op2 {op2} Rt {rt}: ISS {iss:#08x} {'matches' if ok else 'DOES NOT MATCH'} LUC_SYS_CACHE({crm}) {kernel_match(crm):#08x}")
    bad += not ok
print("test-ucache:", "PASS" if bad == 0 else f"FAIL ({bad})")
sys.exit(1 if bad else 0)
PY

# laurel 3040: no printf in laurel_ucache_apply() before the guard `startup_phase >= STARTUP_SUB_TUNABLES` (the first call runs in
# arm_init() before the boot thread exists; a printf there hung the phone on 2026-11-07). The file as the series makes it: the new file
# of 2998, then 3040 on it. Every printf of the function must come after the guard, and the guard must be there.
U=$T/ucache; mkdir -p "$U/osfmk/arm64"
python3 -I - "$REPO/patches/laurel/xnu/2998-laurel-ucache.patch" "$U/osfmk/arm64/laurel_ucache.c" <<'PY'
import sys
out, take = [], False
for line in open(sys.argv[1]):
    if line.startswith('+++ b/osfmk/arm64/laurel_ucache.c'): take = True; continue
    if take and line.startswith('diff --git'): break
    if take and line.startswith('+') and not line.startswith('+++'): out.append(line[1:])
open(sys.argv[2], 'w').write(''.join(out))
PY
(cd "$U" && patch -p1 -s < "$REPO/patches/laurel/xnu/3040-laurel-ucache-line-after-boot-thread.patch") || { echo "test-ucache: FAIL: 3040 does not apply on the file of 2998"; exit 1; }
python3 -I - "$U/osfmk/arm64/laurel_ucache.c" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
m = re.search(r'\nlaurel_ucache_apply\(void\)\n\{(.*?)\n\}\n', s, re.S)
assert m, 'no laurel_ucache_apply'
body = m.group(1)
guard = body.find('startup_phase >= STARTUP_SUB_TUNABLES')
prints = [p.start() for p in re.finditer(r'\bprintf\(', body)]
early = [p for p in prints if guard < 0 or p < guard]
print(f"laurel_ucache_apply: {len(prints)} printf, guard at {guard}, {len(early)} before the guard")
if guard < 0 or early:
    print("test-ucache: FAIL (3040: a printf before the boot thread exists)"); sys.exit(1)
print("test-ucache (3040 guard): PASS")
PY
