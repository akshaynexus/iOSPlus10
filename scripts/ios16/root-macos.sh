#!/bin/bash
# Build the iOS 16.7.16 root (HFS+, case-sensitive, journaled) for the negroni userdata partition, on
# macOS. Same result as external/slop/negroni-ios/tools/build-ios16-root.sh (Linux: apfs-fuse +
# hfsplus loop mount), but with macOS's own APFS and HFS+ support. No Sileo (SKIP_SILEO in the port).
#
#   sudo scripts/ios16/root-macos.sh [OUT.img]        (default $APPLE/ios16-root.img)
#   in tmux:  scripts/bg.sh root sudo scripts/ios16/root-macos.sh   (then: tmux attach -t root,
#             type the sudo password, detach with Ctrl-b d)
#
# Needs: the three DMGs in $APPLE/20H392 (scripts/ios16/fetch-dmgs.sh), Homebrew rsync (3.x; macOS's
# openrsync lacks -H), python3. Then: scripts/ios16/root-simg.sh (Android sparse image for fastboot).
# Linux: scripts/ios16/root-linux.sh. Shared last steps: scripts/ios16/root-finish.sh.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
U=${SUDO_USER:-$USER}
H=$(dscl . -read "/Users/$U" NFSHomeDirectory | awk '{print $2}')
REPO=$(cd "$(dirname "$0")/../.." && pwd)
SLOP=$REPO/external/slop
APPLE=${APPLE:-$H/op10-apple}
D=$APPLE/20H392
OUT=${1:-$APPLE/ios16-root.img}
SIZE=${SIZE:-16g}
RSYNC=$(command -v /opt/homebrew/bin/rsync || command -v /usr/local/bin/rsync || true)
# read the whole --version output first: with pipefail, `| head -1` would SIGPIPE rsync and fail
rv=$([ -n "$RSYNC" ] && "$RSYNC" --version 2>/dev/null || true)
case "$rv" in *"version 3."*) ;; *) echo "need Homebrew rsync 3.x (brew install rsync)" >&2; exit 1 ;; esac
for f in 087-86698-044.dmg 087-86593-047.dmg 087-86715-047.dmg; do
  [ -f "$D/$f" ] || { echo "missing $D/$f (scripts/ios16/fetch-dmgs.sh)" >&2; exit 1; }
done
[ ! -e "$OUT" ] || { echo "refusing to overwrite $OUT" >&2; exit 1; }

work=$(mktemp -d /tmp/iosroot.XXXX)
devs=()
cleanup() {
  for m in "$work"/root "$work"/os "$work"/sysos "$work"/appos; do
    mount | grep -q " on $m " && umount "$m" 2>/dev/null || true
  done
  for d in "${devs[@]}"; do hdiutil detach -force "$d" >/dev/null 2>&1 || true; done
  rmdir "$work"/* "$work" 2>/dev/null || true
}
trap cleanup EXIT

# attach IMAGE MOUNTPOINT [raw]: read-only, hidden from Finder/Spotlight
attach() {
  local img=$1 mnt=$2 extra=()
  [ "${3:-}" = raw ] && extra=(-imagekey diskimage-class=CRawDiskImage)
  mkdir -p "$mnt"
  local plist dev
  plist=$(hdiutil attach -readonly -nobrowse -noverify -noautoopen "${extra[@]}" -mountpoint "$mnt" -plist "$img")
  dev=$(printf '%s' "$plist" | python3 -c 'import plistlib,sys; e=plistlib.loads(sys.stdin.buffer.read())["system-entities"]; print(min(x["dev-entry"] for x in e))')
  devs+=("$dev")
  echo "attached $(basename "$img") -> $mnt ($dev)"
}

# 1. Apple images (OS is UDIF, the cryptexes are raw APFS)
attach "$D/087-86698-044.dmg" "$work/os"
attach "$D/087-86593-047.dmg" "$work/sysos" raw
attach "$D/087-86715-047.dmg" "$work/appos" raw

# 2. empty case-sensitive journaled HFS+ image (sparse file)
mkfile -n "$SIZE" "$OUT"
dev=$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$OUT" | awk 'NR==1{print $1}')
devs=("$dev" "${devs[@]}")
newfs_hfs -s -J -v iOSRoot "$dev"
mkdir -p "$work/root"
mount -t hfs -o nobrowse "$dev" "$work/root"
diskutil enableOwnership "$work/root" >/dev/null
mdutil -i off "$work/root" >/dev/null 2>&1 || true
touch "$work/root/.metadata_never_index"
R=$work/root

copy() { echo "copying $1 -> ${2#"$R"}"; mkdir -p "$2"; "$RSYNC" -aH --numeric-ids "$1/" "$2/"; }
copy "$work/os" "$R"
copy "$work/sysos" "$R/private/preboot/Cryptexes/OS"
copy "$work/appos" "$R/private/preboot/Cryptexes/App"

# 3. dyld shared cache where dyld looks at ignition level 1 (hard links), and every cryptex file
#    without a counterpart in the OS root linked to its root path (as mkiosroot.sh)
dsc=private/preboot/Cryptexes/OS/System/Library/Caches/com.apple.dyld
mkdir -p "$R/System/Library/Caches/com.apple.dyld"
for f in "$R/$dsc"/*; do ln -f "$f" "$R/System/Library/Caches/com.apple.dyld/${f##*/}"; done
for c in OS App; do
  (cd "$R/private/preboot/Cryptexes/$c" && find . ! -type d ! -path './System/Library/Caches/com.apple.dyld/*') |
  while IFS= read -r f; do
    f=${f#./}
    if [ ! -e "$R/$f" ] && [ ! -L "$R/$f" ]; then
      mkdir -p "$R/$(dirname "$f")"
      src=$R/private/preboot/Cryptexes/$c/$f
      if [ -L "$src" ]; then cp -P "$src" "$R/$f"; else ln "$src" "$R/$f"; fi
    fi
  done
done

# 4. logd stores (owner _logd 272 + .migrated), system keybag (as mkiosroot.sh / build-ios16-root.sh)
db=$R/private/var/db
mkdir -p "$db/diagnostics/timesync" "$db/uuidtext"
for d in diagnostics uuidtext diagnostics/timesync; do
  touch "$db/$d/.migrated"; chown 272:272 "$db/$d" "$db/$d/.migrated"; chmod 0644 "$db/$d/.migrated"
done
chmod 0751 "$db/diagnostics"; chmod 0755 "$db/uuidtext" "$db/diagnostics/timesync"
kb=$R/private/var/keybags
mkdir -p "$kb"; chown 0:0 "$kb"; chmod 0700 "$kb"
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
  '<plist version="1.0"><dict><key>KeyBagKeys</key><data>U1dFRVQ=</data></dict></plist>' > "$kb/systembag.kb"
chown 0:0 "$kb/systembag.kb"; chmod 0600 "$kb/systembag.kb"

# 5. bring-up tweaks, staged apps, no macOS metadata (shared with root-linux.sh)
bash "$REPO/scripts/ios16/root-finish.sh" "$R"
sync
umount "$R"
fsck_hfs -fy "$dev" || true
fsck_hfs -fn "$dev"
chown "$U" "$OUT"
ls -l "$OUT"
echo "next: scripts/bg.sh simg scripts/ios16/root-simg.sh"
