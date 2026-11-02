#!/bin/bash
# Mi A3: a whole iOS 26 update, in order: builds, then root + boot image on the phone. Owner's yes first: it writes iosroot, boot_b and dtbo_b.
#   scripts/bg.sh ios26-update scripts/laurel/ios26-full-update.sh
#   WAIT_JOB=NAME        wait for the tmux job NAME (logs/NAME.exit) first; it must end with 0
#   NO_BUILD=1           no Mu or root build: use what is there
#   EXTRA_ARGS=...       boot-args of this image, e.g. a kill switch
# Every write goes through a guarded step of scripts/laurel/dual-boot.sh (docs/laurel_sprout/dual-boot.md). It stops at the first failure and never runs a step the guards refuse.
# Android stays usable while the builds run. The phone reboots by itself at the last part, and ends in iOS.
set -euo pipefail
cd "$(dirname "$0")/../.."
D="sh scripts/laurel/dual-boot.sh"
say() { echo "$(date +%H:%M:%S) full-update: $*"; }
die() { say "STOP: $*"; exit 1; }
# [V 2026-11-02] Another Android phone can be on the same computer: every adb call goes to the Mi A3 by serial.
mi_a3() { for _s in $(timeout 5 adb devices 2>/dev/null | sed -n 's/\tdevice$//p'); do [ "$(timeout 5 adb -s "$_s" shell getprop ro.product.device 2>/dev/null | tr -d '\r')" = laurel_sprout ] && { echo "$_s"; return 0; }; done; return 1; }
fb_ok() { timeout 3 fastboot devices 2>/dev/null | grep -q fastboot; }
wait_fb() { local c=0; until fb_ok; do [ "$c" -lt "$1" ] || return 1; sleep 3; c=$((c + 1)); done; }
fb_get() { local v; for _t in 1 2 3 4; do v=$(timeout 10 fastboot getvar "$1" 2>&1 | sed -n "s/^$1: *//p" | tr -d '\r'); [ -z "$v" ] || { echo "$v"; return 0; }; done; return 0; }
wait_android() {
  local c=0 s=""
  until s=$(mi_a3) && [ "$(timeout 5 adb -s "$s" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; do
    [ "$c" -lt 120 ] || return 1; sleep 5; c=$((c + 1))
  done
  ANDROID_SERIAL=$s; export ANDROID_SERIAL
}
to_root() {
  local c=0
  while [ "$c" -lt 20 ]; do
    if [ "$(timeout 5 adb shell id -u 2>/dev/null | tr -d '\r')" = 0 ]; then sleep 3; [ "$(timeout 5 adb shell id -u 2>/dev/null | tr -d '\r')" = 0 ] && return 0; fi
    timeout 15 adb root >/dev/null 2>&1 || true; sleep 3; c=$((c + 1))
  done
  return 1
}
# A session entered with the buttons can answer wrongly: the same check as ios26-retry.sh.
fastboot_to_android() {
  local ok=0
  sleep 2
  for i in 1 2 3 4 5 6; do
    if [ "$(fb_get slot-count)" = 2 ] && [ "$(fb_get product)" = laurel_sprout ]; then ok=1; break; fi
    say "the fastboot session answers wrongly, try $i"; sleep 2
  done
  [ "$ok" = 1 ] || die "the fastboot session stays wrong: fastboot reboot bootloader, or hold Power + Vol Down, then run this again"
  CONFIRM=to-android $D to-android | tail -n 1
}

# 1. Android now: the conversion must not run with the phone waiting in fastboot (dual-boot.md step 6).
if fb_ok; then say "phone in fastboot: to Android for the builds"; fastboot_to_android; fi

# 2. Builds
if [ -n "${WAIT_JOB:-}" ]; then
  say "waiting for job $WAIT_JOB"
  until [ -s "logs/$WAIT_JOB.exit" ]; do sleep 10; done
  [ "$(cat "logs/$WAIT_JOB.exit")" = 0 ] || die "job $WAIT_JOB ended with $(cat "logs/$WAIT_JOB.exit"): logs/$WAIT_JOB.log"
fi
if [ "${NO_BUILD:-0}" != 1 ]; then
  say "Mu and the root"
  bash scripts/laurel/mu-build.sh DEBUG > logs/full-update-mu.log 2>&1 &
  mu=$!
  FORCE=1 bash scripts/laurel/ios26-root.sh > logs/full-update-root.log 2>&1 &
  rt=$!
  rc=0
  wait "$mu" || rc=1
  [ "$rc" = 0 ] || { wait "$rt" || true; die "Mu build failed: logs/full-update-mu.log"; }
  wait "$rt" || die "root build failed: logs/full-update-root.log"
  grep -a -E 'all checks OK|failed|FAILED' logs/full-update-root.log | tail -n 1 || true
fi

# 3. Root on the phone
wait_android || die "no Android on the Mi A3: read the screen"
to_root || die "no adb root"
say "prepare-root"
$D prepare-root | tail -n 1
say "fastboot for the root"
timeout 20 adb reboot bootloader
wait_fb 60 || die "no fastboot after adb reboot bootloader"
sleep 2
say "install: writes iosroot"
CONFIRM=install $D install | tail -n 1
timeout 15 fastboot reboot >/dev/null 2>&1 || say "ABL did not take reboot: hold Power"
wait_android || die "Android did not start after install: read the screen"
to_root || die "no adb root"
say "verify-root"
$D verify-root | tail -n 2
unset ANDROID_SERIAL

# 4. New boot image, to iOS
say "boot image and switch"
env LAUREL_PANIC_SECS=0 scripts/laurel/ios26-retry.sh rw
say "done: iOS 26 is booting"
