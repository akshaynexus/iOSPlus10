#!/bin/sh
# Copy the iOS 16 (20H392, iPhone X) dyld shared cache out of the SystemOS image, for the ABI comparison in
# docs/laurel_sprout/ios26-userland.md. apfs-fuse on Linux, hdiutil on macOS. Never in git.
#   scripts/bg.sh ios16-cache scripts/ios26/ios16-cache-copy.sh
set -eu
. "$(dirname "$0")/../lib/env.sh"
APPLE=${APPLE:-$HOME/op10-apple}
IMG=${IMG:-$APPLE/20H392/087-86593-047.dmg}
T=${TREE:-$APPLE/20H392/cache}
MNT=$OUT/ios26/mnt/ios16
mkdir -p "$T" "$MNT"
case "$(uname -s)" in
Linux) apfs-fuse "$IMG" "$MNT"; trap 'fusermount3 -u "$MNT" 2>/dev/null || fusermount -u "$MNT"' EXIT; C=$MNT/root/System/Library/Caches/com.apple.dyld ;;
Darwin) hdiutil attach -readonly -nobrowse -mountpoint "$MNT" "$IMG" >/dev/null; trap 'hdiutil detach "$MNT" >/dev/null' EXIT; C=$MNT/System/Library/Caches/com.apple.dyld ;;
esac
for f in "$C"/*; do
  n=$(basename "$f")
  [ -e "$T/$n" ] && [ "$(wc -c < "$f")" = "$(wc -c < "$T/$n")" ] || cp "$f" "$T/"
done
ls "$T" | wc -l
du -sh "$T"
