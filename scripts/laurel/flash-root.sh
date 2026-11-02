#!/bin/sh
# Flash the iOS root (sparse HFS+ image) to the Mi A3 partition iosroot. No other partition: never userdata. Owner confirms first (dual-boot.sh install calls this).
#   scripts/bg.sh db-install env CONFIRM=install scripts/laurel/dual-boot.sh install      (always in tmux: 34 GB logical, about 19 GB of data)
#   scripts/laurel/flash-root.sh ROOT.simg
# Same session rules as flash-boot.sh (docs/notes.md): fastboot reboot bootloader first (a session entered with the buttons after a panic has a broken USB state), then the
# flash; -S 512M sends the image as sparse pieces (ABL max-download-size 768 MiB). ABL stops a sparse image over the partition size [V FastbootCmds.c HandleSparseImgFlash].
# After a big flash the Xiaomi ABL can hang (topaz NOTES.md:40): this script then says so; the owner re-enters fastboot with Power+VolDown.
# This script cannot know that the last piece was written. [V ABL FastbootCmds.c] ABL answers OKAY to a piece before it writes it, AcceptCmd (:3425) does not wait for the write when the command is a download and reads
# FlashResult (:3437) while the write runs, a piece written by SparseImgFlashThread (:1358) drops its result, and a `reboot` waits for the write (:3427) but stops only flash and download on a failed result.
# A `fastboot stage` here said "failed" with no write failure and "good" with one, so it is gone. The verdict is the read-back in Android: dual-boot.sh verify-root; dual-boot.sh switch refuses without it.
set -eu
. "$(dirname "$0")/../lib/env.sh"
. "$REPO/scripts/lib/laurel-layout.sh"
IMG=${1:?usage: flash-root.sh ROOT.simg}
[ -f "$IMG" ] || { echo "flash-root: missing $IMG" >&2; exit 1; }
ts() { date +%H:%M:%S; }
die() { echo "flash-root: REFUSED: $1. Nothing was written." >&2; exit 3; }
# the sparse header: magic, then blk_sz at byte 12 and total_blks at byte 16 (total_chunks is byte 20)
[ "$(LC_ALL=C od -An -tx4 -N4 "$IMG" | tr -d ' \n')" = ed26ff3a ] || die "$IMG is not a sparse image"
sz=$(LC_ALL=C od -An -tu4 -j12 -N4 "$IMG" | tr -d ' \n'); tb=$(LC_ALL=C od -An -tu4 -j16 -N4 "$IMG" | tr -d ' \n')
[ $((sz * tb)) -le "$IOSROOT_VOLUME_MAX" ] || die "$IMG holds $((sz * tb)) bytes: iosroot takes $IOSROOT_VOLUME_MAX and the console log"
# One phone in fastboot, and it says it is the Mi A3, with the partition of the plan. ABL answers getvar on stderr.
var() { fastboot getvar "$1" 2>&1 | sed -n "s/^$1: *//p" | tr -d '\r'; }
need_phone() {
  _f=$(fastboot devices) || die "fastboot devices failed"
  [ "$(printf '%s\n' "$_f" | grep -c fastboot)" = 1 ] || die "not exactly one phone in fastboot: $_f"
  _p=
  for _ in 1 2 3; do _p=$(var product); [ "$_p" = laurel_sprout ] && break; sleep 1; done
  [ "$_p" = laurel_sprout ] || die "the phone in fastboot says product '${_p:-no answer}', not laurel_sprout"
  size_of iosroot
  [ -n "$_s" ] || die "ABL names no partition iosroot after 3 tries. Run: fastboot reboot bootloader, then this step again. If a clean session says the same, the new table is not there: the GPT steps of docs/laurel_sprout/dual-boot.md"
  laurel_size_ok "$_s" || die "ABL gives iosroot the size '$_s' after 3 tries: not a number. Run: fastboot reboot bootloader, then this step again"
  [ "$((_s))" = "$IOSROOT_BYTES" ] || die "iosroot has $_s bytes, the plan has $IOSROOT_BYTES"
  size_of userdata
  laurel_size_ok "$_s" || die "ABL gives userdata the size '${_s:-no answer}' after 3 tries. Run: fastboot reboot bootloader, then this step again"
  [ "$((_s))" = "$USERDATA_BYTES" ] || die "userdata has $_s bytes, the plan has $USERDATA_BYTES"
}
# One getvar can answer wrongly on this ABL (docs/notes.md): asked again until the answer is a number; the last answer stays in _s.
size_of() {
  for _ in 1 2 3; do _s=$(var "partition-size:$1"); laurel_size_ok "$_s" && return 0; sleep 1; done
}
need_phone
echo "$(ts) flash-root: image $IMG ($((sz * tb)) bytes logical)"
echo "$(ts) flash-root: fastboot reboot bootloader (clean ABL session)"
fastboot reboot bootloader
n=0; until [ -n "$(fastboot devices)" ]; do n=$((n + 1)); [ "$n" -lt 60 ] || die "no phone in fastboot after the reboot"; sleep 2; done
sleep 2
need_phone
# From here iosroot is not what any earlier read-back saw: the record says so before the first byte goes out. A later `installed` line needs its own read-back.
mkdir -p "$OUT/laurel/dualboot"; echo "install-started $(date +%Y-%m-%dT%H:%M:%S) $IMG" >> "$OUT/laurel/dualboot/first-boot.result"
echo "$(ts) flash-root: flashing iosroot"
if ! fastboot -S 512M flash iosroot "$IMG"; then
  echo "$(ts) flash-root: flash failed: iosroot holds part of the image. Hold Power+VolDown for fastboot, then run this again: it starts again from the first piece." >&2
  exit 1
fi
echo "$(ts) flash-root: ABL took all pieces. This does not show that the last piece was written: dual-boot.sh verify-root decides"
# A reboot waits for the write of the last piece (:3427; 11 s on the 12 GB flash, logs/laurel-root-flash.log). A hang costs the limit, not the job. After the limit no write runs: a restart is safe.
_r=0; laurel_with_limit "${FLASH_REBOOT_LIMIT:-180}" fastboot reboot || _r=$?
case "$_r" in
0) ;;
124) echo "$(ts) flash-root: WARNING: ABL did not answer 'reboot' in ${FLASH_REBOOT_LIMIT:-180} s (it can hang after a big flash). No write runs now. Hold Power for a restart: Android starts. Then: dual-boot.sh verify-root" ;;
*) echo "$(ts) flash-root: WARNING: ABL did not take 'reboot' (exit $_r; it can hang after a big flash). Hold Power for a restart: Android starts. Then: dual-boot.sh verify-root" ;;
esac
echo "$(ts) flash-root: done"
