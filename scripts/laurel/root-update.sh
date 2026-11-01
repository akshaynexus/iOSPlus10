#!/bin/sh
# Mi A3: update the running phone's iOS root in place over SSH. /private/var stays: Wi-Fi networks, settings, app data. docs/laurel_sprout/root-update.md.
#   scripts/bg.sh rupd scripts/laurel/root-update.sh                  update, verify, `ctl reboot`, then register apps (always in tmux)
#   scripts/laurel/root-update.sh --dry-run                           read the phone only: the list of changes and the bytes; no write
#   scripts/laurel/root-update.sh --list                              no phone: all paths of the delta
#   scripts/laurel/root-update.sh --rollback [ID]                     old files back from /var/root/laurel-rollback (SSH needed); then ctl reboot
#   scripts/laurel/root-update.sh --after-boot                        wait for SSH, register new apps, compare the root again
# Input: $APPLE/laurel-ios16-root.update, written by scripts/laurel/root.sh (sudo). No new mount, no sudo here.
# Same gate as a flash: root-manifest.py flash-check (run ended well, no missing feature, stages + kernel + boot image are one build); STALE_OK=1 goes on with the list.
# REBOOT=0: no reboot at the end (update-phone.sh flashes the kernel next). Refused with one line (exit 3) when only a full flash can do it: scripts/laurel/root-flash-test.sh.
set -eu
REPO=$(cd "$(dirname "$0")/../.." && pwd)
APPLE=${APPLE:-$HOME/op10-apple}
M=$REPO/scripts/laurel/root-manifest.py
MAIN=$REPO/scripts/laurel/rootupdate/main.py
UPD=${ROOT_UPDATE_DIR:-$APPLE/laurel-ios16-root.update}
SIDE=$APPLE/laurel-ios16-root.manifest
SIMG=$APPLE/laurel-ios16-root.simg
BOOTIMG=$REPO/out/laurel/uefi/laurel-uefi-boot.img
case "${1:-}" in
--rollback)
  "$REPO/scripts/laurel/android-guard.sh" running-ios
  exec python3 -I "$MAIN" --dir "$UPD" "$@" ;;
--list|--after-boot)
  exec python3 -I "$MAIN" --dir "$UPD" "$@" ;;
--dry-run)
  python3 -I "$M" flash-check "$SIDE" "$SIMG" "$BOOTIMG" || echo "root-update: note: this root would not pass the gate of a real run"
  exec python3 -I "$MAIN" --dir "$UPD" --sidecar "$SIDE" "$@" ;;
"")
  "$REPO/scripts/laurel/android-guard.sh" running-ios   # dual boot: only an iOS with the fence on; docs/laurel_sprout/dual-boot.md
  python3 -I "$M" flash-check "$SIDE" "$SIMG" "$BOOTIMG" || { echo "root-update: nothing changed: the gate above failed" >&2; exit 1; }
  exec python3 -I "$MAIN" --dir "$UPD" --sidecar "$SIDE" ;;
*)
  sed -n 2,9p "$0" >&2; exit 2 ;;
esac
