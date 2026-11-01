#!/bin/sh
# Host test of XNUtils' data path (macOS and Linux, under 2 s, foreground): the kernel table of patch 2911 + the report sections.
#   scripts/laurel/xnutils-test.sh [LOG]      LOG: a real console log (logs/laurel-boot-*.txt); default the sample in the repo
# laurel_stats_core.h comes from the patch: the test checks the code that goes into the kernel. Built with ASan + UBSan.
# Checks: the sample's numbers reach their rows; 14+ digit runs are masked at any cut of the input; no row invents a value.
set -eu
. "$(dirname "$0")/../lib/env.sh"
P=$REPO/patches/laurel/xnu/2911-laurel-stats.patch
S=$REPO/userland/laurel/xnutils
D=$OUT/laurel/xnutils-test
rm -rf "$D"; mkdir -p "$D"
for f in laurel_stats_core.h laurel_stats_lines.h; do
  awk -v f="+++ b/bsd/dev/$f" '$0 == f {p=1; next}
       p && /^diff / {exit}
       p && /^@@/ {next}
       p && /^\+/ {print substr($0, 2)}' "$P" > "$D/$f"
  [ -s "$D/$f" ] || { echo "xnutils-test: no $f in $P" >&2; exit 1; }
done
${CC:-cc} -g -O1 -Wall -Wextra -Wno-unused-parameter -fsanitize=address,undefined -fno-sanitize-recover=undefined -I"$D" -I"$S" -o "$D/host_main" \
  "$S/test/host_main.c" "$S/report_core.c" "$S/report_row.c" "$S/report_gfx.c" "$S/report_sys.c" "$S/report_io.c"
LOG=${1:-$S/test/sample.log}
export ASAN_OPTIONS=detect_leaks=0     # the test tool keeps its buffers until it exits
"$D/host_main" "$LOG" "$S/test/sample.kv" --plain > "$D/report.txt"
"$D/host_main" "$LOG" "$S/test/sample.kv" --chunk 7 --plain > "$D/report-cut.txt"
"$D/host_main" "$LOG" "$S/test/sample.kv" > "$D/report.tsv"
cmp "$D/report.txt" "$D/report-cut.txt" || { echo "xnutils-test: FAIL: the cut of the input changes the report" >&2; exit 1; }
fail=0
want() { grep -qF -- "$1" "$D/report.txt" || { echo "xnutils-test: FAIL: no '$1' in the report" >&2; fail=1; }; }
if [ "$LOG" = "$S/test/sample.log" ]; then
  want 'Busy: 41.2 %'
  want 'Frame time (last logged): 54.1 ms'
  want 'Measured core clock: 300 MHz while busy'
  want 'Pool free: 419 of 512 MB free in 7 ranges'
  want 'SMMU faults: 2, last: FSR'
  want 'FB owner refusals: 3'
  want 'Wake count: 5'
  want 'SIM 1: present'
  want 'SIM 2: absent'
  want 'Device SpringBoard: running, 1 opens; pipelines 6 compiled'
  want 'driverkitd: 1 times, last signal 9, ns 1 code 0x7: (none)'
  want 'syncdefaultsd: 2 times, last signal 6'
  want 'Frames: 30 in 1006 ms; 29.8 fps'
  want 'Rx rate: VHT MCS 7, 80 MHz, 325.0 Mbit/s'
  want 'Drops by reason: full 13000, link down 700'
  want 'Gold (A73): 1401 MHz, busy 31 %'
  want 'Address: 02:4c:41:33:42:54'
  want 'JEITA zone: 1: ICL 1500 mA'
  if grep -q 8991000123456789012 "$D/report.txt" "$D/report.tsv"; then echo "xnutils-test: FAIL: a long digit run in the report" >&2; fail=1; fi
  grep -qF '###################' "$D/report.txt" || { echo "xnutils-test: FAIL: the digit run is not masked" >&2; fail=1; }
fi
grep -c '^#	' "$D/report.tsv" | { read -r n; [ "$n" = 18 ] || { echo "xnutils-test: FAIL: $n sections, not 18" >&2; exit 1; }; }
[ "$(tail -1 "$D/report.tsv")" = "%" ] || { echo "xnutils-test: FAIL: no end mark" >&2; fail=1; }
awk -F'\t' '$1=="#" && NF!=4 {print "bad header: " $0; bad=1} $1=="=" && NF!=4 {print "bad row: " $0; bad=1} END {exit bad}' "$D/report.tsv" || fail=1
# The helper's file verbs, on a folder, as uid 0 of a user namespace: what the gate's and the wrapper's readers will find
if unshare -r true 2>/dev/null; then
  F=$D/phone
  mkdir -p "$F/private/var/db/negronimetal/strikes" "$F/System/Library/Extensions/NegroniMetal.bundle"
  : > "$F/private/var/db/negronimetal/strikes/SpringBoard"
  mkdir -p "$D/shim/sys"; cp "$S/test/shim_sysctl.h" "$D/shim/sys/sysctl.h"
  ${CC:-cc} -g -O1 -Wall -Wextra -Wno-unused-parameter -fsanitize=address,undefined -I"$D/shim" -I"$S" -I"$S/test" -DXT_ROOT="\"$F\"" -Dsyscall=xt_no_syscall \
    -include sys/types.h -include stdint.h -o "$D/helper" "$S/helper.c" "$S/helper_files.c" "$S/test/host_stubs.c" "$S/report_core.c" "$S/report_row.c" "$S/report_gfx.c" "$S/report_sys.c" "$S/report_io.c" 2>"$D/helper.log" || { cat "$D/helper.log"; exit 1; }
  h() { unshare -r "$D/helper" "$@"; }
  C=$F/private/var/db/negronimetal/clients L=$F/System/Library/Extensions/NegroniMetal.bundle/clients.local
  h metal all; [ "$(tail -1 "$C")" = "* -backboardd -mediaserverd" ] && cmp -s "$C" "$L" && ! head -1 "$C" | grep -q laurel-metal-gate || { echo "xnutils-test: FAIL: metal all" >&2; fail=1; }
  h metal off; [ -f "$F/private/var/db/negronimetal/off" ] || { echo "xnutils-test: FAIL: metal off" >&2; fail=1; }
  h metal probes; [ "$(tail -1 "$C")" = "metalprobe m2vtest carenderprobe layerprobe" ] && [ ! -e "$F/private/var/db/negronimetal/off" ] || { echo "xnutils-test: FAIL: metal probes" >&2; fail=1; }
  : > "$F/private/var/db/negronimetal/gate"
  h metal auto; head -1 "$C" | grep -q '^# laurel-metal-gate' && [ "$(tail -1 "$C")" = "metalprobe m2vtest carenderprobe layerprobe" ] && [ ! -e "$F/private/var/db/negronimetal/gate" ] || { echo "xnutils-test: FAIL: metal auto (the gate must see its mark)" >&2; fail=1; }
  h gl off; [ -f "$F/private/var/db/laurelgl/off" ] || { echo "xnutils-test: FAIL: gl off" >&2; fail=1; }
  h gl on; [ ! -e "$F/private/var/db/laurelgl/off" ] || { echo "xnutils-test: FAIL: gl on" >&2; fail=1; }
  [ "$(h strikes-clear)" = "STRIKES_CLEARED=1" ] && [ -z "$(ls "$F/private/var/db/negronimetal/strikes")" ] || { echo "xnutils-test: FAIL: strikes-clear" >&2; fail=1; }
  rc=0; h metal everything 2>/dev/null || rc=$?; [ $rc = 2 ] || { echo "xnutils-test: FAIL: a bad verb gives $rc, not 2" >&2; fail=1; }
  rc=0; "$D/helper" gl on 2>/dev/null || rc=$?; [ $rc = 5 ] || { echo "xnutils-test: FAIL: not root gives $rc, not 5" >&2; fail=1; }
  rc=0; h check >/dev/null || rc=$?; [ $rc = 3 ] || { echo "xnutils-test: FAIL: check without the sysctl gives $rc, not 3" >&2; fail=1; }
else
  echo "xnutils-test: note: no user namespace: the helper's file verbs not tested"
fi
[ $fail = 0 ] || exit 1
echo "xnutils-test: PASS ($(grep -c '^=	' "$D/report.tsv") rows, $(grep -c 'not available' "$D/report.tsv") not available; $D/report.txt)"
