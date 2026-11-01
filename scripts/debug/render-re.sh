#!/bin/bash
# Disassembly of the 20H392 frameworks behind the render work (RenderBox, QuartzCore, ...) into out/rend/<image>.dis,
# for grep (docs/laurel_sprout/gpu.md "IOSurface formats"). Needs blacktop/ipsw and the cryptex. macOS + Linux.
#   scripts/bg.sh rend-re scripts/debug/render-re.sh [IMAGE...]
set -euo pipefail
here=$(cd "$(dirname "$0")/../.." && pwd)
IPSW=${IPSW:-$(command -v ipsw || echo "$here/out/laurel-metal/ipsw/ipsw")}
mnt=$here/out/mnt-cryptex
if [ -z "${DSC:-}" ]; then
  [ -d "$mnt/root/System" ] || { mkdir -p "$mnt"; apfs-fuse -o ro "$HOME/op10-apple/20H392/087-86593-047.dmg" "$mnt"; }
  DSC=$mnt/root/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64
fi
work=$here/out/rend; mkdir -p "$work"
[ $# -gt 0 ] || set -- RenderBox QuartzCore
for i in "$@"; do
  "$IPSW" dyld disass "$DSC" --image "$i" --quiet --force > "$work/$i.dis" 2> "$work/$i.err" </dev/null &
done
wait
wc -l "$work"/*.dis
