#!/bin/bash
# Reference for the native stack: the fixed scene (userland/laurel/metal-native/tests/scene.c) through the default stack: real metal2vulkan runtime + bridge + real Turnip for FD610 on Mesa's drm-shim, on this host. No GPU runs.
# Output: out/ios26/native/ref/{scene.log, *.rd, ref.txt (cffdump)}.   scripts/bg.sh nmn-ref scripts/laurel/native/ref-capture.sh
set -euo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/metal-env.sh"
export METAL_OUT=$OUT/ios26/metal
. "$REPO/scripts/metal/env.sh"
H=$OUT/ios26/native/mesa-host
W=$OUT/ios26/native/ref
B=$MOUT/bridge/linux/libnative_metal_bridge.a
FLAME=$MOUT/src/flame/phone/metal2/bridge
LIB=$OUT/ios26/metallib/Frameworks_QuartzCore.framework_default.metallib/default.metallib
[ -f "$LIB" ] || LIB=$(find "$OUT/ios26/metallib/Frameworks_QuartzCore.framework_default.metallib" -maxdepth 1 -type f | head -1)
# REF_ONLY=NAME: one more capture of the list below, and the others stay: pm4-actions.py's table is by index into the old captures
mkdir -p "$W"; [ -n "${REF_ONLY:-}" ] || rm -rf "$W"/*
TU=$(find "$H" -name libvulkan_freedreno.so | head -1)
SHIM=$(find "$H" -name libfreedreno_noop_drm_shim.so | head -1)
cat > "$W/icd.json" <<JSON
{ "ICD": { "api_version": "1.3.0", "library_path": "$TU" }, "file_format_version": "1.0.0" }
JSON
clang -O1 -g -Wall -I "$FLAME" "$REPO/userland/laurel/metal-native/tests/scene.c" "$B" -lm -ldl -lpthread -lstdc++ -o "$W/scene-default"
# Row numbers of the plan to capture on top of the plain scene: REF_ROWS="0 45". Two modes: autotune (what the phone runs) and TU_DEBUG=sysmem.
C=$(find "$H" -type f -name cffdump | head -1)
export RNN_PATH=$OUT/ios26/turnip-host/mesa/src/freedreno/registers
one() {
  name=$1; mode=$2; shift 2
  rm -f /tmp/tu_scene-default.*.rd
  (cd "$W"
   export VK_ICD_FILENAMES=$W/icd.json VK_DRIVER_FILES=$W/icd.json TU_DEBUG=noconform,nocache$mode FD_GPU_ID=610 FD_RD_DUMP=enable,full
   LD_PRELOAD=$SHIM ./scene-default libvulkan.so.1 "$W/cache-$name" "$LIB" "$@" > "$name.log" 2>&1 || echo "$name: scene exit $?")
  grep -E '^(scene|FAIL)' "$W/$name.log" | cut -c1-160
  local i=0
  for r in /tmp/tu_scene-default.*.rd; do
    [ -f "$r" ] || continue
    mv "$r" "$W/$name-$i.rd"
    "$C" "$W/$name-$i.rd" > "$W/$name-$i.txt" 2>&1 || true
    "$C" --summary "$W/$name-$i.rd" > "$W/$name-$i-summary.txt" 2>&1 || true
    i=$((i+1))
  done
  echo "$name: bins $(cat "$W/$name"-*.txt | grep -c 'RM6_BIN_RENDER_START\|mode: RM6_RENDER\|RM6_BIN_VISIBILITY' ) direct $(cat "$W/$name"-*.txt | grep -c RM6_DIRECT_RENDER) CP_DRAW $(cat "$W/$name"-*.txt | grep -c 'opcode: CP_DRAW')"
}
if [ "${REF_ONLY:-}" = depth-sysmem ]; then
  # Depth32Float_Stencil8: Turnip's registers for pm4-compare.sh
  NMN_SCENE_DEPTH=1 one depth-sysmem ,sysmem
  exit 0
fi
one plain-sysmem ,sysmem
one plain-auto ""
NMN_SCENE_DEPTH=1 one depth-sysmem ,sysmem
for row in ${REF_ROWS:-0}; do
  one "row$row-sysmem" ,sysmem "$OUT/ios26/native/plans/ca-real.txt" "$row"
  one "row$row-auto" "" "$OUT/ios26/native/plans/ca-real.txt" "$row"
done
ls -la "$W" | grep -c rd
