#!/bin/bash
# GPU levels of the Mi A3 (patch 2961), host only, quick:
#  1. the table in laurel_gpu_opp.h against the stock source and the phone's stock DTB: rate, bus level, CX corner, PLL, L, alpha, VCO, iPeak.
#  2. tools/gpu-opp-test: the real text of the header, with a fake clock block: the order of the votes, each failure, the governor, the thermal rule.
#  3. controls: with no CX vote or with the CX vote after the clock, step 2 must fail.
# Exit 0: PASS. The stock source: external/laurel-kernel-los (main checkout too); the DTB: ~/laurel-backup/stock/images/boot.img. No source: that part says SKIP.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
P=$REPO/patches/laurel/xnu/2961-laurel-gpu-opp.patch
python3 -I - "$P" "$W/laurel_gpu_opp.h" <<'PY'
import sys
out=[]; inside=False
for l in open(sys.argv[1]):
    if l.startswith('diff '): inside=l.rstrip().endswith('b/iokit/Kernel/arm/laurel_gpu_opp.h')
    elif inside and l.startswith('+') and not l.startswith('+++'): out.append(l[1:])
assert out, 'no laurel_gpu_opp.h in the patch'
open(sys.argv[2],'w').writelines(out)
PY
MAIN=$(git -C "$REPO" worktree list --porcelain | sed -n '1s/^worktree //p')
K=$REPO/external/laurel-kernel-los; [ -e "$K/drivers/clk/qcom/gpucc-trinket.c" ] || K=$MAIN/external/laurel-kernel-los
python3 -I "$REPO/tools/gpu-opp-test/check-table.py" "$W/laurel_gpu_opp.h" "$K" "$HOME/laurel-backup/stock/images/boot.img" "$HOME/laurel-backup/stock/images/dtbo.img"
CXX=${CXX:-c++}
build() { "$CXX" -std=c++17 -Wall -Wextra -Wno-unused-function -I"$1" "$REPO/tools/gpu-opp-test/test.cpp" -o "$2"; }
build "$W" "$W/t"
"$W/t"
control() {  # NAME OLD NEW: the test must fail on this change of the header
  mkdir -p "$W/c"
  python3 -I - "$W/laurel_gpu_opp.h" "$W/c/laurel_gpu_opp.h" "$2" "$3" <<'PY'
import sys
s=open(sys.argv[1]).read(); assert sys.argv[3] in s, 'control text is gone: '+sys.argv[3]
open(sys.argv[2],'w').write(s.replace(sys.argv[3],sys.argv[4]))
PY
  build "$W/c" "$W/c/t"
  if "$W/c/t" > "$W/c/log"; then echo "control $1: the test did not see it"; exit 1; fi
  echo "ok    control $1: $(grep -m1 FAIL "$W/c/log" | cut -c1-110)"
}
control no-cx-vote 'if (c > st->cx) {' 'if (false && c > st->cx) {'
control no-ipeak 'if (t->ipeak && !st->ipeak) {' 'if (false && t->ipeak && !st->ipeak) {'
control rail-stays 'if (c < st->cx) {' 'if (false && c < st->cx) {'
control lost-ack 'st->cx = ops->cx(c) ? c : 0;' 'if (ops->cx(c)) { st->cx = c; }'
control no-ipeak-rule 'return o->ipeak && !feature;' 'return false;'
control running-pll 'ops->pll_off(t->pll);
		if (!ops->pll_on(t)) {' 'if (!ops->pll_on(t)) {'
echo "test-gpu-opp: PASS"
