#!/bin/sh
# Mi A3: refuse what would damage Android's data on userdata. Called by every script that can write it. Exit 0 = go on; exit 3 = refused, one message, nothing done.
#   android-guard.sh userdata          a write of the whole partition (flash-root.sh, root-flash-test.sh, fastboot-drain.py)
#   android-guard.sh boot-image IMG    a flash of a boot image (flash-boot.sh, boot-test.sh): IMG must carry an extent table
#   android-guard.sh running-ios       a write through a running iOS (root-update.sh, update-phone.sh): that iOS must have the fence on
#   android-guard.sh other-device      a script for another phone (scripts/flash/*): the Mi A3 must not be the phone on the cable
# Refused when config/laurel-android-data exists or when the phone itself shows Android over adb. There is no environment switch: removing the flag is a git change
# (the owner says Android's data is gone), and a phone that shows Android on adb is refused even then.
# boot-image: a plain Android boot image (restore) goes with ANDROID_IMAGE=1, which is named in the command and works for no iOS image.
# Dual boot path: docs/laurel_sprout/dual-boot.md.
set -eu
REPO=$(cd "$(dirname "$0")/../.." && pwd)
FLAG=$REPO/config/laurel-android-data
PATHWAY="dual boot path: docs/laurel_sprout/dual-boot.md, scripts/laurel/dual-boot.sh"

refuse() {
  echo "android-guard: REFUSED: $1" >&2
  echo "android-guard: $PATHWAY. Nothing was written." >&2
  exit 3
}
prop() { timeout 8 adb shell getprop "$1" 2>/dev/null | tr -d '\r' || true; }
adb_on() { [ "$(timeout 8 adb get-state 2>/dev/null || true)" = device ]; }
android_live() {   # the phone on adb runs Android on the Mi A3
  adb_on && [ "$(prop ro.product.device)" = laurel_sprout ] && [ -n "$(prop ro.build.version.release)" ]
}
flag_says() { [ -e "$FLAG" ]; }
mi_a3_on_cable() {
  if adb_on && [ "$(prop ro.product.device)" = laurel_sprout ]; then return 0; fi
  if [ -n "$(timeout 5 fastboot devices 2>/dev/null || true)" ]; then
    # one getvar can answer wrongly on this ABL (docs/notes.md): two tries
    for _ in 1 2; do
      timeout 10 fastboot getvar product 2>&1 | grep -q 'laurel_sprout' && return 0
    done
  fi
  return 1
}

case "${1:-}" in
userdata)
  android_live && refuse "the phone on adb runs Android: this script erases all of userdata"
  flag_says && refuse "config/laurel-android-data says userdata holds Android: this script erases all of it"
  ;;
boot-image)
  img=${2:?boot-image needs IMG}
  if [ "${ANDROID_IMAGE:-0}" = 1 ]; then
    # the promise of ANDROID_IMAGE=1 is checked: no UniXNU payload in the image
    if LC_ALL=C grep -aq 'LAURELESP' "$img"; then refuse "ANDROID_IMAGE=1, but $img holds an iOS payload"; fi
    exit 0
  fi
  if ! flag_says && ! android_live; then exit 0; fi
  [ -f "$img.dualboot" ] || refuse "$img has no extent table: its kernel would treat userdata as an iOS root (build it after dual-boot.sh map; a plain Android image: ANDROID_IMAGE=1)"
  got=$(sha256sum "$img" | cut -d' ' -f1)
  want=$(sed -n 's/^image //p' "$img.dualboot")
  [ "$got" = "$want" ] || refuse "$img changed after its table was added ($img.dualboot does not match): build it again"
  ;;
running-ios)
  if ! flag_says && ! android_live; then exit 0; fi
  android_live && refuse "the phone runs Android, not iOS"
  # the kernel says whether its fence is on (patch 2950): nothing else counts
  v=$("${PHONE_SSH:-$REPO/scripts/laurel/phone-ssh.sh}" sysctl -n kern.laurel_dualboot 2>/dev/null | tr -d '\r' || true)
  [ "$v" = 1 ] || refuse "userdata holds Android, and the running iOS does not report kern.laurel_dualboot=1 (got '${v:-no answer}')"
  ;;
other-device)
  mi_a3_on_cable && refuse "the phone on the cable is the Mi A3: this script is for the OnePlus 10 Pro"
  exit 0
  ;;
*)
  sed -n 2,9p "$0" >&2; exit 2 ;;
esac
exit 0
