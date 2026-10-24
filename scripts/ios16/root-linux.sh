#!/bin/bash
# Build the iOS 16.7.16 root (HFS+, case-sensitive, journaled) on Linux.
#   sudo scripts/ios16/root-linux.sh [OUT.img]        (default $APPLE/ios16-root.img)
#   in tmux:  scripts/bg.sh root sudo scripts/ios16/root-linux.sh   (tmux attach -t root for the password)
# Needs: apfs-fuse, hfsprogs (mkfs.hfsplus, fsck.hfsplus), rsync, the hfsplus kernel module, and the
# three DMGs in $APPLE/20H392 (scripts/ios16/fetch-dmgs.sh). Uses the port's tools/mkiosroot.sh
# (copy, dyld/cryptex links, logd stores, keybag), then scripts/ios16/root-finish.sh.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
U=${SUDO_USER:-$USER}
H=$(getent passwd "$U" | cut -d: -f6)
REPO=$(cd "$(dirname "$0")/../.." && pwd)
APPLE=${APPLE:-$H/op10-apple}
D=$APPLE/20H392
OUT=${1:-$APPLE/ios16-root.img}
for t in apfs-fuse mkfs.hfsplus fsck.hfsplus rsync; do
  command -v "$t" >/dev/null || { echo "missing $t (apt install apfs-fuse hfsprogs rsync)" >&2; exit 1; }
done
modprobe hfsplus

bash "$REPO/external/slop/tools/mkiosroot.sh" \
  "$D/087-86698-044.dmg" "$D/087-86593-047.dmg" "$D/087-86715-047.dmg" "$OUT" "${SIZE:-16G}"

mnt=$(mktemp -d)
fsck.hfsplus -fy "$OUT" | grep -v 'Illegal name' || true
mount -t hfsplus -o loop,force,rw "$OUT" "$mnt"
trap 'mountpoint -q "$mnt" && umount "$mnt"; rmdir "$mnt"' EXIT
bash "$REPO/scripts/ios16/root-finish.sh" "$mnt"
sync
umount "$mnt"
fsck.hfsplus -fy "$OUT" | grep -v 'Illegal name' || true
chown "$U:" "$OUT"
ls -l "$OUT"
echo "next: scripts/bg.sh simg scripts/ios16/root-simg.sh"
