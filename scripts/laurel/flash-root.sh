#!/bin/sh
# Flash the iOS root (sparse HFS+ image) to the Mi A3 userdata. ERASES Android's user data: owner confirms first.
#   scripts/bg.sh laurel-root-flash scripts/laurel/flash-root.sh [ROOT.simg]     (always in tmux: ~10 min)
#   default ~/op10-apple/laurel-ios16-root.simg (scripts/laurel/root.sh). Restore Android: stock ROM userdata.img.
# Same session rules as flash-boot.sh (docs/notes.md): fastboot reboot bootloader first (a session entered with
# the buttons after a panic has a broken USB state), then the flash; -S 512M sends the 12 GB image as sparse
# pieces (ABL max-download-size 768 MiB). After a big flash the Xiaomi ABL can hang (topaz NOTES.md:40): this
# script then stops and says so; the owner re-enters fastboot with Power+VolDown.
set -eu
. "$(dirname "$0")/../lib/env.sh"
APPLE=${APPLE:-$HOME/op10-apple}
IMG=${1:-$APPLE/laurel-ios16-root.simg}
[ -f "$IMG" ] || { echo "flash-root: missing $IMG (scripts/laurel/root.sh)" >&2; exit 1; }
ts() { date +%H:%M:%S; }
cur() { lsusb | awk '/18d1:d00d/{print $4}'; }
wait_dev() { while :; do c=$(cur); [ -n "$c" ] && [ "$c" != "$1" ] && { echo "$c"; return; }; sleep 1; done; }

echo "$(ts) flash-root: waiting for the phone in fastboot"
d=$(wait_dev "")
echo "$(ts) flash-root: $(fastboot --version | head -1); image $IMG ($(stat -c %s "$IMG") bytes)"
echo "$(ts) flash-root: fastboot reboot bootloader (clean ABL session)"
fastboot reboot bootloader
d=$(wait_dev "$d"); sleep 2
echo "$(ts) flash-root: new session $d: flashing userdata"
if ! fastboot -S 512M flash userdata "$IMG"; then
  echo "$(ts) flash-root: flash failed. Hold Power+VolDown for fastboot, then run this script again." >&2
  exit 1
fi
echo "$(ts) flash-root: userdata flashed"
fastboot reboot || echo "$(ts) flash-root: ABL did not take 'reboot' (it can hang after a big flash): hold Power for a restart"
echo "$(ts) flash-root: done"
