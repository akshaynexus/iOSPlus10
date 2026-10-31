#!/bin/sh
# Flash a boot image to the Mi A3 (laurel_sprout) boot_b with plain fastboot, then reboot.
#   scripts/bg.sh laurel-flash scripts/laurel/flash-boot.sh [BOOT.img]      (always in tmux: no timeout)
#   default image out/laurel/laurel-boot.img; restore: BOOTIMG=~/laurel-backup/stock/images/boot.img
#   WAIT_NEW=1 (default): wait for a NEW fastboot USB connection first (put the phone in fastboot after start)
# The phone's ABL quirks (docs/notes.md, 2026-10-31):
#   * it keeps the tail of a longer previous command; 'getvar:max-download-size' right before 'download:'
#     garbles the size -> "more than max allowed". '-S' skips that getvar.
#   * downloads of 16 MiB or more stop in sessions entered after a panic; '-S 8M' sends pieces < 16 MiB.
#   * it can be very slow (an 8 MiB piece took > 30 s): no timeout here.
#   * no getvar before the flash; ~1 in 5 commands gets "unknown command": the flash is tried up to 3 times.
set -eu
. "$(dirname "$0")/../lib/env.sh"
IMG=${1:-${BOOTIMG:-$OUT/laurel/laurel-boot.img}}
[ -f "$IMG" ] || { echo "flash-boot: missing $IMG" >&2; exit 1; }
ts() { date +%H:%M:%S; }
cur() { lsusb | awk '/18d1:d00d/{print $4}'; }

if [ "${WAIT_NEW:-1}" = 1 ]; then
  old=$(cur)
  echo "$(ts) flash-boot: waiting for a new fastboot connection (now: ${old:-none})"
  while :; do c=$(cur); [ -n "$c" ] && [ "$c" != "$old" ] && break; sleep 1; done
  sleep 2
fi
echo "$(ts) flash-boot: $(fastboot --version | head -1); image $IMG ($(stat -c %s "$IMG") bytes)"
n=0
until fastboot -S 8M flash boot_b "$IMG"; do
  n=$((n + 1))
  [ $n -lt 3 ] || { echo "$(ts) flash-boot: flash failed 3 times" >&2; exit 1; }
  echo "$(ts) flash-boot: flash failed, try $((n + 1))"
  sleep 2
done
echo "$(ts) flash-boot: flashed boot_b"
fastboot reboot || { sleep 1; fastboot reboot; }
echo "$(ts) flash-boot: rebooted"
