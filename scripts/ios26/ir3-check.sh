#!/bin/bash
# CoreAnimation's 23F84 shaders through the whole compiler chain of the phone, on this host, for FD610: AIR -> metal2vulkan -> SPIR-V -> Turnip (spirv_to_nir, ir3) -> A610 code.
# No GPU runs. A pass says the pipeline is made, nothing about its pixels. Input: scripts/ios26/metal-corpus.sh ui, scripts/ios26/turnip-host.sh.
#   scripts/bg.sh ios26-ir3 scripts/ios26/ir3-check.sh [LIB]        LIB default Frameworks_QuartzCore.framework_default.metallib
# Output: out/ios26/ir3/<LIB>/{plan.txt,result.tsv,stats.tsv}. Exit 0 when the run ends; the refusals are in result.tsv.
set -euo pipefail
. "$(cd "$(dirname "$0")/../laurel" && pwd)/metal-env.sh"
. "$REPO/scripts/metal/env.sh"
lib=${1:-Frameworks_QuartzCore.framework_default.metallib}
C=$OUT/ios26/metal-corpus/ui/$lib
[ -f "$C/results.tsv" ] || C=$OUT/ios26/metal-corpus/all/$lib
A=$OUT/ios26/metallib/$lib
H=$OUT/ios26/turnip-host
W=$OUT/ios26/ir3/$lib
[ -f "$C/results.tsv" ] || { echo "ir3-check: no $C/results.tsv (scripts/ios26/metal-corpus.sh)" >&2; exit 1; }
[ -f "$H/libvulkan_freedreno.so" ] || { echo "ir3-check: scripts/ios26/turnip-host.sh first" >&2; exit 1; }
mkdir -p "$W"
B=$MOUT/bridge/linux/libnative_metal_bridge.a
FLAME_DIR=$MOUT/src/flame/phone/metal2/bridge
if [ ! -f "$B" ] || [ -n "$(find "$FLAME_DIR" -newer "$B" -name 'NativeMetal*' -print -quit)" ]; then
  BRIDGE_TARGET_DIR=$MOUT/bridge-linux-target "$REPO/scripts/metal/build-bridge.sh" linux
fi
clang -O1 -Wall -I "$FLAME_DIR" "$REPO/userland/laurel/metal/tests/ca-pipelines.c" "$B" -lm -ldl -lpthread -lstdc++ -o "$W/ca-pipelines"
python3 -I "$REPO/scripts/ios26/ir3-plan.py" "$C" > "$W/plan.txt"
export VK_ICD_FILENAMES=$H/icd.json VK_DRIVER_FILES=$H/icd.json
# noconform: on Linux Turnip 0102 is off (Darwin only); this is what 0102 answers. IR3_SHADER_DEBUG=disasm: code + statistics per variant.
export TU_DEBUG=noconform,nocache FD_GPU_ID=610 IR3_SHADER_DEBUG=disasm
export LD_PRELOAD_SHIM=$H/libfreedreno_noop_drm_shim.so
# one process per pipeline, because metal2vulkan compiles on its own threads: a log with one pipeline is one pipeline's statistics
rm -rf "$W/rows"; mkdir -p "$W/rows"
split -l 1 -d -a 4 <(grep -v '^$' "$W/plan.txt") "$W/rows/r"
one() {
  r=$1
  LD_PRELOAD=$LD_PRELOAD_SHIM "$W/ca-pipelines" libvulkan.so.1 "$r.cache" "$A" "$r" > "$r.out" 2> "$r.log" || echo "FAIL	$(cut -f2 "$r")	crash	exit $?" >> "$r.out"
  python3 -I "$REPO/scripts/ios26/ir3-stats.py" "$r.log" | tail -n +2 > "$r.stats"
  rm -rf "$r.cache" "$r.log"
}
export -f one; export W A REPO
ls "$W"/rows/r???? | xargs -P "$NPROC" -n 1 bash -c 'one "$0"'
cat "$W"/rows/r????.out | grep -E '^(ok|FAIL)' > "$W/result.tsv"
grep -h -E '^answer ' "$W"/rows/r0000.out > "$W/answers.txt" || true
{ printf 'pipeline\tstage\tinstr\tnops\tmov\tcov\tdwords\thalf\tfull\tconstlen\tcat5\tcat6\tsstall\tsystall\tloops\n'; cat "$W"/rows/r????.stats; } > "$W/stats.tsv"
rm -rf "$W/rows"
echo "ir3-check: $(grep -c '^ok' "$W/result.tsv") made, $(grep -c '^FAIL' "$W/result.tsv") refused"
wc -l "$W/stats.tsv"
