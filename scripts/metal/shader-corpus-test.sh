#!/bin/bash
# System-shader corpus regression test for the Metal path, on the Mac (or Linux), no GPU, no phone needed after fetch.
# Idea and table format: Chlorophyll tools/corpus.py + results/all-system-metallibs-summary.txt (external/Chlorophyll
# 787338f, MIT, Copyright (c) 2026 OOSEX GANG): every function of every system metallib through the translator, counted
# per library and kind. Here the translator is our metal2vulkan (AIR -> SPIR-V, spirv-val) at the pinned commit with
# our patches, for the A730 Vulkan profile, through scripts/metal/host-translate.sh (its stand-ins for vertex
# descriptors, function constants and attachments). docs/gpu-hybrid-plan.md section 6.
#
#   scripts/metal/shader-corpus-test.sh fetch      copy the 20H392 metallibs into out/metal/corpus/20H392/ (ROOT=DIR: a
#                                                  mounted root; else the phone, read-only, over scripts/net/ssh-phone.sh)
#   scripts/metal/shader-corpus-test.sh run        translate SET (default ui) -> out/metal/corpus/runs/<time>/
#   scripts/metal/shader-corpus-test.sh compare [RUN]   RUN (default: latest) against the baseline: exit 1 on a regression
#   scripts/metal/shader-corpus-test.sh baseline [RUN]  make RUN the baseline (userland/metal/tests/shader-corpus-<SET>.tsv)
#   scripts/metal/shader-corpus-test.sh all        fetch (if empty) + run + compare
# Env: SET=ui|all|LIST_FILE (ui = the 30 libraries CA, SpringBoard, widgets, posters, Maps, Camera and Photos load;
#      all = the 143 of out/metal/spi/metallibs.txt), PROFILE (default out/metal/profiles/a730-turnip-est.json),
#      LIB_TIMEOUT (seconds per library, default 1800).
# Long (ui: about 10-30 min; all: hours): scripts/bg.sh shader-corpus scripts/metal/shader-corpus-test.sh all
# Kinds "extern", "visible", "unqualified" (CoreImage stitchable functions, linked at run time) are counted, not compiled.
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/env.sh"

CORPUS=$MOUT/corpus
LIBS=$CORPUS/20H392
RUNS=$CORPUS/runs
SET=${SET:-ui}
PROFILE=${PROFILE:-$MOUT/profiles/a730-turnip-est.json}
LIB_TIMEOUT=${LIB_TIMEOUT:-1800}
BASE=$REPO/userland/metal/tests/shader-corpus-$( [ -f "$SET" ] && basename "$SET" .txt || echo "$SET").tsv
CHL=$EXT/Chlorophyll/results/all-system-metallibs-summary.txt
TO=""   # per-library deadline: GNU timeout (Linux; Homebrew coreutils on macOS), else none
if command -v timeout >/dev/null; then TO="timeout $LIB_TIMEOUT"; elif command -v gtimeout >/dev/null; then TO="gtimeout $LIB_TIMEOUT"; fi

# the UI set: libraries our logs show in use (metal.log images, crash frames) + Chlorophyll's UI list (ui-libs-22H352)
UI_LIBS="
/System/Library/Frameworks/QuartzCore.framework/default.metallib
/System/Library/PrivateFrameworks/RenderBox.framework/default.metallib
/System/Library/PrivateFrameworks/CoreUI.framework/default.metallib
/System/Library/PrivateFrameworks/VFX.framework/default.metallib
/System/Library/PrivateFrameworks/ClockKitUI.framework/default.metallib
/System/Library/PrivateFrameworks/NanoUniverse.framework/default.metallib
/System/Library/PrivateFrameworks/PridePoster.framework/default.metallib
/System/Library/PrivateFrameworks/PhotosUICore.framework/default.metallib
/System/Library/PrivateFrameworks/MediaCoreUI.framework/default.metallib
/System/Library/PrivateFrameworks/SiriUICore.framework/default.metallib
/System/Library/PrivateFrameworks/VectorKit.framework/default.metallib
/System/Library/PrivateFrameworks/VectorKit.framework/metal_libraries/AlloyCommonLibrary.metallib
/System/Library/PrivateFrameworks/WeatherUI.framework/default.metallib
/System/Library/PrivateFrameworks/ActivityRingsUI.framework/default.metallib
/System/Library/PrivateFrameworks/FitnessUI.framework/default.metallib
/System/Library/PrivateFrameworks/CameraUI.framework/default.metallib
/System/Library/PrivateFrameworks/TextInputUI.framework/default.metallib
/System/Library/PrivateFrameworks/MusicUI.framework/default.metallib
/System/Library/PrivateFrameworks/ChatKit.framework/default.metallib
/System/Library/PrivateFrameworks/LocalAuthenticationPrivateUI.framework/default.metallib
/System/Library/PrivateFrameworks/PassKitUIFoundation.framework/default.metallib
/System/Library/Frameworks/MetalPerformanceShaders.framework/Frameworks/MPSCore.framework/default.metallib
/System/Library/Frameworks/MetalPerformanceShaders.framework/Frameworks/MPSImage.framework/default.metallib
/System/Library/Frameworks/CoreImage.framework/default.metallib
/System/Library/Frameworks/CoreImage.framework/CoreImage.metallib
/System/Library/Frameworks/VideoToolbox.framework/default.metallib
/System/Library/PrivateFrameworks/VideoProcessing.framework/default.metallib
/System/Library/Frameworks/PencilKit.framework/default.metallib
/System/Library/Frameworks/SpriteKit.framework/default.metallib
/System/Library/Frameworks/MetalFX.framework/default.metallib
"

list() { # the phone paths of SET
	case "$SET" in
	ui) printf '%s\n' $UI_LIBS ;;
	all) sed 's#^rootmnt##' "$MOUT/spi/metallibs.txt" ;;
	*) grep -v '^#' "$SET" ;;
	esac
}

key() { # Chlorophyll's row key without its number: /a/b/c.metallib -> a__b__c.metallib
	echo "${1#/}" | sed 's#/#__#g'
}

fetch() {
	mkdir -p "$LIBS"
	local want=$CORPUS/fetch-list.txt
	list > "$want"
	if [ -n "${ROOT:-}" ]; then
		while read -r p; do
			[ -f "$ROOT$p" ] || { echo "fetch: missing $ROOT$p" >&2; continue; }
			mkdir -p "$LIBS$(dirname "$p")" && cp "$ROOT$p" "$LIBS$p"
		done < "$want"
	else
		# read-only on the phone: one tar of the files that exist
		local paths
		paths=$(sed 's#^/##' "$want" | tr '\n' ' ')
		"$REPO/scripts/net/ssh-phone.sh" "cd / && tar cf - $paths 2>/dev/null; true" > "$CORPUS/fetch.tar"
		tar xf "$CORPUS/fetch.tar" -C "$LIBS"
		rm -f "$CORPUS/fetch.tar"
	fi
	local have=0
	while read -r p; do [ -f "$LIBS$p" ] && have=$((have + 1)); done < "$want"
	echo "fetch: $have of $(wc -l < "$want" | tr -d ' ') metallibs in $LIBS"
}

cli() { # the host CLI for this metal2vulkan commit + patch series (built once, kept)
	local stamp
	stamp=$( (git -C "$M2V_SUB" rev-parse HEAD 2>/dev/null || echo "$M2V_COMMIT"); cat "$REPO"/userland/metal/patches/m2v-flame/*.patch \
		"$REPO"/userland/metal/patches/m2v/*.patch 2>/dev/null)
	stamp=$(printf '%s' "$stamp" | shasum -a 256 | cut -c1-12)
	local bin=$MOUT/bin/metal2vulkan-$stamp
	if [ ! -x "$bin" ]; then
		[ -f "$M2V/Cargo.toml" ] || { echo "no $M2V: run scripts/metal/fetch-sources.sh first" >&2; exit 1; }
		# a private copy (without the 1.5 GB test corpora): fetch-sources.sh may rewrite $M2V while cargo runs
		local src=$MOUT/m2v-corpus-src
		rsync -a --delete --exclude target --exclude 'crates/metal2vulkan-validation/corpus' \
			--exclude 'crates/metal2vulkan-conformance/recordings' "$M2V/" "$src/"
		cargo "+$RUST_TOOLCHAIN" build --release --manifest-path "$src/Cargo.toml" -p metal2vulkan --features cli \
			--bin metal2vulkan --target-dir "$MOUT/m2v-host" -j "$NPROC" >&2
		mkdir -p "$MOUT/bin" && cp "$MOUT/m2v-host/release/metal2vulkan" "$bin"
		rm -rf "$MOUT/m2v-host" "$src"     # 1+ GB; the binary is kept
	fi
	echo "$bin"
}

count_kinds() { # metallib -> "kind total" lines
	python3 -I "$REPO/scripts/metal/metallib-info.py" "$1" | tail -n +2 | awk '{n[$1]++} END{for (k in n) print k, n[k]}'
}

run() {
	[ -d "$LIBS" ] || fetch
	[ -f "$PROFILE" ] || { echo "no profile $PROFILE (scripts/metal/a730-profile.py)" >&2; exit 1; }
	local bin r t0 n=0
	bin=$(cli)
	r=$RUNS/$(date +%Y%m%d-%H%M%S)-$SET
	mkdir -p "$r"
	printf 'set\t%s\nprofile\t%s\ncli\t%s\nm2v\t%s\n' "$SET" "$PROFILE" "$bin" "$(git -C "$M2V_SUB" rev-parse --short HEAD 2>/dev/null || echo "$M2V_COMMIT")" > "$r/meta.tsv"
	: > "$r/summary.tsv"
	while read -r p; do
		n=$((n + 1))
		local lib=$LIBS$p k
		k=$(key "$p")
		if [ ! -f "$lib" ]; then
			printf '%s\tall\t0\t0\tmissing\n' "$k" >> "$r/summary.tsv"
			continue
		fi
		t0=$(date +%s)
		count_kinds "$lib" | while read -r kind total; do
			case $kind in kernel|vertex|fragment) ;; *) printf '%s\t%s\t%s\t0\tnot compiled (linked at run time)\n' "$k" "$kind" "$total" >> "$r/summary.tsv" ;; esac
		done
		local out=$r/libs
		if M2V_CLI=$bin TRANSLATE_DIR=$out OUTNAME=$k $TO "$REPO/scripts/metal/host-translate.sh" "$lib" "$PROFILE" \
			> "$r/$k.log" 2>&1; then :; else echo "run: $k: host-translate exit $? (timeout ${LIB_TIMEOUT}s?)" | tee -a "$r/errors.txt"; fi
		local res=$out/$k/results.tsv
		for kind in kernel vertex fragment; do
			local tot ok
			tot=$( [ -f "$res" ] && awk -F'\t' -v k=$kind '$1==k' "$res" | wc -l | tr -d ' ' || echo 0)
			ok=$( [ -f "$res" ] && awk -F'\t' -v k=$kind '$1==k && $3 ~ /^PASS/' "$res" | wc -l | tr -d ' ' || echo 0)
			[ "$tot" = 0 ] || printf '%s\t%s\t%s\t%s\t%ss\n' "$k" "$kind" "$tot" "$ok" "$(( $(date +%s) - t0 ))" >> "$r/summary.tsv"
		done
		# keep results and failure texts, not the SPIR-V
		find "$out/$k" -name '*.spv' -delete 2>/dev/null || true
		echo "run: [$n] $k done in $(( $(date +%s) - t0 )) s"
	done < <(list)
	report "$r" | tee "$r/summary.txt"
	echo "run: $r"
}

report() { # RUN: Chlorophyll-style table + Chlorophyll's iOS 18 / A630 numbers for the same library (reference only)
	local r=$1
	awk -F'\t' '$5 !~ /^not compiled|missing/ {f+=$3; ok+=$4} END{printf "functions=%d translate_ok=%d (kernel/vertex/fragment; metal2vulkan -> SPIR-V, A730 profile)\n", f, ok}' "$r/summary.tsv"
	while IFS=$'\t' read -r k kind tot ok note; do
		local chl=""
		if [ -f "$CHL" ]; then
			chl=$(grep -E "^ *[0-9]+_${k//./\\.} +$kind " "$CHL" | head -1 | grep -o 'translate=[0-9]*' || true)
		fi
		printf '  %-90s %-12s total=%-5s translate=%-5s %s%s\n' "$k" "$kind" "$tot" "$ok" "${note:+[$note] }" "${chl:+(Chlorophyll iOS18/A630 $chl)}"
	done < "$r/summary.tsv"
	echo "failure reasons (count):"
	cat "$r"/libs/*/results.tsv 2>/dev/null | awk -F'\t' '$3 !~ /^PASS/ {x=$3; sub(/^FALLBACK \(compile failed: /, "", x); print substr(x, 1, 100)}' |
		sort | uniq -c | sort -rn | head -20
}

latest() { ls -1d "$RUNS"/*-"$SET" 2>/dev/null | tail -1; }

compare() {
	local r=${1:-$(latest)}
	[ -n "$r" ] && [ -f "$r/summary.tsv" ] || { echo "compare: no run (scripts/metal/shader-corpus-test.sh run)" >&2; exit 1; }
	if [ ! -f "$BASE" ]; then
		echo "compare: no baseline $BASE; making it from $r"
		baseline "$r"
		return 0
	fi
	python3 -I - "$BASE" "$r/summary.tsv" <<'PY'
import sys
def load(p):
    d = {}
    for line in open(p):
        f = line.rstrip("\n").split("\t")
        if len(f) >= 4 and not line.startswith("#"):
            d[(f[0], f[1])] = (int(f[2]), int(f[3]))
    return d
base, now = load(sys.argv[1]), load(sys.argv[2])
worse = [(k, base[k], now.get(k, (0, 0))) for k in base if now.get(k, (0, 0))[1] < base[k][1]]
better = [(k, base.get(k, (0, 0)), v) for k, v in now.items() if v[1] > base.get(k, (0, 0))[1]]
for k, b, n in worse:
    print(f"REGRESSION {k[0]} {k[1]}: {b[1]}/{b[0]} -> {n[1]}/{n[0]}")
for k, b, n in better:
    print(f"better     {k[0]} {k[1]}: {b[1]}/{b[0]} -> {n[1]}/{n[0]}")
tb, tn = sum(v[1] for v in base.values()), sum(v[1] for v in now.values())
print(f"compare: baseline {tb} translate, now {tn}; {len(worse)} regressions, {len(better)} improvements")
sys.exit(1 if worse else 0)
PY
}

baseline() {
	local r=${1:-$(latest)}
	mkdir -p "$(dirname "$BASE")"
	{ echo "# shader corpus baseline: $(basename "$r") $(tr '\n' ' ' < "$r/meta.tsv")"; echo "# lib	kind	total	translate	note"; cat "$r/summary.tsv"; } > "$BASE"
	echo "baseline: $BASE"
}

case "${1:-all}" in
fetch) fetch ;;
run) run ;;
compare) compare "${2:-}" ;;
baseline) baseline "${2:-}" ;;
report) report "${2:-$(latest)}" ;;
all) [ -d "$LIBS" ] || fetch; run; compare ;;
*) sed -n '2,20p' "$0"; exit 2 ;;
esac
