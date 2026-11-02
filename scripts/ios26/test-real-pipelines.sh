#!/bin/bash
# The pipelines a phone really asked for, with their real keys (NMTL_DIR/cache/<process>/pipelines.log, copied by read-only SSH to DIR), through the phone's whole compiler chain for FD610 on this host:
# AIR -> metal2vulkan -> SPIR-V -> Turnip (spirv_to_nir, ir3). No GPU runs. Output: out/ios26/real-pipelines/{ca,rb}/{result.txt,ir3.log}, then one summary line per set, and
# the derivative instructions ir3 emits with a half register (`half-deriv`): ir3 gives dsx/dsy TYPE_F32 whatever the register holds.
#   scripts/bg.sh real-pipelines scripts/ios26/test-real-pipelines.sh DIR     METAL_OUT=DIR2: the tree of scripts/laurel/ios26-metal-build.sh (default out/ios26/metal)
set -euo pipefail
export PATH=$HOME/.cargo/bin:$PATH
. "$(cd "$(dirname "$0")/../laurel" && pwd)/metal-env.sh"
export METAL_OUT=${METAL_OUT:-$OUT/ios26/metal}
. "$REPO/scripts/metal/env.sh"
LOGS=${1:?usage: test-real-pipelines.sh DIR_WITH_PIPELINES_LOGS}
H=$OUT/ios26/turnip-host
A=$OUT/ios26/metallib
W=${REAL_OUT:-$OUT/ios26/real-pipelines}
[ -f "$H/libvulkan_freedreno.so" ] || { echo "real-pipelines: scripts/ios26/turnip-host.sh first" >&2; exit 1; }
mkdir -p "$W/ca" "$W/rb" "$A"
RB=$A/PrivateFrameworks_RenderBox.framework_default.metallib
IC=$A/PrivateFrameworks_IconRendering.framework_default.metallib
QC=$A/Frameworks_QuartzCore.framework_default.metallib
if [ ! -f "$RB" ] || [ ! -f "$IC" ] || [ ! -f "$QC" ]; then
  OS_DMG=${OS_DMG:-$HOME/op10-apple/ios26/23F84-n104ap/os/094-55773-107.dmg}
  MNT=$OUT/ios26/mnt/os
  mkdir -p "$MNT"
  mountpoint -q "$MNT" || apfs-fuse -o ro "$OS_DMG" "$MNT"
  trap 'fusermount3 -u "$MNT" 2>/dev/null || true' EXIT
  python3 -I "$REPO/scripts/ios26/metallib-air.py" "$MNT/root/System/Library/PrivateFrameworks/RenderBox.framework/default.metallib" "$RB"
  python3 -I "$REPO/scripts/ios26/metallib-air.py" "$MNT/root/System/Library/PrivateFrameworks/IconRendering.framework/default.metallib" "$IC"
  python3 -I "$REPO/scripts/ios26/metallib-air.py" "$MNT/root/System/Library/Frameworks/QuartzCore.framework/default.metallib" "$QC"
fi
B=$MOUT/bridge/linux/libnative_metal_bridge.a
FLAME_DIR=$MOUT/src/flame/phone/metal2/bridge
if [ ! -f "$B" ] || [ -n "$(find "$FLAME_DIR" "$M2V/crates" -newer "$B" -name '*.rs' -print -quit)" ]; then
  BRIDGE_TARGET_DIR=$MOUT/bridge-linux-target "$REPO/scripts/metal/build-bridge.sh" linux
fi
clang -O1 -Wall -I "$FLAME_DIR" "$REPO/userland/laurel/metal/tests/ca-pipelines.c" "$B" -lm -ldl -lpthread -lstdc++ -o "$W/ca-pipelines"
python3 -I "$REPO/scripts/ios26/real-plan.py" ca "$LOGS"/backboardd.pipelines.log > "$W/ca/plan.txt"
python3 -I "$REPO/scripts/ios26/real-plan.py" rb "$LOGS"/SpringBoard.pipelines.log "$LOGS"/iconservicesagent.pipelines.log "$LOGS"/Spotlight.pipelines.log | sed "s|@IC@|$IC|" > "$W/rb/plan.txt"
export VK_ICD_FILENAMES=$H/icd.json VK_DRIVER_FILES=$H/icd.json
export TU_DEBUG=noconform,nocache FD_GPU_ID=610 IR3_SHADER_DEBUG=disasm
for set in ca rb; do
  case $set in ca) L=$QC ;; rb) L=$RB ;; esac
  rm -rf "$W/$set/cache"
  LD_PRELOAD=$H/libfreedreno_noop_drm_shim.so "$W/ca-pipelines" libvulkan.so.1 "$W/$set/cache" "$L" "$W/$set/plan.txt" > "$W/$set/result.txt" 2> "$W/$set/ir3.log" || true
  grep -E '^ca-pipelines' "$W/$set/result.txt" | sed "s/^/$set: /"
  grep -E '^FAIL' "$W/$set/result.txt" | cut -f2- | cut -c1-200 | sort | uniq -c | sort -rn | head -8 || true
  python3 -I "$REPO/scripts/ios26/half-deriv.py" "$W/$set/ir3.log" | tail -n 25
done
