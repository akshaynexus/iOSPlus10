#!/bin/bash
# Mi A3 iOS 26: the CPU cost of encoding on the default stack, with no phone: real metal2vulkan runtime + bridge + real Turnip (FD610) on Mesa's drm-shim, on this host's CPU.
#   scripts/bg.sh encode-bench scripts/laurel/ios26-encode-bench.sh [build|run|all] [DRAWS,FRAMES]      default all 200,300
# Result: logs/encode-bench.txt: us per draw, per pass end, per commit; self time by function, by the inlined function too. A host number is for compare before/after only; the phone's cost is larger.
# METAL_OUT default out/ios26/metal-impl: the tree of the phone's build, with its patches. Env passes to the run (NEGRONIMETAL_QOS=0 and others).
# NMN_SCENE_BENCH_SPIN=US (env): a spin of US us after each draw stands in for the program's own work between draws (CoreAnimation's). The A/B of the lowering thread (flame-ios26/0007, NEGRONIMETAL_LOWERING=0) needs it: the thread overlaps with that work only; with no spin the main thread waits for the thread (512 calls ahead at most) and the draw cost reads the thread's rate.
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/metal-env.sh"
export METAL_OUT=${METAL_OUT:-$OUT/ios26/metal-impl}
. "$REPO/scripts/metal/env.sh"
what=${1:-all}; spec=${2:-200,300}
W=$OUT/ios26/encode-bench
T=$OUT/ios26/turnip-host
B=$MOUT/bridge/linux/libnative_metal_bridge.a
FLAME=$MOUT/src/flame/phone/metal2/bridge
LIB=$OUT/ios26/metallib/Frameworks_QuartzCore.framework_default.metallib/default.metallib
[ -f "$LIB" ] || LIB=$(find "$OUT/ios26/metallib/Frameworks_QuartzCore.framework_default.metallib" -maxdepth 1 -type f | head -1)
mkdir -p "$W" "$REPO/logs"
if [ "$what" != run ]; then
  # the phone's flags: fat LTO, one codegen unit (ios26-metal-build.sh)
  CARGO_PROFILE_RELEASE_LTO=fat CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1 BRIDGE_TARGET_DIR=$MOUT/bridge-linux-target "$REPO/scripts/metal/build-bridge.sh" linux
fi
clang -O1 -g -Wall -I "$FLAME" "$REPO/userland/laurel/metal-native/tests/scene.c" "$B" -lm -ldl -lpthread -lstdc++ -o "$W/scene-default"
[ "$what" != build ] || exit 0
cat > "$W/icd.json" <<JSON
{ "ICD": { "api_version": "1.3.0", "library_path": "$T/libvulkan_freedreno.so" }, "file_format_version": "1.0.0" }
JSON
cd "$W"
export VK_ICD_FILENAMES=$W/icd.json VK_DRIVER_FILES=$W/icd.json TU_DEBUG=noconform,nocache FD_GPU_ID=610 NMN_SCENE_BENCH=$spec NMN_SCENE_BENCH_PCS=$W/pcs.txt
LD_PRELOAD=$T/libfreedreno_noop_drm_shim.so ./scene-default libvulkan.so.1 "$W/cache" "$LIB" > "$W/run.log" 2>&1 || { echo "encode-bench: scene exit $?"; tail -5 "$W/run.log"; exit 1; }
{ grep -E '^(bench|FAIL)' "$W/run.log"; python3 -I "$REPO/scripts/laurel/ios26-encode-bench.py" "$W/pcs.txt" "$W/scene-default"; } | tee "$REPO/logs/encode-bench${BENCH_NAME:+-$BENCH_NAME}.txt"
