#!/bin/bash
# STUB (written, never run): the iOS 26.5.2 (23F84, iPhone12,3 donor) root for negroni, HFS+ like the iOS 16 root
# (scripts/ios16/root-macos.sh). Same layout idea: OS volume at /, SystemOS cryptex at
# /private/preboot/Cryptexes/OS, AppOS cryptex at /private/preboot/Cryptexes/App, dyld shared cache hard-linked
# to /System/Library/Caches/com.apple.dyld, cryptex-only files linked into the root.
#
#   sudo scripts/ios26/root-macos.sh [OUT.img]     (default $APPLE/ios26-root.img; 24 GB sparse)
#
# Inputs: scripts/ios26/fetch-os.sh output in $APPLE/ios26/23F84-d421ap/os (decrypted OS + SystemOS, plain AppOS).
# Differences to iOS 16 that are handled here or still open (docs/ios26-port-status.md section 5):
#   - OS and SystemOS come as AEA; fetch-os.sh decrypts them (ipsw fw aea).                      [V] format
#   - 26.x keeps the cryptex layout of 16.x (Cryptex1,SystemOS / Cryptex1,AppOS in BuildManifest) [V] manifest
#   - the dyld cache is dyld_shared_cache_arm64e + 83 subcaches, slide info v5                     [V]
#   - root tweaks: scripts/ios26/root-tweaks.py (iOS 16 list, each item still to audit on 26)    [I]
#   - keybag stand-in, logd stores: same as iOS 16                                                [I]
set -euo pipefail
[ "${IOS26_ROOT_STUB_OK:-0}" = 1 ] || { echo "stub: not tested; set IOS26_ROOT_STUB_OK=1 to run it" >&2; exit 2; }
[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
U=${SUDO_USER:-$USER}
H=$(dscl . -read "/Users/$U" NFSHomeDirectory | awk '{print $2}')
REPO=$(cd "$(dirname "$0")/../.." && pwd)
APPLE=${APPLE:-$H/op10-apple}
D=${OSDIR:-$APPLE/ios26/23F84-d421ap/os}
OUT=${1:-$APPLE/ios26-root.img}
SIZE=${SIZE:-24g}
OS_DMG=$D/094-55352-108.dmg SYS_DMG=$D/094-55541-109.dmg APP_DMG=$D/094-54871-112.dmg
RSYNC=$(command -v /opt/homebrew/bin/rsync || command -v /usr/local/bin/rsync || true)
[ -n "$RSYNC" ] || { echo "need Homebrew rsync 3.x" >&2; exit 1; }
for f in "$OS_DMG" "$SYS_DMG" "$APP_DMG"; do [ -f "$f" ] || { echo "missing $f (scripts/ios26/fetch-os.sh)" >&2; exit 1; }; done
[ ! -e "$OUT" ] || { echo "refusing to overwrite $OUT" >&2; exit 1; }
avail=$(df -g "$(dirname "$OUT")" | awk 'NR==2 {print $4}')
[ "$avail" -ge 20 ] || { echo "only $avail GiB free; the root needs about 18 GiB of real blocks [I]" >&2; exit 1; }

work=$(cd "$(mktemp -d /tmp/ios26root.XXXX)" && pwd -P)
devs=()
cleanup() {
  for m in "$work"/root "$work"/os "$work"/sysos "$work"/appos; do
    if mount | grep -q " on $m "; then umount "$m" 2>/dev/null || umount -f "$m" 2>/dev/null || true; fi
  done
  for d in ${devs[@]+"${devs[@]}"}; do hdiutil detach -force "$d" >/dev/null 2>&1 || true; done
  rmdir "${work:?}"/root "${work:?}"/os "${work:?}"/sysos "${work:?}"/appos "${work:?}" 2>/dev/null || true
}
trap cleanup EXIT
attach() {
  local img=$1 mnt=$2 extra=() plist dev
  [ "${3:-}" = raw ] && extra=(-imagekey diskimage-class=CRawDiskImage)
  mkdir -p "$mnt"
  plist=$(hdiutil attach -readonly -nobrowse -noverify -noautoopen ${extra[@]+"${extra[@]}"} -mountpoint "$mnt" -plist "$img")
  dev=$(printf '%s' "$plist" | python3 -c 'import plistlib,sys; e=plistlib.loads(sys.stdin.buffer.read())["system-entities"]; print(min(x["dev-entry"] for x in e))')
  devs+=("$dev")
}
# [U] which of the three are UDIF and which raw APFS on 26.x: try UDIF first, raw second
try_attach() { attach "$1" "$2" 2>/dev/null || attach "$1" "$2" raw; }
try_attach "$OS_DMG" "$work/os"; try_attach "$SYS_DMG" "$work/sysos"; try_attach "$APP_DMG" "$work/appos"

mkfile -n "$SIZE" "$OUT"
dev=$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$OUT" | awk 'NR==1{print $1}')
devs=("$dev" ${devs[@]+"${devs[@]}"})
newfs_hfs -s -J -v iOSRoot "$dev"
mkdir -p "$work/root"; mount -t hfs -o nobrowse "$dev" "$work/root"
R=$work/root
copy() { mkdir -p "$2"; "$RSYNC" -aH --numeric-ids "$1/" "$2/"; }
copy "$work/os" "$R" & p1=$!
copy "$work/sysos" "$R/private/preboot/Cryptexes/OS" & p2=$!
copy "$work/appos" "$R/private/preboot/Cryptexes/App" & p3=$!
wait $p1; wait $p2; wait $p3
dsc=private/preboot/Cryptexes/OS/System/Library/Caches/com.apple.dyld
mkdir -p "$R/System/Library/Caches/com.apple.dyld"
for f in "$R/$dsc"/*; do ln -f "$f" "$R/System/Library/Caches/com.apple.dyld/${f##*/}"; done
for c in OS App; do
  (cd "$R/private/preboot/Cryptexes/$c" && find . ! -type d ! -path './System/Library/Caches/com.apple.dyld/*') |
  while IFS= read -r f; do
    f=${f#./}
    if [ ! -e "$R/$f" ] && [ ! -L "$R/$f" ]; then
      mkdir -p "$R/$(dirname "$f")"; src=$R/private/preboot/Cryptexes/$c/$f
      if [ -L "$src" ]; then cp -P "$src" "$R/$f"; else ln "$src" "$R/$f"; fi
    fi
  done
done
db=$R/private/var/db
mkdir -p "$db/diagnostics/timesync" "$db/uuidtext"
for d in diagnostics uuidtext diagnostics/timesync; do
  touch "$db/$d/.migrated"; chown 272:272 "$db/$d" "$db/$d/.migrated"; chmod 0644 "$db/$d/.migrated"
done
kb=$R/private/var/keybags; mkdir -p "$kb"; chmod 0700 "$kb"
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
  '<plist version="1.0"><dict><key>KeyBagKeys</key><data>U1dFRVQ=</data></dict></plist>' > "$kb/systembag.kb"
chmod 0600 "$kb/systembag.kb"
python3 -I "$REPO/scripts/ios26/root-tweaks.py" "$R"
sync; umount "$R"; fsck_hfs -fy "$dev" || true
chown "$U" "$OUT"; ls -l "$OUT"
echo "next: scripts/ios16/root-simg.sh $OUT (Android sparse image; same tool for 26)"
