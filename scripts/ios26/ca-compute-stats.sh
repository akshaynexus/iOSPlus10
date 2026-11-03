#!/bin/bash
# CoreAnimation's compute kernels on the phone's chain for FD610, on this host, no GPU: size and code of each (ir3). Docs: docs/laurel_sprout/ios26-default-speed.md.
#   scripts/ios26/ca-compute-stats.sh       Input: test-real-pipelines.sh ran once. Output: out/ios26/ca-compute/{result.txt,ir3.log}, one line per kernel.
set -euo pipefail
export PATH=$HOME/.cargo/bin:$PATH
. "$(cd "$(dirname "$0")/../laurel" && pwd)/metal-env.sh"
export METAL_OUT=${METAL_OUT:-$OUT/ios26/metal}
. "$REPO/scripts/metal/env.sh"
H=$OUT/ios26/turnip-host
QC=$OUT/ios26/metallib/Frameworks_QuartzCore.framework_default.metallib
W=$OUT/ios26/ca-compute
mkdir -p "$W"
B=$MOUT/bridge/linux/libnative_metal_bridge.a
clang -O1 -I "$MOUT/src/flame/phone/metal2/bridge" "$REPO/userland/laurel/metal/tests/ca-pipelines.c" "$B" -lm -ldl -lpthread -lstdc++ -o "$W/ca-pipelines"
for k in compute_apl sum_apl_and_compute_dimming_factor compute_apl_fast compute_average_luma compute_sum_luma variable_blur_downsample_compute variable_blur_copy_base_mip_compute read_write_surf_compute; do printf 'D\t%s\t-\t32,16,16;0,0,16\n' "$k"; done > "$W/plan.txt"
rm -rf "$W/cache"
VK_ICD_FILENAMES=$H/icd.json VK_DRIVER_FILES=$H/icd.json TU_DEBUG=noconform,nocache FD_GPU_ID=610 IR3_SHADER_DEBUG=disasm LD_PRELOAD=$H/libfreedreno_noop_drm_shim.so "$W/ca-pipelines" libvulkan.so.1 "$W/cache" "$QC" "$W/plan.txt" > "$W/result.txt" 2> "$W/ir3.log" || true
grep -E '^(kernel|dispatch|FAIL)' "$W/result.txt" | cut -c1-190
grep -E "; (CL|COMP[A-Z]*) prog [0-9]+/[0-9]+: [0-9]+ instr" "$W/ir3.log" | sed 's/MESA: info: //' | cut -c1-110
