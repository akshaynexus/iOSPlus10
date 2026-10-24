#!/bin/sh
# Flash the whole iOS 16 boot chain in the right order (one command; run it in tmux: make flash).
#   CONFIRM=yes scripts/flash/all.sh [--skip-userdata]
# Phone: Android with USB debugging, or in fastbootd / bootloader fastboot mode (from iOS: hold
# Volume Up + Volume Down + Power until the bootloader appears).
#  0. bootloader (only when the phone is not in Android or fastbootd, e.g. iOS is installed):
#     stock vendor_boot_a + dtbo_a, so the recovery's fastbootd starts
#  1. fastbootd:  userdata <- iOS root (fastboot splits it to the device's 256 MiB download limit)
#  2. bootloader: vendor_boot_a, vbmeta_a (verification off), erase dtbo_a, boot_a
#  3. set slot a active, reboot
# userdata goes first: fastbootd runs from the recovery, which still needs the stock vendor_boot/dtbo.
# --skip-userdata: only step 2-3 (e.g. after a new boot image; the iOS root stays).
# ERASES Android user data (step 1). Way back: scripts/flash/restore.sh.
set -eu
. "$(dirname "$0")/../lib/env.sh"
F=$REPO/scripts/flash/ios16.sh
[ "${CONFIRM:-}" = yes ] || { echo "this writes boot_a, vendor_boot_a, vbmeta_a, dtbo_a and userdata: run with CONFIRM=yes" >&2; exit 1; }

wait_fastboot() {   # $1 = yes (fastbootd) | no (bootloader)
  i=0
  until [ -n "$(fastboot devices)" ] && fastboot getvar is-userspace 2>&1 | grep -q "is-userspace: $1"; do
    i=$((i + 1)); [ $i -lt 120 ] || { echo "phone did not reach fastboot mode (userspace=$1)" >&2; exit 1; }
    sleep 1
  done
}
to_fastbootd() {
  if [ -n "$(adb devices | tail -n +2 | grep device)" ]; then adb reboot fastboot
  elif [ -n "$(fastboot devices)" ]; then fastboot reboot fastboot
  else echo "no phone found (adb or fastboot)" >&2; exit 1; fi
  wait_fastboot yes
}
to_bootloader() {
  if [ -n "$(adb devices | tail -n +2 | grep device)" ]; then adb reboot bootloader
  else fastboot reboot bootloader; fi
  wait_fastboot no
}

if [ "${1:-}" != --skip-userdata ]; then
  echo "== 1/3 userdata (fastbootd)"
  if ! fastboot getvar is-userspace 2>&1 | grep -q "is-userspace: yes"; then
    if [ -z "$(adb devices | tail -n +2 | grep device)" ] && [ -n "$(fastboot devices)" ]; then
      echo "== 0/3 stock vendor_boot_a + dtbo_a (bootloader), so fastbootd can start"
      "$F" recovery --yes
    fi
    to_fastbootd
  fi
  "$F" userdata --yes
  to_bootloader
else
  echo "== userdata skipped"
  if [ -z "$(fastboot devices)" ] || fastboot getvar is-userspace 2>&1 | grep -q "is-userspace: yes"; then to_bootloader; fi
fi

echo "== 2/3 boot partitions (bootloader)"
for s in vendor_boot vbmeta dtbo boot; do "$F" "$s" --yes; done
echo "== 3/3 set slot a active, reboot"
"$F" active --yes
echo "done: first boot. Expect the OnePlus logo, then Mu-Silicium, then the iOS kernel log."
