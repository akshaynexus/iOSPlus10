#!/bin/bash
# Stage 3 of the native stack: CoreAnimation's pipelines through AIR -> SPIR-V (metal2vulkan crate) -> NIR -> our lowering -> ir3 for FD610, with no Vulkan, no Turnip, no drm-shim. The same harness as scripts/ios26/ir3-check.sh (userland/laurel/metal/tests/ca-pipelines.c), so the count is comparable: 141 of 154 on the default stack.
#   scripts/bg.sh nmn-ir3 scripts/laurel/native/ir3-native.sh [PLAN ...]     default: the 154-row plan and the real keys of the phone
# A pipeline made here says that the code exists, not that its pixels are right. NMN_POLICY=unsafe turns the translator's bounds checks off, to measure them.
# Output: out/ios26/native/ir3/<plan>/{result.tsv,stats.tsv}.
set -euo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/metal-env.sh"
export METAL_OUT=$OUT/ios26/metal
. "$REPO/scripts/metal/env.sh"
H=$OUT/ios26/native/host
B=$OUT/ios26/native/mesa-host
FLAME=$MOUT/src/flame/phone/metal2/bridge
LIB=$OUT/ios26/metallib/Frameworks_QuartzCore.framework_default.metallib
OUTROOT=$OUT/ios26/native/ir3${NMN_POLICY:+-$NMN_POLICY}
mkdir -p "$OUTROOT"
M="$B/src/compiler/spirv/libvtn.a $B/src/compiler/nir/libnir.a $B/src/compiler/libcompiler.a $B/src/freedreno/ir3/libfreedreno_ir3.a $B/src/freedreno/isa/libir3decode.a $B/src/freedreno/isa/libir3encode.a $B/src/compiler/isaspec/libisaspec.a $B/src/freedreno/common/libfreedreno_common.a $B/src/freedreno/fdl/libfreedreno_layout.a $B/src/util/libmesa_util.a $B/src/util/blake3/libblake3.a $B/src/c11/impl/libmesa_util_c11.a $B/src/util/libmesa_util_sse41.a"
EX=$OUTROOT/ca-pipelines
clang -O1 -g -Wall -I "$FLAME" "$REPO/userland/laurel/metal/tests/ca-pipelines.c" "$H/libnative_metal_native.a" "$H/libnmn_c.a" -Wl,--start-group $M -Wl,--end-group $(pkg-config --libs SPIRV-Tools-shared 2>/dev/null || echo -lSPIRV-Tools-shared) -lm -ldl -lpthread -lstdc++ -lz -o "$EX"
plans=${*:-$OUT/ios26/native/plans/ca-154.txt $OUT/ios26/native/plans/ca-real.txt}
export LIB EX NMN_STATS=1
one() {
  r=$1
  NMN_STAT_NAME=$(cut -f2 "$r" | cut -c1-120) "$EX" none "$r.cache" "$LIB" "$r" > "$r.out" 2> "$r.err" || echo "FAIL	$(cut -f2 "$r")	crash	exit $?: $(tail -1 "$r.err" | cut -c1-200)" >> "$r.out"
  rm -rf "$r.cache"
}
export -f one
for plan in $plans; do
  n=$(basename "$plan" .txt)
  W=$OUTROOT/$n
  rm -rf "$W"; mkdir -p "$W/rows"
  # the plan of the phone's keys names a vertex function "fixed_vert_lph", which QuartzCore's library does not have: 90 rows are refused for that on the default stack too. Here those rows take fixed_vert_lph_spc, so that the fragment keys are counted.
  split -l 1 -d -a 4 <(grep -v '^$' "$plan" | sed 's/\tfixed_vert_lph\t/\tfixed_vert_lph_spc\t/') "$W/rows/r"
  ls "$W"/rows/r???? | xargs -P "$NPROC" -n 1 bash -c 'one "$0"'
  for f in "$W"/rows/r????.out; do r=${f%.out}; grep -E '^(ok|FAIL)' "$f" | head -1 | sed "s#\$#\t$(cut -f2 "$r" | cut -c1-60)#"; done > "$W/result.tsv" || true
  cat "$W"/rows/r????.out | grep '^stat' > "$W/stats.tsv" || true
  cat "$W"/rows/r????.err | sort | uniq -c | sort -rn | head -40 > "$W/errors.txt" || true
  echo "$n: $(grep -c '^ok' "$W/result.tsv" || true) made, $(grep -c '^FAIL' "$W/result.tsv" || true) refused of $(wc -l < "$W/result.tsv")"
  rm -rf "$W/rows"
done
