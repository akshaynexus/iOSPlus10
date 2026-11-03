#!/bin/bash
# RPM clock scaling of the Mi A3 (patch 2985), host only, quick:
#  1. laurel_rpm_scale.h against the stock source and the stock rpm.mbn: clocks, ids, keys, order, Gold table, DDR rows.
#  2. tools/rpm-scale-test: the real text of the header, with a fake RPM made from the firmware's rules: the order, each failure, the read.
#  3. controls: an Enab with a clock not voted, or in the wrong order, must fail step 2.
# Exit 0: PASS. No stock file: that part says SKIP. Nothing here proves that the phone follows: only the boot line does.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
P=$REPO/patches/laurel/xnu/2985-laurel-rpm-scale.patch
python3 -I - "$P" "$W/laurel_rpm_scale.h" <<'PY'
import sys
out=[]; inside=False
for l in open(sys.argv[1]):
    if l.startswith('diff '): inside=l.rstrip().endswith('b/iokit/Kernel/arm/laurel_rpm_scale.h')
    elif inside and l.startswith('+') and not l.startswith('+++'): out.append(l[1:])
assert out, 'no laurel_rpm_scale.h in the patch'
open(sys.argv[2],'w').writelines(out)
PY
MAIN=$(git -C "$REPO" worktree list --porcelain | sed -n '1s/^worktree //p')
K=$REPO/external/laurel-kernel-los; [ -e "$K/drivers/clk/qcom/clk-smd-rpm.c" ] || K=$MAIN/external/laurel-kernel-los
python3 -I "$REPO/tools/rpm-scale-test/check-table.py" "$W/laurel_rpm_scale.h" "$K" "$HOME/laurel-backup/stock/images/rpm.mbn"
CXX=${CXX:-c++}
build() { "$CXX" -std=c++17 -Wall -Wextra -Wno-unused-function -I"$1" "$REPO/tools/rpm-scale-test/test.cpp" -o "$2"; }
build "$W" "$W/t"
"$W/t"
control() {  # NAME OLD NEW: the test must fail on this change of the header
  mkdir -p "$W/c"
  python3 -I - "$W/laurel_rpm_scale.h" "$W/c/laurel_rpm_scale.h" "$2" "$3" <<'PY'
import sys
s=open(sys.argv[1]).read(); assert sys.argv[3] in s, 'control text is gone: '+sys.argv[3]
open(sys.argv[2],'w').write(s.replace(sys.argv[3],sys.argv[4]))
PY
  build "$W/c" "$W/c/t"
  if "$W/c/t" > "$W/c/log"; then echo "control $1: the test did not see it"; exit 1; fi
  echo "ok    control $1: $(grep -m1 FAIL "$W/c/log" | cut -c1-110)"
}
control no-bimc-first 'RS_KEY_KHZ, RS_BIMC_FIRST)' 'RS_KEY_KHZ, RS_TOP_KHZ)'
control active-first 'ops->write(RS_SET_SLEEP, RS_CLK0' 'ops->write(RS_SET_ACTIVE, RS_CLK0'
control sleep-set-missing '!ops->write(RS_SET_SLEEP, rs_clocks[i].type, rs_clocks[i].id, RS_KEY_KHZ, RS_TOP_KHZ)' 'false'
control enab-after-fail 'if (!ops->write(RS_SET_ACTIVE, rs_clocks[i].type, rs_clocks[i].id, RS_KEY_KHZ, RS_TOP_KHZ) ||' 'if ((ops->write(RS_SET_ACTIVE, rs_clocks[i].type, rs_clocks[i].id, RS_KEY_KHZ, RS_TOP_KHZ), false) ||'
control gold-row 'gold_mhz > 1804 ? 1804' 'gold_mhz > 1804 ? 1555'
echo "test-rpm-scale: PASS"
