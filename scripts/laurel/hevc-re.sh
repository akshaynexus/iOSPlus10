#!/bin/bash
# Reverse-engineering inputs of the HEVC decoder work, out/heic/re (git-ignored). No root needed, no third-party binary.
#   scripts/bg.sh heic-re scripts/laurel/hevc-re.sh
# 1. apfs-fuse mounts of the OS + SystemOS images (20H392) in out/heic/re/{os,sys}, the cache copied to out/heic/re/dsc; 2. images.txt, then for each
# image the HEVC path goes through: symbols, strings and a listing in out/heic/re/IMAGE.* (scripts/laurel/dsc-image.py).
# Findings from these files: docs/laurel_sprout/hevc.md. Apple content stays in out/.
set -euo pipefail
. "$(cd "$(dirname "$0")/../lib" && pwd)/env.sh"
APPLE=${APPLE:-$HOME/op10-apple}
RE=$OUT/heic/re
mkdir -p "$RE"
for p in os:087-86698-044 sys:087-86593-047; do
  n=${p%%:*}; f=${p#*:}
  mkdir -p "$RE/$n"
  ln -sf "$APPLE/20H392/$f.dmg" "$RE/$n.dmg"
  mountpoint -q "$RE/$n" || apfs-fuse -o ro "$RE/$n.dmg" "$RE/$n"
done
# out of the mount first: 3.2 GB, but symbol reads through apfs-fuse take minutes each
DSC=$RE/dsc
if [ ! -s "$DSC/dyld_shared_cache_arm64.symbols" ]; then
  mkdir -p "$DSC"
  cp -n "$RE"/sys/root/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64* "$DSC/"
fi
TOOL=$REPO/scripts/laurel/dsc-image.py
python3 -I "$TOOL" "$DSC" images > "$RE/images.txt"
for i in ${IMAGES:-VCPHEVC VideoToolbox CMPhoto ImageIO}; do
  python3 -I "$TOOL" "$DSC" syms "$i" > "$RE/$i.symbols.txt"
  python3 -I "$TOOL" "$DSC" strings "$i" > "$RE/$i.strings.txt"
  [ -n "${NO_DISASS:-}" ] || python3 -I "$TOOL" "$DSC" dis "$i" > "$RE/$i.s"
done
wc -l "$RE"/*.symbols.txt "$RE"/*.strings.txt
