#!/bin/bash
# The native stack's registers at the draw against Turnip's, on many real keys of the phone (a plan of scripts/ios26/real-plan.py): each row: Turnip's capture on drm-shim (sysmem), the native stream on the fake kernel, pm4-diff.py. A missing register shows only when a key needs it: the bindless prefetch's slot showed in no row of pm4-compare.sh, and hung the GPU.
#   scripts/bg.sh nmn-rows scripts/laurel/native/pm4-rows.sh PLAN STEP      every STEP-th row of the plan, and each distinct fragment function
# Output: out/ios26/native/rows/ROW-diff.txt; one line a row, then the registers that differ by count. Exit 1 on an unexpected difference. No GPU.
set -uo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/metal-env.sh"
export METAL_OUT=$OUT/ios26/metal
. "$REPO/scripts/metal/env.sh"
PLAN=$1; STEP=${2:-16}
H=$OUT/ios26/native/mesa-host
W=$OUT/ios26/native/rows; mkdir -p "$W"
N=$OUT/ios26/native/pm4
R=$OUT/ios26/native/ref
LIB=${LIB:-$OUT/ios26/metallib/Frameworks_QuartzCore.framework_default.metallib}
[ -f "$LIB" ] || LIB=$(find "$LIB" -maxdepth 1 -type f | head -1)
C=$(find "$H/" -type f -name cffdump | head -1)
SHIM=$(find "$H/" -name libfreedreno_noop_drm_shim.so | head -1)
export RNN_PATH=$OUT/ios26/turnip-host/mesa/src/freedreno/registers
[ -x "$R/scene-default" ] || { echo "pm4-rows: no $R/scene-default: scripts/laurel/native/ref-capture.sh"; exit 2; }
rows=${ROWS:-$(python3 -I -c '
import sys
seen=set(); out=[]
for i,l in enumerate(open(sys.argv[1])):
    f=l.split("\t")
    if len(f)<7: continue
    if f[3] not in seen or i % int(sys.argv[2])==0:
        seen.add(f[3]); out.append(i)
print(" ".join(map(str,out)))' "$PLAN" "$STEP")}
echo "rows: $rows"
rc=0; : > "$W/all-diff.txt"
for r in $rows; do
  rm -f /tmp/tu_scene-default.*.rd
  (cd "$R"; export VK_ICD_FILENAMES=$R/icd.json VK_DRIVER_FILES=$R/icd.json TU_DEBUG=noconform,nocache,sysmem FD_GPU_ID=610 FD_RD_DUMP=enable,full; LD_PRELOAD=$SHIM timeout 120 ./scene-default libvulkan.so.1 "$W/cache-ref" "$LIB" "$PLAN" "$r" > "$W/$r-ref.log" 2>&1)
  ref=$(ls -S /tmp/tu_scene-default.*.rd 2>/dev/null | sed -n 1p)
  # the file with the draw: the second capture of a run (0: device init)
  draw=$(ls /tmp/tu_scene-default.*.rd 2>/dev/null | sort | sed -n 2p)
  [ -n "$draw" ] || { echo "row $r: Turnip made no capture: $(grep -E 'FAIL' "$W/$r-ref.log" | cut -c1-120)"; continue; }
  "$C" --summary "$draw" > "$W/$r-ref-summary.txt" 2>&1 || true
  rm -f /tmp/tu_scene-default.*.rd
  NMN_SCENE_NO_SURFACES=1 NMN_RD=$W/$r.rd timeout 120 "$N/scene-native" none "$W/cache" "$LIB" "$PLAN" "$r" > "$W/$r.log" 2>&1 || { echo "row $r: native: $(grep -E 'FAIL' "$W/$r.log" | cut -c1-140)"; continue; }
  "$C" --summary "$W/$r.rd" > "$W/$r-summary.txt" 2>&1 || true
  python3 -I "$REPO/scripts/laurel/native/pm4-diff.py" "$W/$r-ref-summary.txt" "$W/$r-summary.txt" > "$W/$r-diff.txt" 2>&1 || rc=1
  name=$(sed -n $((r + 1))p "$PLAN" | cut -f3,4 | tr '\t' '+')
  echo "row $r $name: $(grep -m1 UNEXPECTED "$W/$r-diff.txt" | cut -c1-80)"
  grep -E '^DIFF' "$W/$r-diff.txt" >> "$W/all-diff.txt"
done
echo "--- registers that differ, by rows"
sed -E 's/^DIFF +([A-Za-z0-9_\[\]x.]+):.*/\1/' "$W/all-diff.txt" | sort | uniq -c | sort -rn | head -40
exit $rc
