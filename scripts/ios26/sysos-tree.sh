#!/bin/sh
# Copy the parts of the donor images that the userland work reads into plain files, with no root access and no writes
# to the images. Linux: apfs-fuse (read-only). macOS: hdiutil attach -readonly.
#   scripts/bg.sh ios26-tree env DEV=n104ap scripts/ios26/sysos-tree.sh
# Output: $APPLE/ios26/$BUILD-$DEV/tree/cache/   dyld_shared_cache_arm64e + subcaches (no .symbols unless SYMBOLS=1)
#         $APPLE/ios26/$BUILD-$DEV/tree/root/    every Mach-O of the OS volume and the SystemOS volume outside the cache,
#                                                with its path kept (scripts/ios26/macho-copy.py finds them by magic)
#         $APPLE/ios26/$BUILD-$DEV/tree/root-list.txt
# CACHE_ONLY=1 copies only the dyld shared cache. Never in git. Downloaded data: nothing from the images is executed.
set -eu
. "$(dirname "$0")/../lib/env.sh"
. "$(dirname "$0")/donor.sh"
D=${OUTDIR:-$APPLE/ios26/$BUILD-$DEV/os}
T=${TREE:-$APPLE/ios26/$BUILD-$DEV/tree}
OS_DMG=$D/${OS_AEA%.aea}
SYS_DMG=$D/${SYSOS%.aea}
MNT=$OUT/ios26/mnt/$DEV
mkdir -p "$T/cache" "$T/root" "$MNT/sys" "$MNT/os"
case "$(uname -s)" in
Linux)
  mount_ro() { apfs-fuse "$1" "$2"; }
  unmount() { fusermount3 -u "$1" 2>/dev/null || fusermount -u "$1"; }
  vol() { echo "$1/root"; } ;;
Darwin)
  mount_ro() { hdiutil attach -readonly -nobrowse -mountpoint "$2" "$1" >/dev/null; }
  unmount() { hdiutil detach "$1" >/dev/null; }
  vol() { echo "$1"; } ;;
esac
trap 'unmount "$MNT/sys" 2>/dev/null || true; unmount "$MNT/os" 2>/dev/null || true' EXIT
mount_ro "$SYS_DMG" "$MNT/sys"
[ "${CACHE_ONLY:-0}" = 1 ] || mount_ro "$OS_DMG" "$MNT/os"
C=$(vol "$MNT/sys")/System/Library/Caches/com.apple.dyld
ls -l "$C" | sed -n 1,5p
find "$C" -type f | while read -r f; do
  case "$f" in *.symbols) [ "${SYMBOLS:-0}" = 1 ] || continue ;; esac
  [ -e "$T/cache/$(basename "$f")" ] && [ "$(wc -c < "$f")" = "$(wc -c < "$T/cache/$(basename "$f")")" ] || cp "$f" "$T/cache/"
done
if [ "${CACHE_ONLY:-0}" = 1 ]; then du -sh "$T/cache"; exit 0; fi
python3 -I "$REPO/scripts/ios26/macho-copy.py" "$(vol "$MNT/os")" "$T/root/os" > "$T/root-list-os.txt"
python3 -I "$REPO/scripts/ios26/macho-copy.py" "$(vol "$MNT/sys")" "$T/root/sys" > "$T/root-list-sys.txt"
cat "$T/root-list-os.txt" "$T/root-list-sys.txt" > "$T/root-list.txt"
wc -l "$T/root-list.txt"
du -sh "$T/cache" "$T/root"
