#!/bin/bash
# Host check of the shader path (no phone, no GPU): translate a metallib's functions with the metal2vulkan CLI
# (AIR -> SPIR-V, checked by spirv-val when it is on PATH) for a Vulkan device profile.
#   scripts/metal/host-translate.sh [METALLIB] [PROFILE_JSON]
#     METALLIB  default: QuartzCore's default.metallib of the attached 20H392 root (out/metal/rootmnt)
#     PROFILE   default: metal2vulkan's vk12-floor profile (a bare Vulkan 1.2 device). Replace it with the A730's
#               profile once vkprobe/vulkaninfo gives one (docs/metal-design.md "Device profile").
# Per function: kernels and vertex functions alone; each fragment with the vertex functions until one links.
# Output: out/metal/translate/<lib>/{results.tsv,summary.txt,*.spv}. Builds the CLI on first use.
# Run in tmux: scripts/bg.sh metal-translate scripts/metal/host-translate.sh
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/env.sh"
LIB=${1:-$MOUT/rootmnt/System/Library/Frameworks/QuartzCore.framework/default.metallib}
PROFILE=${2:-$M2V/crates/metal2vulkan-validation/profiles/vk12-floor.json}
CLI=$MOUT/m2v-host/release/metal2vulkan
if [ ! -x "$CLI" ]; then
  cargo "+$RUST_TOOLCHAIN" build --release --manifest-path "$M2V/Cargo.toml" -p metal2vulkan --features cli \
    --bin metal2vulkan --target-dir "$MOUT/m2v-host" -j "$NPROC"
fi
name=$(basename "$(dirname "$LIB")" .framework)_$(basename "$LIB" .metallib)
T=$MOUT/translate/$name
rm -rf "$T" && mkdir -p "$T"
python3 -I "$REPO/scripts/metal/metallib-info.py" "$LIB" | tail -n +2 | awk '{print $1, $2}' > "$T/functions.txt"
export METAL2VULKAN_REPRO_DIR=$T/repros
# CA supplies vertex descriptors at pipeline creation; on the host each attribute the compile asks for gets a
# 16-byte slot in buffer 29 (formats tried in order until the attribute's type accepts one). This tests the
# translation of the shader bodies, not CA's real layouts.
cat > "$T/vd.py" <<'PY'
import json, re, sys
# vd.py FILE ERRORTEXT: add or change the attribute the error names; exit 1 when there is nothing left to try
path, err = sys.argv[1], sys.argv[2]
formats = ["Float4", "UInt4", "Int4", "Half4", "UChar4Normalized"]
try:
    d = json.load(open(path))
except Exception:
    d = {"layouts": {"29": {"stride": 256, "step_function": "PerVertex", "step_rate": 1}}, "attributes": {}}
m = re.search(r"VertexAttribute \{ attribute: (\d+) \}", err)
if not m:
    sys.exit(1)
a = m.group(1)
attrs = d["attributes"]
if a in attrs:
    i = formats.index(attrs[a]["format"]) + 1
    if i >= len(formats):
        sys.exit(1)
    attrs[a]["format"] = formats[i]
else:
    if len(attrs) >= 16:
        sys.exit(1)
    attrs[a] = {"format": formats[0], "offset": 16 * len(attrs), "buffer_index": 29}
json.dump(d, open(path, "w"))
PY
one() { # kind name [fragment]: compile; vertex functions grow their descriptor in $T/<vertex>.vd.json
  local kind=$1 fn=$2 frag=${3:-} out log vd=$T/$2.vd.json args
  for _ in $(seq 1 40); do
    if [ -n "$frag" ]; then out=$T/$frag.spv; log=$T/$frag.log; else out=$T/$fn.spv; log=$T/$fn.log; fi
    args=(--profile "$PROFILE" --function "$fn")
    [ -n "$frag" ] && args+=(--fragment "$frag" --color-format 0:BGRA8Unorm)
    [ -f "$vd" ] && args+=(--vertex-descriptor "$vd")
    "$CLI" "$LIB" "$out" "${args[@]}" > "$log" 2>&1 && return 0
    [ "$kind" = kernel ] && return 1
    [ -n "$frag" ] && return 1           # the vertex descriptor is already complete from the vertex run
    python3 -I "$T/vd.py" "$vd" "$(cat "$log")" || return 1
  done
  return 1
}
export -f one; export CLI LIB PROFILE T
# kernels + vertex functions, in parallel
awk '$1=="kernel"||$1=="vertex"{print $1, $2}' "$T/functions.txt" |
  xargs -P "$NPROC" -n 2 bash -c 'if one "$0" "$1"; then echo "$0	$1	PASS"; else echo "$0	$1	$(grep -o "FALLBACK.*" "$T/$1.log" | head -1 | cut -c1-200)"; fi' > "$T/results.tsv" || true
# fragments: pair with each vertex function that translated (same precision suffix first) until one links
frag_pair() {
  local f=$1 suf=${1##*_} v last="" order=()
  for v in $verts; do [[ $v == *_"$suf" ]] && order+=("$v"); done
  for v in $verts; do [[ $v == *_"$suf" ]] || order+=("$v"); done
  for v in ${order[@]+"${order[@]}"}; do
    if one fragment "$v" "$f"; then printf 'fragment\t%s\tPASS (%s)\n' "$f" "$v"; return 0; fi
    last=$(grep -o "FALLBACK.*" "$T/$f.log" | head -1 | cut -c1-200)
    # an interface mismatch with this vertex function: try the next one; any other refusal is the fragment's own
    [[ $last == *nterpolant* || $last == *stage* || $last == *output* || $last == *input* || $last == *match* ]] || break
  done
  printf 'fragment\t%s\t%s\n' "$f" "${last:-no translated vertex function}"
}
verts=$(awk -F'\t' '$1=="vertex" && $3=="PASS"{print $2}' "$T/results.tsv" | tr '\n' ' ')
export verts; export -f frag_pair
awk '$1=="fragment"{print $2}' "$T/functions.txt" | xargs -P "$NPROC" -n 1 bash -c 'frag_pair "$0"' >> "$T/results.tsv" || true
{
  echo "library $LIB"
  echo "profile $PROFILE"
  for k in kernel vertex fragment; do
    tot=$(awk -F'\t' -v k=$k '$1==k' "$T/results.tsv" | wc -l | tr -d ' ')
    ok=$(awk -F'\t' -v k=$k '$1==k && $3 ~ /^PASS/' "$T/results.tsv" | wc -l | tr -d ' ')
    echo "$k: $ok of $tot translate"
  done
  echo "failure reasons (count):"
  awk -F'\t' '$3 !~ /^PASS/ {r=$3; sub(/^FALLBACK \(compile failed: /, "", r); r=substr(r, 1, 90); print r}' "$T/results.tsv" |
    sort | uniq -c | sort -rn | head -25
} | tee "$T/summary.txt"
