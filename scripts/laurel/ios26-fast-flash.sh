#!/bin/sh
# Mi A3: a new iOS 26 boot image with no stop in Android, for a phone whose active slot is b. Owner's yes first: it writes boot_b.
#   scripts/bg.sh ios26-fast scripts/laurel/ios26-fast-flash.sh [ro|rw]        (default rw)
#   EXTRA_ARGS=...   boot-args of this image, e.g. a kill switch
# From iOS (or a panic hold) to fastboot by USB control, boot_b, then a normal reboot: slot b stays active, so the phone starts iOS at once.
# Slot a and Android are not touched. Use it for a kernel or boot-image change only. dtbo_b stays: it holds the stock dtbo since flash-slot-b.
# It leaves out the proof that Android opens its data after an iOS boot: run scripts/laurel/ios26-retry.sh, which has that proof, after a change in the UFS write path or the fence (patch 2950).
set -eu
cd "$(dirname "$0")/../.."
M=${1:-rw}
[ "$M" != ro ] || M=
DB="sh scripts/laurel/dual-boot.sh"
say() { echo "$(date +%H:%M:%S) fast-flash: $*"; }
die() { say "STOP: $*"; exit 1; }
fb_ok() { timeout 3 fastboot devices 2>/dev/null | grep -q fastboot; }
wait_fb() { c=0; until fb_ok; do [ "$c" -lt "$1" ] || return 1; sleep 3; c=$((c + 1)); done; }
# [V phone 2026-11-02] After a button entry, every second command of the session can fail: ask up to 4 times.
fb_get() { for _t in 1 2 3 4; do _v=$(timeout 10 fastboot getvar "$1" 2>&1 | sed -n "s/^$1: *//p" | tr -d '\r'); [ -z "$_v" ] || { echo "$_v"; return 0; }; done; return 0; }

say "building the image"
$DB image $M > /tmp/fast-flash.$$ 2>&1 || { cat /tmp/fast-flash.$$; rm -f /tmp/fast-flash.$$; die "image failed"; }
tail -n 1 /tmp/fast-flash.$$; rm -f /tmp/fast-flash.$$
IMG=out/laurel-ios26/uefi${M:+-$M}/laurel-uefi-boot.img
[ -s "$IMG" ] || die "no image $IMG"
scripts/laurel/android-guard.sh boot-image "$IMG" || die "the Android guard refuses this image"
if ! fb_ok; then
  lsusb 2>/dev/null | grep -q '1209:0001' || die "no iOS on USB and no fastboot: boot iOS, or hold Power + Vol Down"
  say "asking iOS for fastboot"
  timeout 15 sshpass -p "${IOS_PASSWORD:-alpine}" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=6 root@192.168.7.2 sync 2>/dev/null || say "no sync over SSH (a panic hold has no SSH)"
  timeout 15 out/bin/op10tool ctl bootloader 2>&1 | tail -n 1
  wait_fb 100 || die "no fastboot in 5 minutes: hold Power + Vol Down"
fi
sleep 2
[ "$(fb_get product)" = laurel_sprout ] || die "fastboot: not the Mi A3"
[ "$(fb_get slot-count)" = 2 ] || die "fastboot: no two slots"
_cs=$(fb_get current-slot)
[ "$_cs" = b ] || die "current slot is '$_cs', not b: use scripts/laurel/ios26-retry.sh, which switches from Android"
say "writing boot_b"
fastboot flash boot_b "$IMG"
say "reboot into iOS"
timeout 15 fastboot reboot >/dev/null 2>&1 || say "ABL did not take reboot: hold Power"
say "done: slot b, iOS is booting"
