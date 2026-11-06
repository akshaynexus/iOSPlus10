#!/bin/sh
# Mi A3: one more read-only (or rw) iOS 26 boot, from a phone that waits in fastboot after a panic or a hang.
#   scripts/bg.sh ios26-retry scripts/laurel/ios26-retry.sh [ro|rw]
# Owner: Power + Vol Down until the fastboot screen shows. This script then: slot a, Android must open its data
# (android-check), new boot image, boot_b + dtbo_b, Android must start, switch to slot b. Each write is a step of
# docs/laurel_sprout/dual-boot.md with its own guard. A session entered with the buttons can answer wrongly, so it is
# checked first. It never writes without a phone that answers laurel_sprout, and it stops at the first failure.
# Build the kernel first if the patches changed: scripts/laurel/kernel-ios26-linux.sh.
#   RESUME_FASTBOOT=1   start at the flash, from fastboot on slot a, after a run that passed android-check
#   FAST_SWITCH=1 ...   after boot_b + dtbo_b, switch to slot b from fastboot, with no Android boot in between (owner, 2026-11-07)
set -eu
cd "$(dirname "$0")/../.."
M=${1:-}
[ "$M" != ro ] || M=
DB="sh scripts/laurel/dual-boot.sh"
# [V 2026-11-02] Another Android phone can be on the same computer: every adb call goes to the Mi A3 by its serial, or stops.
mi_a3() { for _s in $(timeout 5 adb devices 2>/dev/null | sed -n 's/\tdevice$//p'); do [ "$(timeout 5 adb -s "$_s" shell getprop ro.product.device 2>/dev/null | tr -d '\r')" = laurel_sprout ] && { echo "$_s"; return 0; }; done; return 1; }
run() { "$@" > /tmp/ios26-retry.$$ 2>&1 || { cat /tmp/ios26-retry.$$; rm -f /tmp/ios26-retry.$$; die "failed: $*"; }; tail -n 1 /tmp/ios26-retry.$$; rm -f /tmp/ios26-retry.$$; }
say() { echo "$(date +%H:%M:%S) ios26-retry: $*"; }
die() { say "STOP: $*"; exit 1; }
fb_ok() { timeout 3 fastboot devices 2>/dev/null | grep -q fastboot; }
wait_fb() { c=0; until fb_ok; do [ "$c" -lt "$1" ] || return 1; sleep 3; c=$((c + 1)); done; }
# [V phone 2026-11-02] After a button entry, every second command of the session can fail: ask up to 4 times.
fb_get() { for _t in 1 2 3 4; do _v=$(timeout 10 fastboot getvar "$1" 2>&1 | sed -n "s/^$1: *//p" | tr -d '\r'); [ -z "$_v" ] || { echo "$_v"; return 0; }; done; return 0; }
wait_android() {
  c=0
  until _ser=$(mi_a3) && [ "$(timeout 5 adb -s "$_ser" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; do
    [ "$c" -lt 60 ] || return 1; sleep 5; c=$((c + 1))
  done
  ANDROID_SERIAL=$_ser; export ANDROID_SERIAL
}
# [V phone 2026-11-02] The installed switcher app (BootLockReceiver) restarts adbd at boot, and that undoes an earlier `adb root`. So root is read again right before each step that needs it, and it must hold for two reads 3 s apart.
adb_uid() { timeout 5 adb shell id -u 2>/dev/null | tr -d '\r'; }
to_root() {
  c=0
  while [ "$c" -lt 20 ]; do
    if [ "$(adb_uid)" = 0 ]; then sleep 3; [ "$(adb_uid)" = 0 ] && return 0; fi
    timeout 15 adb root >/dev/null 2>&1 || true
    sleep 3; c=$((c + 1))
  done
  return 1
}

say "building the image"
run $DB image $M
if [ "${RESUME_FASTBOOT:-0}" = 1 ]; then
  # A run that passed android-check and then met a wrong fastboot answer: the phone waits in fastboot on slot a.
  wait_fb 40 || die "RESUME_FASTBOOT=1: no fastboot"
  [ "$(fb_get product)" = laurel_sprout ] || die "RESUME_FASTBOOT=1: fastboot is not the Mi A3"
  [ "$(fb_get current-slot)" = a ] || die "RESUME_FASTBOOT=1: current slot is not a"
  say "resume from fastboot: android-check passed in the run before"
else
_ser=$(mi_a3 || true)
if [ -n "$_ser" ] && [ "$(timeout 5 adb -s "$_ser" shell getprop ro.boot.slot_suffix 2>/dev/null | tr -d '\r')" = _a ]; then
  ANDROID_SERIAL=$_ser; export ANDROID_SERIAL
  say "Android is already on slot a"
else
  # A panic hold answers on USB: this asks for fastboot with no buttons, and the session it gives is clean.
  if lsusb 2>/dev/null | grep -q '1209:0001'; then
    say "the kernel answers on USB: asking it for fastboot"
    timeout 15 out/bin/op10tool ctl bootloader 2>&1 | tail -n 1 || true
  fi
  say "waiting for fastboot: owner, hold Power + Vol Down if it does not come"
  wait_fb 400 || die "no fastboot in 20 minutes"
  sleep 2
  ok=0
  for i in 1 2 3 4 5 6; do
    if [ "$(fb_get slot-count)" = 2 ] && [ "$(fb_get product)" = laurel_sprout ]; then ok=1; break; fi
    say "the fastboot session answers wrongly, try $i"; sleep 2
  done
  [ "$ok" = 1 ] || die "the fastboot session stays wrong: run fastboot reboot bootloader, or hold Power + Vol Down again, then run this again"
  CONFIRM=to-android; export CONFIRM; run $DB to-android
fi
wait_android || die "Android did not finish booting: read the screen; do not accept a reset"
to_root || die "no adb root"
run $DB android-check
timeout 20 adb reboot bootloader
wait_fb 40 || die "no fastboot after adb reboot bootloader"
sleep 2
fi
CONFIRM=flash-slot-b; export CONFIRM
# [V phone 2026-11-03, 2026-11-07] ABL can give an empty partition-size:userdata for a whole session; flash-slot-b then
# stops before any write. A new session (fastboot reboot bootloader) answers again: up to 3 sessions.
_fs=1
until $DB flash-slot-b $M > /tmp/ios26-retry-fs.$$ 2>&1; do
  tail -n 2 /tmp/ios26-retry-fs.$$
  grep -q 'not numbers' /tmp/ios26-retry-fs.$$ && [ "$_fs" -lt 3 ] || { rm -f /tmp/ios26-retry-fs.$$; die "failed: $DB flash-slot-b $M"; }
  say "fastboot answered wrongly: a new session ($_fs of 2)"
  timeout 15 fastboot reboot bootloader >/dev/null 2>&1 || true
  sleep 8; wait_fb 40 || die "no fastboot after reboot bootloader"
  sleep 2; _fs=$((_fs + 1))
done
tail -n 1 /tmp/ios26-retry-fs.$$; rm -f /tmp/ios26-retry-fs.$$
if [ "${FAST_SWITCH:-0}" = 1 ]; then
  # Owner, 2026-11-07: skip the Android boot that only rechecks. Android was up a moment ago and passed android-check
  # (data opened, updater off), so slot a is the way back; the switch goes to slot b from this fastboot session.
  # [V phone 2026-11-02] set_active can fail a few times in a session: retry with pauses, as dual-boot.sh to-android.
  _try=0
  until timeout 15 fastboot set_active b >/dev/null 2>&1 && [ "$(fb_get current-slot)" = b ]; do
    _try=$((_try + 1))
    [ "$_try" -lt 10 ] || die "set_active b failed 10 times: boot_b is written, slot a stays active; run this again without FAST_SWITCH=1"
    sleep 3
  done
  say "slot b active from fastboot at $(date +%H:%M:%S) (FAST_SWITCH=1: no Android recheck)"
  timeout 15 fastboot reboot >/dev/null 2>&1 || say "ABL did not take reboot: hold Power"
  say "done: iOS 26 is booting. Read the panel; USB log: logs/usblog-*.txt"
  exit 0
fi
timeout 15 fastboot reboot >/dev/null 2>&1 || say "ABL did not take reboot: hold Power"
wait_android || die "Android did not start after flash-slot-b"
say "switching to iOS at $(date +%H:%M:%S)"
to_root || die "no adb root"
CONFIRM=switch; export CONFIRM; run $DB switch $M
say "done: iOS 26 is booting. Read the panel; USB log: logs/usblog-*.txt"
