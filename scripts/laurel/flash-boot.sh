#!/bin/sh
# Flash a boot image to the Mi A3 (laurel_sprout) boot_b with plain fastboot, then reboot.
#   scripts/bg.sh laurel-flash scripts/laurel/flash-boot.sh [BOOT.img]      (always in tmux: no timeout)
#   default image out/laurel/laurel-boot.img; restore: BOOTIMG=~/laurel-backup/stock/images/boot.img
#   WAIT_NEW=1 (default): wait for a NEW fastboot USB connection first (put the phone in fastboot after start)
#   REBOOT=0: do not reboot after the flash
# Why 'fastboot reboot bootloader' first (docs/notes.md, 2026-10-31): a fastboot session entered with
# Power+VolDown (after a panic of our kernel) has a broken ABL USB state: commands get the tail of
# the previous command ('download:' size garbled -> "more than max allowed"), ~1 in 5 commands is
# "unknown command", downloads stop at 16 MiB (the ABL USB rx chunk, USB_BUFFER_SIZE) or hang, and
# the session dies. A warm reset with the bootloader reason ('fastboot reboot bootloader', 4 s, or
# 'adb reboot bootloader') gives a clean ABL: the plain full-size flash then takes 0.5 s.
# 'reboot-bootloader' is 17 chars like 'download:010a8000', so the broken session still parses it.
set -eu
. "$(dirname "$0")/../lib/env.sh"
IMG=${1:-${BOOTIMG:-$OUT/laurel/laurel-boot.img}}
[ -f "$IMG" ] || { echo "flash-boot: missing $IMG" >&2; exit 1; }
ts() { date +%H:%M:%S; }
cur() { lsusb | awk '/18d1:d00d/{print $4}'; }
wait_dev() {   # wait for a fastboot device other than $1
  while :; do c=$(cur); [ -n "$c" ] && [ "$c" != "$1" ] && break; sleep 1; done
  sleep 2
}

old=$(cur)
if [ "${WAIT_NEW:-1}" = 1 ]; then
  echo "$(ts) flash-boot: waiting for a new fastboot connection (now: ${old:-none})"
  wait_dev "$old"
elif [ -z "$old" ]; then
  echo "$(ts) flash-boot: waiting for a fastboot connection"; wait_dev ""
fi
echo "$(ts) flash-boot: $(fastboot --version | head -1); image $IMG ($(stat -c %s "$IMG") bytes)"

# Clean ABL session: warm reset into the bootloader, then wait for the new USB device.
old=$(cur)
echo "$(ts) flash-boot: fastboot reboot bootloader (clean ABL session)"
fastboot reboot bootloader
wait_dev "$old"
echo "$(ts) flash-boot: new session $(cur)"

n=0
until fastboot flash boot_b "$IMG"; do
  n=$((n + 1))
  [ $n -lt 3 ] || { echo "$(ts) flash-boot: flash failed 3 times" >&2; exit 1; }
  echo "$(ts) flash-boot: flash failed, try $((n + 1)) after another reboot bootloader"
  old=$(cur); fastboot reboot bootloader || true; wait_dev "$old"
done
echo "$(ts) flash-boot: flashed boot_b"
[ "${REBOOT:-1}" = 1 ] || exit 0
fastboot reboot || { sleep 1; fastboot reboot; }
echo "$(ts) flash-boot: rebooted"
