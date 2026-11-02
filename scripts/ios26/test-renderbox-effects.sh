#!/bin/bash
# RenderBox's custom effects of 23F84 through the phone's whole compiler chain, on this host, for FD610: the stage of RenderBox's default.metallib + the effect of IconRendering's default.metallib,
# linked as custom_fn (RB::Device::RenderPipelineEntry::Loader::load_custom_fn sets specializedName @"custom_fn"), AIR -> metal2vulkan -> SPIR-V -> Turnip (spirv_to_nir, ir3). No GPU runs: a pass says the pipeline is made, nothing about pixels.
# Control: the same pipeline with no specialized name must give the phone's refusal of boot 11: NeedsInput(LinkedFunction { symbol: "custom_fn" }).
#   scripts/bg.sh rb-effects scripts/ios26/test-renderbox-effects.sh     METAL_OUT=DIR: the tree of scripts/laurel/ios26-metal-build.sh (default out/ios26/metal)
# Input: scripts/ios26/turnip-host.sh; the OS image of 23F84 (apfs-fuse, read only, the metallibs stay in out/). Exit 0: every line as expected.
set -euo pipefail
export PATH=$HOME/.cargo/bin:$PATH
. "$(cd "$(dirname "$0")/../laurel" && pwd)/metal-env.sh"
export METAL_OUT=${METAL_OUT:-$OUT/ios26/metal}
. "$REPO/scripts/metal/env.sh"
H=$OUT/ios26/turnip-host
A=$OUT/ios26/metallib
W=$OUT/ios26/rb-effects
RB=$A/PrivateFrameworks_RenderBox.framework_default.metallib
IC=$A/PrivateFrameworks_IconRendering.framework_default.metallib
[ -f "$H/libvulkan_freedreno.so" ] || { echo "rb-effects: scripts/ios26/turnip-host.sh first" >&2; exit 1; }
mkdir -p "$W" "$A"
if [ ! -f "$RB" ] || [ ! -f "$IC" ]; then
  OS_DMG=${OS_DMG:-$HOME/op10-apple/ios26/23F84-n104ap/os/094-55773-107.dmg}
  MNT=$OUT/ios26/mnt/os
  mkdir -p "$MNT"
  mountpoint -q "$MNT" || apfs-fuse -o ro "$OS_DMG" "$MNT"
  trap 'fusermount3 -u "$MNT" 2>/dev/null || true' EXIT
  for n in RenderBox IconRendering; do
    python3 -I "$REPO/scripts/ios26/metallib-air.py" "$MNT/root/System/Library/PrivateFrameworks/$n.framework/default.metallib" "$A/PrivateFrameworks_$n.framework_default.metallib"
  done
fi
B=$MOUT/bridge/linux/libnative_metal_bridge.a
FLAME_DIR=$MOUT/src/flame/phone/metal2/bridge
if [ ! -f "$B" ] || [ -n "$(find "$FLAME_DIR" "$M2V/crates" -newer "$B" -name '*.rs' -print -quit)" ]; then
  BRIDGE_TARGET_DIR=$MOUT/bridge-linux-target "$REPO/scripts/metal/build-bridge.sh" linux
fi
clang -O1 -Wall -I "$FLAME_DIR" "$REPO/userland/laurel/metal/tests/ca-pipelines.c" "$B" -lm -ldl -lpthread -lstdc++ -o "$W/ca-pipelines"
# the three of boot 11, each with the phone's formats: colour 115, depth + stencil 260; the names of each stage from the log
# stage constant 0: uint4 (RB::Device::make_render_pipeline_descriptor: setConstantValue:type:0x24 atIndex:0 [V 23F84]); zeros stand in for the state bits
K=i0:36:0e0.0e0.0e0.0e0     # (e0: the plan's number reader takes "0.0" as one number)
TAB=$(printf '\t')
{
  for fx in clampToEdges_v1; do
    printf 'L%scustom_effect:%s%scustom_effect_vertex%scustom_effect_fragment%s115%s-%s%s%scustom_fn%s%s%s%s\n' "$TAB" "$fx" "$TAB" "$TAB" "$TAB" "$TAB" "$TAB" "$fx" "$TAB" "$TAB" "$IC" "$TAB" "$K"
  done
  for fx in glow_v1 simplifiedShapeAwareGradientMask_v1; do
    printf 'L%sprimitive_custom:%s%sprimitive_custom_vertex%sprimitive_custom_fragment%s115%s-%s%s%scustom_fn%s%s%s%s\n' "$TAB" "$fx" "$TAB" "$TAB" "$TAB" "$TAB" "$TAB" "$fx" "$TAB" "$TAB" "$IC" "$TAB" "$K"
  done
  printf 'L%scontrol-no-name%scustom_effect_vertex%scustom_effect_fragment%s115%s-%sclampToEdges_v1%s-%s%s%s%s\n' "$TAB" "$TAB" "$TAB" "$TAB" "$TAB" "$TAB" "$TAB" "$TAB" "$IC" "$TAB" "$K"
} > "$W/plan.txt"
export VK_ICD_FILENAMES=$H/icd.json VK_DRIVER_FILES=$H/icd.json
export TU_DEBUG=noconform,nocache FD_GPU_ID=610 IR3_SHADER_DEBUG=disasm
rm -rf "$W/cache"
LD_PRELOAD=$H/libfreedreno_noop_drm_shim.so "$W/ca-pipelines" libvulkan.so.1 "$W/cache" "$RB" "$W/plan.txt" > "$W/result.txt" 2> "$W/ir3.log" || true
grep -E '^(ok|FAIL|ca-pipelines)' "$W/result.txt" | cut -c1-240
python3 -I "$REPO/scripts/ios26/ir3-stats.py" "$W/ir3.log" | cut -f1-3 | head -20 || true
fail=0
for fx in custom_effect:clampToEdges_v1 primitive_custom:glow_v1 primitive_custom:simplifiedShapeAwareGradientMask_v1; do
  grep -q "^ok${TAB}$fx${TAB}" "$W/result.txt" || { echo "rb-effects: $fx is not made"; fail=1; }
done
grep -q "^FAIL${TAB}control-no-name${TAB}.*NeedsInput(LinkedFunction { symbol: \"custom_fn\" })" "$W/result.txt" || { echo "rb-effects: the control does not give the phone's refusal"; fail=1; }
[ $fail = 0 ] && echo "rb-effects: PASS"
exit $fail
