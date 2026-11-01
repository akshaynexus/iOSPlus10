#!/bin/bash
# A/B of two metal2vulkan pins on the host (no GPU, no phone): the AIR -> SPIR-V translation of iOS 16.7 (20H392) system
# metallibs with each pin + its patch set (scripts/metal/fetch-sources.sh rules), through scripts/metal/host-translate.sh.
# Per pin and library: functions translated, total SPIR-V bytes (smaller = fewer instructions for ir3 to compile and run),
# wall time of the whole library (CPU cost of a cold translation).
#   scripts/bg.sh m2v-ab scripts/metal/m2v-ab.sh [PIN_A [PIN_B]]      default: f6a96b7d (rollback) and the submodule HEAD
# Env: LIBS="path ..." (inside the 20H392 OS image; default QuartzCore, RenderBox, CoreUI), PROFILE (default
# metal2vulkan's vk12-floor profile), OS_DMG (the 20H392 OS image 087-86698-044.dmg, mounted read-only with
# apfs-fuse) or SYSROOT=DIR (an already mounted iOS root).
# Output: out/metal/ab/<pin>/<lib>/ (host-translate results) and out/metal/ab/summary.tsv.
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/env.sh"
APPLE=${APPLE:-$HOME/op10-apple}
OS_DMG=${OS_DMG:-$APPLE/20H392/087-86698-044.dmg}   # the OS image (frameworks and their metallibs; scripts/ios16/fetch-dmgs.sh)
AB=$MOUT/ab
mkdir -p "$AB"
PIN_A=${1:-f6a96b7da82f3032e3fd7b1dc52c07bfd9b78dc8}
PIN_B=${2:-$(git -C "$M2V_SUB" rev-parse HEAD)}
LIBS=${LIBS:-"/System/Library/Frameworks/QuartzCore.framework/default.metallib
/System/Library/PrivateFrameworks/RenderBox.framework/default.metallib
/System/Library/PrivateFrameworks/CoreUI.framework/default.metallib"}

# the iOS root: SYSROOT, or the SystemOS image mounted in user space
MNT=$AB/mnt
umnt() { mountpoint -q "$MNT" 2>/dev/null && fusermount3 -u "$MNT" || true; }
if [ -z "${SYSROOT:-}" ]; then
  command -v apfs-fuse >/dev/null || { echo "m2v-ab: no SYSROOT and no apfs-fuse" >&2; exit 1; }
  mkdir -p "$MNT"; umnt
  apfs-fuse -o ro "$OS_DMG" "$MNT"
  trap umnt EXIT
  SYSROOT=$MNT/root
fi
rm -rf "$AB/libs"; mkdir -p "$AB/libs"
for l in $LIBS; do
  n=$(basename "$(dirname "$l")" .framework)_$(basename "$l" .metallib)
  cp "$SYSROOT$l" "$AB/libs/$n.metallib"      # Apple content: out/ only, never in git
done

tree() { # PIN DIR: metal2vulkan at PIN with its patch set (same rules as fetch-sources.sh)
  local pin=$1 d=$2 set=
  rm -rf "$d"; mkdir -p "$d"
  git -C "$M2V_SUB" archive "$pin" | tar -x -C "$d"
  case "$pin" in
  f6a96b7d*) set="m2v-flame-f6a96b7d m2v-f6a96b7d" ;;
  720ef1ce*) echo "m2v-ab: 720ef1ce takes ios-flame's own patches: not supported here" >&2; return 1 ;;
  *)         set="m2v-flame m2v" ;;
  esac
  for s in $set; do
    for p in "$METAL/patches/$s"/*.patch; do
      [ -f "$p" ] || continue
      (cd "$d" && patch -s -p1 --no-backup-if-mismatch < "$p") || { echo "m2v-ab: $s/$(basename "$p") does not apply at $pin" >&2; return 1; }
    done
  done
}

cli() { # PIN -> path of its host CLI (kept in $AB/bin)
  local pin=$1 bin=$AB/bin/metal2vulkan-${1:0:12}
  if [ ! -x "$bin" ]; then
    tree "$pin" "$AB/src-${pin:0:12}" >&2
    cargo "+$RUST_TOOLCHAIN" build --release --manifest-path "$AB/src-${pin:0:12}/Cargo.toml" -p metal2vulkan --features cli \
      --bin metal2vulkan --target-dir "$AB/target" -j "$NPROC" >&2
    mkdir -p "$AB/bin" && cp "$AB/target/release/metal2vulkan" "$bin"
    rm -rf "$AB/target"
  fi
  echo "$bin"
}

printf 'pin\tlibrary\tfunctions\ttranslated\tspirv_bytes\tseconds\n' > "$AB/summary.tsv"
for pin in "$PIN_A" "$PIN_B"; do
  bin=$(cli "$pin")
  prof=${PROFILE:-$AB/src-${pin:0:12}/crates/metal2vulkan-validation/profiles/vk12-floor.json}
  for m in "$AB"/libs/*.metallib; do
    n=$(basename "$m" .metallib)
    t0=$(date +%s.%N)
    M2V_CLI=$bin OUTNAME=$n TRANSLATE_DIR=$AB/${pin:0:12} "$REPO/scripts/metal/host-translate.sh" "$m" "$prof" > "$AB/${pin:0:12}-$n.log" 2>&1 || true
    t1=$(date +%s.%N)
    d=$AB/${pin:0:12}/$n
    total=$( { wc -l < "$d/functions.txt" 2>/dev/null || echo 0; } | tr -d ' ')
    ok=$(awk -F'\t' '$3 ~ /^PASS/' "$d/results.tsv" 2>/dev/null | wc -l | tr -d ' ')
    bytes=$( { cat "$d"/*.spv 2>/dev/null || true; } | wc -c | tr -d ' ')
    printf '%s\t%s\t%s\t%s\t%s\t%.1f\n' "${pin:0:9}" "$n" "$total" "$ok" "$bytes" "$(awk -v a="$t0" -v b="$t1" 'BEGIN{print b-a}')" | tee -a "$AB/summary.tsv"
  done
done
column -t "$AB/summary.tsv"
