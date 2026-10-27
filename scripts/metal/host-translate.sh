#!/bin/bash
# Host check of the shader path (no phone, no GPU): translate a metallib's functions with the metal2vulkan CLI
# (AIR -> SPIR-V, checked by spirv-val when it is on PATH) for a Vulkan device profile.
#   scripts/metal/host-translate.sh [METALLIB] [PROFILE_JSON]
#     METALLIB  default: QuartzCore's default.metallib of the attached 20H392 root (out/metal/rootmnt)
#     PROFILE   default: metal2vulkan's vk12-floor profile (a bare Vulkan 1.2 device). Replace it with the A730's
#               profile once vkprobe/vulkaninfo gives one (docs/metal-design.md "Device profile").
# Per function: kernels and vertex functions alone; each fragment with the vertex functions until one links.
# Output: out/metal/translate/<lib>/{results.tsv,summary.txt,*.spv} (OUTNAME=NAME sets <lib>, TRANSLATE_DIR the parent,
# M2V_CLI another CLI). Builds the CLI on first use.
# A730 profile (estimate): python3 -I scripts/metal/a730-profile.py \$M2V/.../vk12-floor.json out/metal/profiles/a730-turnip-est.json
# Run in tmux: scripts/bg.sh metal-translate scripts/metal/host-translate.sh
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/env.sh"
LIB=${1:-$MOUT/rootmnt/System/Library/Frameworks/QuartzCore.framework/default.metallib}
# no attached root: the copy in out/metal/ref (cp ROOT/System/Library/Frameworks/QuartzCore.framework/default.metallib
# out/metal/ref/QuartzCore.default.metallib)
[ -f "$LIB" ] || [ -n "${1:-}" ] || LIB=$MOUT/ref/QuartzCore.default.metallib
PROFILE=${2:-$M2V/crates/metal2vulkan-validation/profiles/vk12-floor.json}
# M2V_CLI=PATH: a CLI built elsewhere (scripts/metal/shader-corpus-test.sh builds one per metal2vulkan commit + patches)
CLI=${M2V_CLI:-$MOUT/bin/metal2vulkan}   # the CLI is kept, its cargo target dir (1 GB) may be deleted
if [ ! -x "$CLI" ]; then
  cargo "+$RUST_TOOLCHAIN" build --release --manifest-path "$M2V/Cargo.toml" -p metal2vulkan --features cli \
    --bin metal2vulkan --target-dir "$MOUT/m2v-host" -j "$NPROC"
  mkdir -p "$MOUT/bin" && cp "$MOUT/m2v-host/release/metal2vulkan" "$CLI"
fi
name=${OUTNAME:-$(basename "$(dirname "$LIB")" .framework)_$(basename "$LIB" .metallib)}
T=${TRANSLATE_DIR:-$MOUT/translate}/$name   # TRANSLATE_DIR: another parent directory (corpus runs)
rm -rf "$T" && mkdir -p "$T"
python3 -I "$REPO/scripts/metal/metallib-info.py" "$LIB" | tail -n +2 | awk '{print $1, $2}' > "$T/functions.txt"
export METAL2VULKAN_REPRO_DIR=$T/repros
# CA supplies vertex descriptors, function constants and attachment formats at pipeline creation. On the host the
# loop below answers each input the compile asks for with a stand-in, and tries again:
#   - a vertex attribute: a 16-byte slot in buffer 29 (formats tried in order until the attribute's type accepts one)
#   - a function constant: the first Metal type the constant accepts, value zero/false (CA's real values differ: this
#     checks that the body translates with some value, not CA's variant)
#   - a color attachment the fragment reads or a tile kernel's attachments: BGRA8Unorm
# This tests the translation of the shader bodies, not CA's real layouts.
cat > "$T/fix.py" <<'PY'
import json, re, sys
# fix.py KEY ERRORTEXT: change the stand-ins of $T/KEY.{vd.json,fc,ca} for the input the error names;
# exit 1 when there is nothing left to try
key, err = sys.argv[1], sys.argv[2]
FORMATS = ["Float4", "UInt4", "Int4", "Half4", "UChar4Normalized"]
TYPES = ["bool", "uint", "int", "float", "half", "ushort", "short", "uchar", "char"]
CFORMATS = ["BGRA8Unorm", "RGBA8Unorm", "R8Unorm", "RG8Unorm", "RGBA16Float", "R16Float", "RG16Float", "R32Float",
            "RG32Float", "RGBA32Float", "R8Uint", "R16Uint", "R32Uint", "RGBA8Uint", "RGBA16Uint", "RGBA32Uint", "R32Sint"]
TYPES += [t + n for n in "234" for t in ("uint", "int", "float", "half", "ushort", "short", "uchar", "char", "bool")]
def lines(path):
    try:
        return [l.strip() for l in open(path) if l.strip()]
    except OSError:
        return []
def value(t):
    n = int(t[-1]) if t[-1].isdigit() else 1
    return ",".join(["false" if t.startswith("bool") else "0"] * n)
m = re.search(r"VertexAttribute \{ attribute: (\d+) \}", err)
if m:
    path = key + ".vd.json"
    try:
        d = json.load(open(path))
    except Exception:
        d = {"layouts": {"29": {"stride": 256, "step_function": "PerVertex", "step_rate": 1}}, "attributes": {}}
    a, attrs = m.group(1), d["attributes"]
    if a in attrs:
        i = FORMATS.index(attrs[a]["format"]) + 1
        if i >= len(FORMATS):
            sys.exit(1)
        attrs[a]["format"] = FORMATS[i]
    else:
        if len(attrs) >= 16:
            sys.exit(1)
        attrs[a] = {"format": FORMATS[0], "offset": 16 * len(attrs), "buffer_index": 29}
    json.dump(d, open(path, "w"))
    sys.exit(0)
m = re.search(r"FunctionConstant(Type)? \{ index: (\d+) \}", err)
if m:
    path, idx = key + ".fc", m.group(2)
    have = {l.split(":")[0]: l for l in lines(path)}
    if m.group(1):                       # wrong type: the next one
        if idx not in have:
            sys.exit(1)
        i = TYPES.index(have[idx].split(":")[1]) + 1
        if i >= len(TYPES):
            sys.exit(1)
        have[idx] = f"{idx}:{TYPES[i]}:{value(TYPES[i])}"
    else:
        if idx in have or len(have) >= 64:
            sys.exit(1)
        have[idx] = f"{idx}:bool:false"
    open(path, "w").write("\n".join(have.values()) + "\n")
    sys.exit(0)
m = re.search(r"ColorAttachment \{ index: (\d+) \}", err)
if m or "TileAttachments" in err:
    path, top = key + ".ca", int(m.group(1)) if m else 0
    have = lines(path) or ["0:BGRA8Unorm"]
    if not m and lines(path):
        sys.exit(1)
    if m and top < len(have):            # the attachment exists: its format does not fit the output, the next one
        i = CFORMATS.index(have[top].split(":")[1]) + 1
        if i >= len(CFORMATS):
            sys.exit(1)
        have[top] = f"{top}:{CFORMATS[i]}"
    have += [f"{i}:BGRA8Unorm" for i in range(len(have), top + 1)]
    open(path, "w").write("\n".join(have) + "\n")
    sys.exit(0)
sys.exit(1)
PY
one() { # kind name [fragment]: compile; stand-ins grow in $T/<function>.{vd.json,fc,ca}
  local kind=$1 fn=$2 frag=${3:-} out log key vd=$T/$2.vd.json args c
  key=$T/${frag:-$fn}
  for _ in $(seq 1 250); do
    out=$key.spv; log=$key.log
    args=(--profile "$PROFILE" --function "$fn")
    if [ -n "$frag" ]; then
      args+=(--fragment "$frag")
      [ -f "$key.ca" ] || echo "0:BGRA8Unorm" > "$key.ca"
    fi
    if [ -f "$key.ca" ]; then while read -r c; do args+=(--color-format "$c"); done < "$key.ca"; fi
    [ -f "$vd" ] && args+=(--vertex-descriptor "$vd")
    # constants: the fragment's own first, then the vertex function's (one value per index)
    for c in $(cat "$key.fc" "$T/$fn.fc" 2>/dev/null | awk -F: '!seen[$1]++'); do args+=(--constant "$c"); done
    "$CLI" "$LIB" "$out" "${args[@]}" > "$log" 2>&1 && return 0
    # a fragment does not change its vertex function's descriptor (complete from the vertex run)
    if [ -n "$frag" ] && grep -q "VertexAttribute" "$log"; then return 1; fi
    python3 -I "$T/fix.py" "$key" "$(grep -o 'FALLBACK.*' "$log" | head -1)" || return 1
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
# repro bundles are large (about 700 MB for QuartzCore): keep them only on request
[ -n "${KEEP_REPROS:-}" ] || rm -rf "$T/repros"
