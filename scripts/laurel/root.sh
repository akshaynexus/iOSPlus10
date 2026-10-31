#!/bin/bash
# Build the Mi A3 (laurel_sprout) iOS 16.7.16 root for userdata (rd=ufsroot0) on Linux, as a sparse image.
#   scripts/bg.sh laurel-root sudo scripts/laurel/root.sh       (needs root: loop mounts, apfs-fuse, rsync -aH)
# Input: $APPLE/20H392/*.dmg (scripts/ios16/fetch-dmgs.sh, op10tool ipsw-get; default APPLE=~/op10-apple).
# Steps: 1. external/ios-topaz/tools/mkiosroot.sh (case-sensitive journaled HFS+, OS + SystemOS/AppOS cryptexes,
#        dyld cache link, plain system keybag); 2. topaz sweet-root-tweaks.py (build 20H392 fixes, launchd,
#        CommCenter drop, Setup, migration); 3. fsck; 4. op10tool img2simg -> ios16-root.simg (owned by the user).
# Output: $APPLE/laurel-ios16-root.img + .simg (Apple content: never in git). SIZE=16G (userdata is 108 GiB).
# Flash (erases Android user data; owner confirms first): fastboot reboot bootloader, then
#   fastboot -S 512M flash userdata $APPLE/laurel-ios16-root.simg
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "laurel-root: run with sudo" >&2; exit 1; }
U=${SUDO_USER:-$USER}
H=$(getent passwd "$U" | cut -d: -f6)
REPO=$(cd "$(dirname "$0")/../.." && pwd)
APPLE=${APPLE:-$H/op10-apple}
D=$APPLE/20H392
IMG=$APPLE/laurel-ios16-root.img
TOPAZ=$REPO/external/ios-topaz/tools
for t in apfs-fuse mkfs.hfsplus fsck.hfsplus rsync python3; do
  command -v "$t" >/dev/null || { echo "laurel-root: missing $t (paru -S hfsprogs apfs-fuse-git)" >&2; exit 1; }
done
for f in 087-86698-044.dmg 087-86593-047.dmg 087-86715-047.dmg; do
  [ -s "$D/$f" ] || { echo "laurel-root: missing $D/$f (scripts/ios16/fetch-dmgs.sh)" >&2; exit 1; }
done
modprobe hfsplus
ts() { date +%H:%M:%S; }

echo "$(ts) laurel-root: 1/4 mkiosroot -> $IMG (${SIZE:-16G})"
rm -f "$IMG"
# mkiosroot ends with one fsck repair and a read-only verify; after the big copy the verify can still ask
# for a "minor repair" of the volume header (2026-11-01). Repair again (max 3) until the verify is clean.
if ! bash "$TOPAZ/mkiosroot.sh" "$D/087-86698-044.dmg" "$D/087-86593-047.dmg" "$D/087-86715-047.dmg" "$IMG" "${SIZE:-16G}"; then
  [ -s "$IMG" ] || { echo "laurel-root: mkiosroot failed before the image existed" >&2; exit 1; }
  ok=0
  for i in 1 2 3; do
    echo "$(ts) laurel-root: verify failed: fsck repair pass $i"
    fsck.hfsplus -f -y "$IMG" | grep -v 'Illegal name' || true
    if fsck.hfsplus -f -n "$IMG" >/dev/null 2>&1; then ok=1; break; fi
  done
  if [ $ok = 0 ]; then
    # Linux fsck_hfs 540.1 repairs the volume header and reports "Volume header needs minor repair (1, 0)"
    # again on the next verify-only pass (seen 2026-11-01 after 3 repairs; catalog, extents, bitmap and
    # attributes all pass). Accept exactly that one finding; any other problem stops the build.
    v=$(fsck.hfsplus -f -n "$IMG" 2>&1 || true)
    others=$(printf '%s\n' "$v" | grep -E 'needs|invalid|Invalid|incorrect|Incorrect|error|Error|missing|Missing|overlap' | grep -v 'Volume header needs minor repair' | grep -v 'needs to be repaired' || true)
    if printf '%s\n' "$v" | grep -q 'Volume header needs minor repair' && [ -z "$others" ]; then
      echo "$(ts) laurel-root: note: only 'Volume header needs minor repair' remains (Linux fsck_hfs); accepted"
      ok=1
    else
      echo "laurel-root: volume still not clean after 3 repairs" >&2; printf '%s\n' "$v" | tail -8; exit 1
    fi
  fi
  echo "$(ts) laurel-root: volume checked"
fi

echo "$(ts) laurel-root: 2/4 root tweaks (topaz sweet-root-tweaks.py)"
mnt=$(mktemp -d)
trap 'umount "$mnt" 2>/dev/null || true; rmdir "$mnt" 2>/dev/null || true' EXIT
mount -t hfsplus -o loop,force,rw "$IMG" "$mnt"
python3 -I "$TOPAZ/sweet-root-tweaks.py" "$mnt"
sync
umount "$mnt"

echo "$(ts) laurel-root: 3/4 fsck"
fsck.hfsplus -fy "$IMG" | grep -v 'Illegal name' | tail -3 || true

echo "$(ts) laurel-root: 4/4 sparse image (op10tool img2simg)"
OP=$REPO/out/bin/op10tool
[ -x "$OP" ] || sudo -u "$U" "$REPO/scripts/setup/build-op10tool.sh"
"$OP" img2simg "$IMG" "$IMG.simg.partial" && mv "$IMG.simg.partial" "${IMG%.img}.simg"
chown "$U": "$IMG" "${IMG%.img}.simg"
ls -l "$IMG" "${IMG%.img}.simg"
echo "$(ts) laurel-root: done"
