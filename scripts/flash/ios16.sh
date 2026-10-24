#!/bin/sh
# Flash the iOS 16 boot chain, one approved step at a time (phone in bootloader fastboot mode).
#   scripts/flash/ios16.sh STEP [--yes]
# Without --yes a step only prints what it would do.
# ORDER: userdata first, from fastbootd (`adb reboot fastboot`), while vendor_boot/dtbo are still stock
# (fastbootd runs from the recovery, which needs them). fastbootd writes with AOSP libsparse; the
# OnePlus ABL's sparse flash lost writes beyond ~8 GiB on the NE2213, and the root has 11 GiB of data.
# Then the bootloader steps (`fastboot reboot bootloader`): vendor_boot, vbmeta, dtbo, boot, active.
# Steps:
#   check        fastboot device, mode (bootloader/fastbootd), slot, unlock state, battery (no write)
#   recovery     vendor_boot_a, dtbo_a <- stock (~/op10-backup/images), so fastbootd (in the recovery)
#                starts again when iOS is installed; the vendor_boot/dtbo steps write ours afterwards
#   vendor_boot  vendor_boot_a <- out/ios16/vendor_boot_a.img       (mainline DTB; ABL reads the DTB here)
#   vbmeta       vbmeta_a <- stock vbmeta.img with verity/verification disabled
#   dtbo         erase dtbo_a
#   boot         boot_a <- out/ios16/boot_a.img                      (shim + Mu UEFI + iOS payload)
#   userdata     userdata <- $APPLE/ios16-root.simg (fastbootd only; ERASES Android user data)
#   active       set slot a active, then reboot
# Restore any step: docs/backup-and-restore.md (stock images in ~/op10-backup/images).
set -eu
. "$(dirname "$0")/../lib/env.sh"
APPLE=${APPLE:-$HOME/op10-apple}
I=$BACKUP/images
O=${IOS16_OUT:-$OUT/ios16}       # e.g. IOS16_OUT=out/ios16-debug
STEP=${1:-}; YES=${2:-}

run() {
  echo "+ $*"
  if [ "$YES" = --yes ]; then "$@"; else echo "  (dry run: add --yes to execute)"; fi
}
need() { [ -f "$1" ] || { echo "missing $1" >&2; exit 1; }; }
present() { [ -n "$(fastboot devices)" ] || { echo "no device in fastboot mode" >&2; exit 1; }; }
userspace() { present; fastboot getvar is-userspace 2>&1 | grep -q 'is-userspace: yes'; }
bootloader() { ! userspace || { echo "phone is in fastbootd: run 'fastboot reboot bootloader' first" >&2; exit 1; }; }

case "$STEP" in
check)
  fastboot devices
  for v in product current-slot unlocked is-userspace battery-voltage battery-soc-ok; do
    fastboot getvar "$v" 2>&1 | grep -v Finished | head -1
  done ;;
recovery)    bootloader; need "$I/vendor_boot.img"; need "$I/dtbo.img"
             run fastboot flash vendor_boot_a "$I/vendor_boot.img"; run fastboot flash dtbo_a "$I/dtbo.img" ;;
vendor_boot) bootloader; need "$O/vendor_boot_a.img"; run fastboot flash vendor_boot_a "$O/vendor_boot_a.img" ;;
vbmeta)      bootloader; need "$I/vbmeta.img"; run fastboot --disable-verity --disable-verification flash vbmeta_a "$I/vbmeta.img" ;;
dtbo)        bootloader; run fastboot erase dtbo_a ;;
boot)        bootloader; need "$O/boot_a.img"; run fastboot flash boot_a "$O/boot_a.img" ;;
userdata)
  need "$APPLE/ios16-root.simg"
  userspace || { echo "phone is not in fastbootd: run 'adb reboot fastboot' (or 'fastboot reboot fastboot')" >&2; exit 1; }
  run fastboot flash userdata "$APPLE/ios16-root.simg" ;;   # fastboot splits to the device max-download-size (fastbootd: 256 MiB)
active)      bootloader; run fastboot set_active a; run fastboot reboot ;;
*) sed -n 2,19p "$0"; exit 1 ;;
esac
