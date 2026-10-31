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
bash "$TOPAZ/mkiosroot.sh" "$D/087-86698-044.dmg" "$D/087-86593-047.dmg" "$D/087-86715-047.dmg" "$IMG" "${SIZE:-16G}"

echo "$(ts) laurel-root: 2/4 root tweaks (topaz sweet-root-tweaks.py)"
mnt=$(mktemp -d)
trap 'umount "$mnt" 2>/dev/null || true; rmdir "$mnt" 2>/dev/null || true' EXIT
mount -t hfsplus -o loop,force,rw "$IMG" "$mnt"
python3 -I "$TOPAZ/sweet-root-tweaks.py" "$mnt"
sync
umount "$mnt"

echo "$(ts) laurel-root: 3/4 fsck"
fsck.hfsplus -fy "$IMG" | grep -v 'Illegal name' || true

echo "$(ts) laurel-root: 4/4 sparse image (op10tool img2simg)"
OP=$REPO/out/bin/op10tool
[ -x "$OP" ] || sudo -u "$U" "$REPO/scripts/setup/build-op10tool.sh"
"$OP" img2simg "$IMG" "$IMG.simg.partial" && mv "$IMG.simg.partial" "${IMG%.img}.simg"
chown "$U": "$IMG" "${IMG%.img}.simg"
ls -l "$IMG" "${IMG%.img}.simg"
echo "$(ts) laurel-root: done"
