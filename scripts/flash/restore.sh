#!/bin/sh
# Back to stock Android on slot a (one command; run in tmux: make flash-restore).
#   CONFIRM=yes scripts/flash/restore.sh [--keep-userdata] [--magisk]
# Phone in bootloader fastboot mode (Volume up + Volume down + Power) or Android with adb.
# Flashes the stock boot_a (or the Magisk one with --magisk), vendor_boot_a, dtbo_a, vbmeta_a from
# ~/op10-backup/images, then `fastboot -w` (formats userdata; skip with --keep-userdata), set_active a.
set -eu
. "$(dirname "$0")/../lib/env.sh"
I=$BACKUP/images
[ "${CONFIRM:-}" = yes ] || { echo "this rewrites slot a boot partitions (and formats userdata): run with CONFIRM=yes" >&2; exit 1; }
WIPE=yes; BOOT=$I/boot.img
for a in "$@"; do
  case "$a" in
  --keep-userdata) WIPE=no ;;
  --magisk) BOOT=$BACKUP/magisk/boot_a-magisk-v30.7.img ;;
  esac
done
for f in "$BOOT" "$I/vendor_boot.img" "$I/dtbo.img" "$I/vbmeta.img"; do
  [ -f "$f" ] || { echo "missing $f" >&2; exit 1; }
done
if [ -n "$(adb devices | tail -n +2 | grep device)" ]; then adb reboot bootloader; fi
i=0; until [ -n "$(fastboot devices)" ]; do i=$((i+1)); [ $i -lt 120 ] || exit 1; sleep 1; done
if fastboot getvar is-userspace 2>&1 | grep -q "is-userspace: yes"; then
  fastboot reboot bootloader; sleep 5
  i=0; until [ -n "$(fastboot devices)" ]; do i=$((i+1)); [ $i -lt 120 ] || exit 1; sleep 1; done
fi
fastboot flash boot_a "$BOOT"
fastboot flash vendor_boot_a "$I/vendor_boot.img"
fastboot flash dtbo_a "$I/dtbo.img"
fastboot flash vbmeta_a "$I/vbmeta.img"
[ "$WIPE" = yes ] && fastboot -w
fastboot set_active a
fastboot reboot
echo "restored slot a to stock$( [ "$WIPE" = yes ] && echo ', userdata formatted')"
