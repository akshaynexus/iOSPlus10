#!/bin/bash
# The 23F84 system shaders through metal2vulkan for the Adreno 610's Vulkan profile, on the host (no phone, no GPU): AIR -> SPIR-V + spirv-val, per function.
# It shows what the translator gives, not what Turnip's ir3 does with the SPIR-V (that step is scripts/ios26/ir3-check.sh).
#   scripts/bg.sh ios26-metal-corpus scripts/ios26/metal-corpus.sh [ui|all]     ui = what the compositor and SpringBoard load (default), all = every metallib of the tree
# Input: ~/op10-apple/ios26/23F84-n104ap/tree (Apple files, never in git); out/metal/src from scripts/metal/fetch-sources.sh (or IOS26_METAL_OUT).
# Output: out/ios26/metal-corpus/<set>/{libs.tsv,summary.txt,<lib>/results.tsv}; the extracted AIR stays in out/ios26/metallib (git-ignored).
set -euo pipefail
. "$(cd "$(dirname "$0")/../laurel" && pwd)/metal-env.sh"
. "$REPO/scripts/metal/env.sh"
laurel_metal_tools
set_name=${1:-ui}
T=${IOS26_TREE:-$HOME/op10-apple/ios26/23F84-n104ap/tree}
A=$OUT/ios26/metallib
C=$OUT/ios26/metal-corpus/$set_name
mkdir -p "$A" "$C" "$OUT/metal/profiles"
[ "$(df -Pk "$C" | awk 'NR==2 {print int($4 / 1048576)}')" -ge 50 ] || { echo "metal-corpus: less than 50 GiB free" >&2; exit 3; }
PROFILE=$OUT/metal/profiles/a610-turnip-est.json
python3 -I "$REPO/scripts/laurel/a610-profile.py" "$M2V/crates/metal2vulkan-validation/profiles/vk12-floor.json" "$PROFILE"
# the host CLI (once per metal2vulkan commit + patches), as scripts/metal/shader-corpus-test.sh
CLI=${M2V_CLI:-$MOUT/bin/metal2vulkan}
if [ ! -x "$CLI" ]; then
  cargo "+$RUST_TOOLCHAIN" build --release --manifest-path "$M2V/Cargo.toml" -p metal2vulkan --features cli --bin metal2vulkan \
    --target-dir "$MOUT/m2v-host" -j "$NPROC"
  mkdir -p "$MOUT/bin" && cp "$MOUT/m2v-host/release/metal2vulkan" "$CLI"
fi
case $set_name in
ui) L="QuartzCore.framework/default.metallib" ;;
all) L="" ;;
*) echo "usage: $0 [ui|all]" >&2; exit 2 ;;
esac
list=$C/libs.tsv; : > "$list"
(cd "$T/root" && find os sys -name '*.metallib' 2>/dev/null) | sort | while read -r rel; do
  case $set_name in ui) case $rel in sys/*/Frameworks/QuartzCore.framework/*|os/*RenderBox*|os/*IconRendering*|os/*MercuryPoster*|os/*CoreUI*) ;; *) continue ;; esac ;; esac
  n=$(echo "$rel" | sed 's#^[a-z]*/##; s#System/Library/##; s#[/ ]#_#g')
  if line=$(python3 -I "$REPO/scripts/ios26/metallib-air.py" "$T/root/$rel" "$A/$n"); then
    printf '%s\tAIR\t%s\n' "$n" "$rel" >> "$list"
  else
    printf '%s\tAGX-only\t%s\n' "$n" "$rel" >> "$list"
  fi
  echo "$line"
done
: > "$C/summary.txt"
while IFS=$'\t' read -r n kind rel; do
  [ "$kind" = AIR ] || continue
  M2V_CLI=$CLI TRANSLATE_DIR=$C OUTNAME=$n "$REPO/scripts/metal/host-translate.sh" "$A/$n" "$PROFILE" > "$C/$n.log" 2>&1 || echo "metal-corpus: $n: host-translate exit $?" | tee -a "$C/summary.txt"
  r=$C/$n/results.tsv
  [ -f "$r" ] || continue
  for k in kernel vertex fragment; do
    printf '%s %s: %s of %s\n' "$n" "$k" "$(awk -F'\t' -v k=$k '$1==k && $3 ~ /^PASS/' "$r" | wc -l)" "$(awk -F'\t' -v k=$k '$1==k' "$r" | wc -l)" | tee -a "$C/summary.txt"
  done
  find "$C/$n" -type f ! -name 'results.tsv' ! -name '*.fc' ! -name '*.ca' ! -name 'functions.txt' ! -name '*.vd.json' -delete
done < "$list"
echo "metal-corpus: $C/summary.txt"
