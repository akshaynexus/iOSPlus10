#!/bin/sh
# Mi A3: one more read-only (or rw) iOS 26 boot, from a phone that waits in fastboot after a panic or a hang.
#   scripts/bg.sh ios26-retry scripts/laurel/ios26-retry.sh [ro|rw]
# Owner: Power + Vol Down until the fastboot screen shows. This script then: slot a, Android must open its data
# (android-check), new boot image, boot_b + dtbo_b, Android must start, switch to slot b. Each write is a step of
# docs/laurel_sprout/dual-boot.md with its own guard. A session entered with the buttons can answer wrongly, so it is
# checked first. It never writes without a phone that answers laurel_sprout, and it stops at the first failure.
# Build the kernel first if the patches changed: scripts/laurel/kernel-ios26-linux.sh.
set -eu
cd "$(dirname "$0")/../.."
M=${1:-}
[ "$M" != ro ] || M=
DB="sh scripts/laurel/dual-boot.sh"
say() { echo "$(date +%H:%M:%S) ios26-retry: $*"; }
die() { say "STOP: $*"; exit 1; }
fb_ok() { timeout 3 fastboot devices 2>/dev/null | grep -q fastboot; }
wait_fb() { c=0; until fb_ok; do [ "$c" -lt "$1" ] || return 1; sleep 3; c=$((c + 1)); done; }
fb_get() { timeout 10 fastboot getvar "$1" 2>&1 | sed -n "s/^$1: *//p" | tr -d '\r'; }
wait_android() {
  c=0
  until [ "$(timeout 3 adb get-state 2>/dev/null)" = device ] && [ "$(timeout 5 adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; do
    [ "$c" -lt 60 ] || return 1; sleep 5; c=$((c + 1))
  done
}
to_root() { timeout 15 adb root >/dev/null 2>&1 || true; sleep 3; c=0; until [ "$(timeout 3 adb get-state 2>/dev/null)" = device ]; do [ "$c" -lt 20 ] || return 1; sleep 2; c=$((c + 1)); done; }

say "building the image"
$DB image $M 2>&1 | tail -n 1
if [ "$(timeout 3 adb get-state 2>/dev/null || true)" = device ] && [ "$(timeout 5 adb shell getprop ro.boot.slot_suffix 2>/dev/null | tr -d '\r')" = _a ]; then
  say "Android is already on slot a"
else
  say "waiting for fastboot: owner, hold Power + Vol Down"
  wait_fb 400 || die "no fastboot in 20 minutes"
  sleep 2
  ok=0
  for i in 1 2 3 4 5 6; do
    if [ "$(fb_get slot-count)" = 2 ] && [ "$(fb_get product)" = laurel_sprout ]; then ok=1; break; fi
    say "the fastboot session answers wrongly, try $i"; sleep 2
  done
  [ "$ok" = 1 ] || die "the fastboot session stays wrong: run fastboot reboot bootloader, or hold Power + Vol Down again, then run this again"
  CONFIRM=to-android $DB to-android 2>&1 | tail -n 1
fi
wait_android || die "Android did not finish booting: read the screen; do not accept a reset"
to_root || die "no adb root"
$DB android-check 2>&1 | tail -n 1
timeout 20 adb reboot bootloader
wait_fb 40 || die "no fastboot after adb reboot bootloader"
sleep 2
CONFIRM=flash-slot-b $DB flash-slot-b $M 2>&1 | tail -n 1
timeout 15 fastboot reboot >/dev/null 2>&1 || say "ABL did not take reboot: hold Power"
wait_android || die "Android did not start after flash-slot-b"
to_root || die "no adb root"
say "switching to iOS at $(date +%H:%M:%S)"
CONFIRM=switch $DB switch $M 2>&1 | tail -n 1
say "done: iOS 26 is booting. Read the panel; USB log: logs/usblog-*.txt"
