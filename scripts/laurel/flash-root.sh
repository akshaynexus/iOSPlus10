#!/bin/sh
# Flash the iOS root (sparse HFS+ image) to the Mi A3 partition iosroot. No other partition: never userdata. Owner confirms first (dual-boot.sh install calls this).
#   scripts/bg.sh db-install env CONFIRM=install scripts/laurel/dual-boot.sh install      (always in tmux: 34 GB logical, about 19 GB of data)
#   scripts/laurel/flash-root.sh ROOT.simg
# Same session rules as flash-boot.sh (docs/notes.md): fastboot reboot bootloader first (a session entered with the buttons after a panic has a broken USB state), then the
# flash; -S 512M sends the image as sparse pieces (ABL max-download-size 768 MiB). ABL stops a sparse image over the partition size [V FastbootCmds.c HandleSparseImgFlash].
# After a big flash the Xiaomi ABL can hang (topaz NOTES.md:40): this script then says so; the owner re-enters fastboot with Power+VolDown.
set -eu
. "$(dirname "$0")/../lib/env.sh"
. "$REPO/scripts/lib/laurel-layout.sh"
IMG=${1:?usage: flash-root.sh ROOT.simg}
[ -f "$IMG" ] || { echo "flash-root: missing $IMG" >&2; exit 1; }
ts() { date +%H:%M:%S; }
die() { echo "flash-root: REFUSED: $1. Nothing was written." >&2; exit 3; }
# the sparse header: magic, then blk_sz at byte 12 and total_blks at byte 20
[ "$(LC_ALL=C od -An -tx4 -N4 "$IMG" | tr -d ' \n')" = ed26ff3a ] || die "$IMG is not a sparse image"
sz=$(LC_ALL=C od -An -tu4 -j12 -N4 "$IMG" | tr -d ' \n'); tb=$(LC_ALL=C od -An -tu4 -j20 -N4 "$IMG" | tr -d ' \n')
[ $((sz * tb)) -le "$IOSROOT_VOLUME_MAX" ] || die "$IMG holds $((sz * tb)) bytes: iosroot takes $IOSROOT_VOLUME_MAX and the console log"
# One phone in fastboot, and it says it is the Mi A3, with the partition of the plan. ABL answers getvar on stderr.
var() { fastboot getvar "$1" 2>&1 | sed -n "s/^$1: *//p" | tr -d '\r'; }
need_phone() {
  _f=$(fastboot devices) || die "fastboot devices failed"
  [ "$(printf '%s\n' "$_f" | grep -c fastboot)" = 1 ] || die "not exactly one phone in fastboot: $_f"
  _p=
  for _ in 1 2 3; do _p=$(var product); [ "$_p" = laurel_sprout ] && break; sleep 1; done
  [ "$_p" = laurel_sprout ] || die "the phone in fastboot says product '${_p:-no answer}', not laurel_sprout"
  _s=$(var partition-size:iosroot)
  [ -n "$_s" ] || die "the phone has no partition iosroot: run the GPT steps of docs/laurel_sprout/dual-boot.md"
  [ "$((_s))" = "$IOSROOT_BYTES" ] || die "iosroot has $_s bytes, the plan has $IOSROOT_BYTES"
  _s=$(var partition-size:userdata)
  [ "$((_s))" = "$USERDATA_BYTES" ] || die "userdata has ${_s:-no answer} bytes, the plan has $USERDATA_BYTES"
}
need_phone
echo "$(ts) flash-root: image $IMG ($((sz * tb)) bytes logical)"
echo "$(ts) flash-root: fastboot reboot bootloader (clean ABL session)"
fastboot reboot bootloader
n=0; until [ -n "$(fastboot devices)" ]; do n=$((n + 1)); [ "$n" -lt 60 ] || die "no phone in fastboot after the reboot"; sleep 2; done
sleep 2
need_phone
echo "$(ts) flash-root: flashing iosroot"
if ! fastboot -S 512M flash iosroot "$IMG"; then
  echo "$(ts) flash-root: flash failed. Hold Power+VolDown for fastboot, then run this again." >&2
  exit 1
fi
echo "$(ts) flash-root: iosroot flashed"
fastboot reboot || echo "$(ts) flash-root: ABL did not take 'reboot' (it can hang after a big flash): hold Power for a restart"
echo "$(ts) flash-root: done"
