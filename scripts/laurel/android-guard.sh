#!/bin/sh
# Mi A3: refuse what would damage Android's data on userdata. Called by every script that can write it. Exit 0 = go on; exit 3 = refused, one message, nothing done.
#   android-guard.sh userdata                a write of the whole partition (flash-root.sh, root-flash-test.sh, fastboot-drain.py)
#   android-guard.sh boot-image IMG          a flash of a boot image (flash-boot.sh, boot-test.sh): IMG needs the kernel of patch 2950, Lineage's header, and the gate of the writable boot
#   android-guard.sh running-ios             a write through a running iOS (root-update.sh, update-phone.sh): that iOS must have the fence on
#   android-guard.sh other-device            a script for the OnePlus 10 Pro (scripts/flash/*): the phone must say it is that phone, over adb or fastboot. Off, in iOS, no answer: refused
#   android-guard.sh other-device-fastboot   the same, in fastboot only: right before a write (the phone on the cable can have changed since the first check)
# Refused when config/laurel-android-data exists or when the phone itself shows Android over adb. There is no environment switch: removing the flag is a git change
# (the owner says Android's data is gone), and a phone that shows Android on adb is refused even then.
# boot-image: Lineage's own boot image (restore) goes with ANDROID_IMAGE=1. The hash must be the one in the backup, and the image must hold no iOS text.
# Dual boot path: docs/laurel_sprout/dual-boot.md.
set -eu
REPO=$(cd "$(dirname "$0")/../.." && pwd)
. "$REPO/scripts/lib/laurel-layout.sh"
FLAG=$REPO/config/laurel-android-data
PATHWAY="dual boot path: docs/laurel_sprout/dual-boot.md, scripts/laurel/dual-boot.sh"
# What the OnePlus 10 Pro NE2211 says: ro.product.device OP516FL1 (docs/backup-and-restore.md); fastboot product taro [I: SoC name, not read in this repo].
# A false refusal is what a wrong entry costs. A phone that says something else, or nothing, is not this phone.
ONEPLUS_DEVICES="OP516FL1"
ONEPLUS_PRODUCTS="OP516FL1 taro"

refuse() {
  echo "android-guard: REFUSED: $1" >&2
  echo "android-guard: $PATHWAY. Nothing was written." >&2
  exit 3
}
# A hung adb must not hang a flash script, and a machine with no timeout tool (stock macOS) must not turn this guard off: that would look like "no phone". Fail closed.
if command -v timeout >/dev/null 2>&1; then
  tm() { timeout "$@"; }
elif command -v gtimeout >/dev/null 2>&1; then
  tm() { gtimeout "$@"; }
elif command -v perl >/dev/null 2>&1; then
  tm() { perl -e 'alarm shift @ARGV; exec @ARGV or exit 127' "$@"; }
else
  refuse "no timeout, gtimeout or perl on this machine: this guard cannot ask the phone"
fi
command -v adb >/dev/null 2>&1 || refuse "no adb on this machine: this guard cannot ask the phone"
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
prop() { tm 8 adb shell getprop "$1" 2>/dev/null | tr -d '\r' || true; }
adb_on() { [ "$(tm 8 adb get-state 2>/dev/null || true)" = device ]; }
android_live() {   # the phone on adb runs Android on the Mi A3
  adb_on && [ "$(prop ro.product.device)" = laurel_sprout ] && [ -n "$(prop ro.build.version.release)" ]
}
flag_says() { [ -e "$FLAG" ]; }
one_of() { _w=$1; shift; for _x in "$@"; do [ "$_w" = "$_x" ] && return 0; done; return 1; }
# The phone in fastboot: one phone, and its answer is on the list. One getvar can answer wrongly on the Mi A3's ABL (docs/notes.md), so a wrong answer is asked again; only a right one passes.
oneplus_in_fastboot() {
  _f=$(tm 5 fastboot devices 2>/dev/null || true)
  [ -n "$_f" ] || { why="no phone in fastboot"; return 1; }
  [ "$(printf '%s\n' "$_f" | grep -c .)" = 1 ] || { why="more than one phone in fastboot"; return 1; }
  _p=
  for _ in 1 2 3; do
    _p=$(tm 10 fastboot getvar product 2>&1 | sed -n 's/^product: *//p' | tr -d '\r')
    # shellcheck disable=SC2086
    if one_of "$_p" $ONEPLUS_PRODUCTS; then return 0; fi
    [ "$_p" != laurel_sprout ] || break
    sleep 1
  done
  why="the phone in fastboot says product '${_p:-no answer}'"
  return 1
}
oneplus_on_adb() {
  adb_on || { why="no phone on adb"; return 1; }
  _p=$(prop ro.product.device)
  # shellcheck disable=SC2086
  if one_of "$_p" $ONEPLUS_DEVICES; then return 0; fi
  why="the phone on adb says device '${_p:-no answer}'"
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
    # What ANDROID_IMAGE=1 promises is checked. The text: a shim image has none of the UniXNU label (mkdarwinboot.py), so that label alone proves nothing.
    if LC_ALL=C grep -aqE 'LAURELESP|rd=ufsroot0|ufsrw=|rootrw=|Darwin Kernel Version|xnu-[0-9]+\.|SWEETXNU|LAUREL BUILD' "$img"; then refuse "ANDROID_IMAGE=1, but $img holds an iOS payload"; fi
    # The hash decides: only Lineage's boot image, as the backup lists it. A shim with a compressed kernel has no text to find. Then ufsrw=1 inside it writes to userdata.
    got=$(sha "$img"); ok=
    for f in "$LAUREL_BACKUP"/lineage-*/SHA256SUMS; do [ -f "$f" ] && grep -qE "^$got  boot\.img$" "$f" && ok=1; done
    for f in "$LAUREL_BACKUP"/android-*/SHA256SUMS; do [ -f "$f" ] && grep -qE "^$got  boot_a\.img$" "$f" && ok=1; done
    [ -n "$ok" ] || refuse "ANDROID_IMAGE=1, but $img (sha256 $got) is not Lineage's boot image in $LAUREL_BACKUP (lineage-*/SHA256SUMS boot.img, android-*/SHA256SUMS boot_a.img)"
    exit 0
  fi
  if ! flag_says && ! android_live; then exit 0; fi
  [ -f "$img.dualboot" ] || refuse "$img was not built for this phone (no $img.dualboot; build it with dual-boot.sh image; Lineage's own image: ANDROID_IMAGE=1)"
  got=$(sha "$img")
  want=$(sed -n 's/^image //p' "$img.dualboot")
  [ "$got" = "$want" ] || refuse "$img changed after it was built ($img.dualboot does not match): build it again"
  # A kernel without patch 2950 takes userdata as its root, and with ufsrw=1 it writes its console log there. The text is searched in the image: the kernel lies in the payload FAT uncompressed.
  m=$(sed -n 's/^#define LDB_KERNEL_MARKER *"\([^"]*\)".*/\1/p' "$REPO/tools/laurel-dualboot/laurel_dualboot.h")
  [ -n "$m" ] || refuse "no LDB_KERNEL_MARKER in tools/laurel-dualboot/laurel_dualboot.h"
  LC_ALL=C grep -aqF "$m" "$img" || refuse "$img holds no kernel with patch 2950 ($m): that kernel takes userdata as its root and writes its log into Android's data. Build the kernel, then the image"
  # S1: ABL gives TrustZone the OS version from this header (VerifiedBoot.c): the same as Lineage's. docs/laurel_sprout/dual-boot.md, keys.
  lb=$(laurel_backup_dir 'lineage-*')/boot.img
  [ -f "$lb" ] || refuse "no Lineage boot image in $LAUREL_BACKUP/lineage-*: the header of $img cannot be compared"
  [ "$(boot_os_raw "$img")" = "$(boot_os_raw "$lb")" ] || refuse "$img has OS version field $(boot_os_raw "$img"), Lineage ($lb) has $(boot_os_raw "$lb"): build it again with dual-boot.sh image"
  # The read-only first boot: an image that can write needs the recorded result. The boot-args lie as plain text in the payload FAT: laurel_can_write. A sidecar with no mode line counts as writable.
  mode=$(sed -n 's/^mode //p' "$img.dualboot")
  if [ "$mode" != ro ] || laurel_can_write < "$img"; then
    r=$REPO/out/laurel/dualboot/first-boot.result
    grep -q "^ro-on $m " "$r" 2>/dev/null || refuse "$img can write (ufsrw=1), and no read-only boot of this kernel fence has a recorded result (dual-boot.sh ro-result LOG; $r)"
    grep -q '^android-opened-after-ro ' "$r" 2>/dev/null || refuse "$img can write (ufsrw=1), and Android has not opened its data after the read-only iOS boot (dual-boot.sh android-check; $r)"
  fi
  ;;
running-ios)
  if ! flag_says && ! android_live; then exit 0; fi
  android_live && refuse "the phone runs Android, not iOS"
  # the kernel says whether its fence is on (patch 2950): nothing else counts, and no variable can stand in for it
  v=$("$REPO/scripts/laurel/phone-ssh.sh" sysctl -n kern.laurel_dualboot 2>/dev/null | tr -d '\r' || true)
  [ "$v" = 1 ] || refuse "userdata holds Android, and the running iOS does not report kern.laurel_dualboot=1 (got '${v:-no answer}')"
  ;;
other-device)
  why=
  if oneplus_on_adb; then exit 0; fi
  why1=$why
  if oneplus_in_fastboot; then exit 0; fi
  refuse "this script is for the OnePlus 10 Pro and no phone says it is that phone ($why1; $why). A phone off or in iOS is not known: start it in Android or fastboot"
  ;;
other-device-fastboot)
  why=
  oneplus_in_fastboot || refuse "this write is for the OnePlus 10 Pro: $why"
  ;;
*)
  sed -n 2,10p "$0" >&2; exit 2 ;;
esac
exit 0
