#!/bin/bash
# CoreAnimation's APL kernels on the phone's chain for FD610, on this host, no GPU: threadgroup size and threadgroup memory as CA::OGL::MetalContext::compute_surface_apl_dimming_factor takes them (23F84): threadExecutionWidth x (maxTotal / width), 16 bytes per thread.
# Control: 32 x 32 (the runtime's maxTotal 1024) must give the refusal of boot 16 to the byte. With the frontend's answer (laurel_rules.h): the dispatch is encoded.
#   scripts/bg.sh ca-compute scripts/ios26/test-ca-compute.sh     Input: test-real-pipelines.sh ran once (host bridge, metallibs, turnip-host). Exit 0: every line as expected.
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
clang -O1 -Wall -I "$MOUT/src/flame/phone/metal2/bridge" "$REPO/userland/laurel/metal/tests/ca-pipelines.c" "$B" -lm -ldl -lpthread -lstdc++ -o "$W/ca-pipelines"
for k in compute_apl sum_apl_and_compute_dimming_factor; do printf 'D\t%s\t-\t32,32,16;0,0,16\n' "$k"; done > "$W/plan.txt"
rm -rf "$W/cache"
VK_ICD_FILENAMES=$H/icd.json VK_DRIVER_FILES=$H/icd.json TU_DEBUG=noconform,nocache FD_GPU_ID=610 LD_PRELOAD=$H/libfreedreno_noop_drm_shim.so "$W/ca-pipelines" libvulkan.so.1 "$W/cache" "$QC" "$W/plan.txt" > "$W/result.txt" 2> "$W/log.txt" || true
grep -E '^(kernel|dispatch|FAIL)' "$W/result.txt" | cut -c1-210
fail=0
for k in compute_apl sum_apl_and_compute_dimming_factor; do
  grep -qP "^kernel\t$k\tmax=1024\tanswer=512\twidth=32\tshared=16384" "$W/result.txt" || { echo "ca-compute: $k: not the answer 512"; fail=1; }
  grep -qP "^dispatch\t$k\t32,32,16\t.*limit: MaxComputeSharedMemorySize, required: 20480, available: 16384" "$W/result.txt" || { echo "ca-compute: $k: the control does not give the phone's refusal"; fail=1; }
  grep -qP "^dispatch\t$k\t32,16,16\tok" "$W/result.txt" || { echo "ca-compute: $k: the answer is refused"; fail=1; }
done
[ $fail = 0 ] && echo "ca-compute: PASS"
exit $fail
