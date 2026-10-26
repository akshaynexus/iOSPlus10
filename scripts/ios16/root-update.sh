#!/bin/bash
# Update an existing iOS 16 root image without a full rebuild (macOS): APFS-clone IN to OUT (no extra
# space; IN stays as the fallback), mount OUT read-write with owners, run the named root hooks, clean up.
#   sudo scripts/ios16/root-update.sh IN.img OUT.img HOOK...
#   HOOK: metal | powermenu | negronigl | audio | ssh | haptics | bt | tweaks   (the same scripts that
#   root-finish.sh runs; tweaks = root-tweaks-extra.py, e.g. the FBLaunchWatchdogScale change)
#   e.g. sudo scripts/ios16/root-update.sh ~/op10-apple/ios16-root-new.img ~/op10-apple/ios16-root.img metal powermenu
# Environment for the hooks passes through (METAL_CLIENTS=..., SSH_PUBKEY=...). Then: scripts/ios16/root-simg.sh.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
IN=${1:?usage: $0 IN.img OUT.img HOOK...}; OUT=${2:?usage: $0 IN.img OUT.img HOOK...}; shift 2
[ $# -gt 0 ] || { echo "name at least one hook" >&2; exit 1; }
U=${SUDO_USER:-$USER}
REPO=$(cd "$(dirname "$0")/../.." && pwd)
[ -f "$IN" ] || { echo "missing $IN" >&2; exit 1; }
[ ! -e "$OUT" ] || { echo "refusing to overwrite $OUT" >&2; exit 1; }
for h in "$@"; do
  case $h in metal|powermenu|negronigl|audio|ssh|haptics|bt|tweaks) ;; *) echo "unknown hook $h" >&2; exit 1 ;; esac
done

cp -c "$IN" "$OUT"                    # APFS clone: shares blocks with IN until written
work=$(cd "$(mktemp -d /tmp/iosroot-upd.XXXX)" && pwd -P)
dev=""
cleanup() {
  if mount | grep -q " on $work/root "; then umount "$work/root" 2>/dev/null || umount -f "$work/root" 2>/dev/null || true; fi
  [ -n "$dev" ] && hdiutil detach -force "$dev" >/dev/null 2>&1 || true
  rmdir "$work/root" "$work" 2>/dev/null || true
}
trap cleanup EXIT
dev=$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$OUT" | awk 'NR==1{print $1}')
mkdir -p "$work/root"
mount -t hfs -o nobrowse "$dev" "$work/root"
R=$work/root
# a manual mount_hfs honors owners; check it (iOS needs root/mobile/_logd owners kept)
touch "$R/.owner-test"; chown 272:272 "$R/.owner-test"
[ "$(stat -f %u:%g "$R/.owner-test")" = 272:272 ] || { echo "owners are ignored on $R" >&2; exit 1; }
rm -f "$R/.owner-test"
mdutil -i off "$R" >/dev/null 2>&1 || true
[ -d "$R/System/Library/xpc" ] || { echo "$IN is not an iOS root" >&2; exit 1; }
[ -L "$R/var" ] || { echo "$R/var is not a symlink: stop" >&2; exit 1; }

# tweaks first: root-tweaks-extra.py rewrites the launchd cache (it drops bluetoothd), so bt must come after it
hooks=$(printf "%s\n" "$@" | grep -x tweaks || true); hooks="$hooks $(printf "%s\n" "$@" | grep -vx tweaks | tr "\n" " ")"
for h in $hooks; do
  echo "== hook $h"
  case $h in
    metal)     METAL=1 METAL_CLIENTS="${METAL_CLIENTS-*}" sh "$REPO/scripts/metal/root-add-metal.sh" "$R" ;;   # owner 2026-10-27: Metal for every process by default (METAL_CLIENTS="" keeps the root default list)
    powermenu) POWERMENU=1 sh "$REPO/scripts/ios16/root-add-powermenu.sh" "$R" ;;
    negronigl) NEGRONIGL=1 sh "$REPO/scripts/gpu/root-add-negronigl.sh" "$R" ;;
    audio)     AUDIO=1 sh "$REPO/scripts/audio/root-add-audio.sh" "$R" ;;
    ssh)       SSH=1 sh "$REPO/scripts/net/root-add-ssh.sh" "$R" ;;
    haptics)   HAPTICS=1 sh "$REPO/scripts/haptics/root-add-haptics.sh" "$R" ;;
    bt)        BT=1 sh "$REPO/scripts/bt/root-add-bt.sh" "$R" ;;
    tweaks)    python3 "$REPO/scripts/ios16/root-tweaks-extra.py" "$R" --migration "${MIGRATION:-skip}" ;;
  esac
done
[ -L "$R/var" ] || { echo "a hook replaced the /var symlink: stop (OUT is not usable)" >&2; exit 1; }

rm -rf "$R/.fseventsd" "$R/.Spotlight-V100" "$R/.Trashes" "$R/.metadata_never_index" "$R/.TemporaryItems"
df -h "$R" | tail -1
sync
umount "$R"
fsck_hfs -fy "$dev" || true
fsck_hfs -fn "$dev"
chown "$U" "$OUT"
ls -l "$OUT"
echo "next: AREAS=1 scripts/bg.sh simg scripts/ios16/root-simg.sh $OUT"
