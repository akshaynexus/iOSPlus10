#!/bin/sh
# Mi A3: read the persistent console log (topaz kernel patch 0047, boot-arg ufsrw=1) from the
# last 4 MiB + 1 block of the userdata partition. Port of external/ios-topaz/tools/sweet-log-pull.sh
# (the decoder tools/sweet-log.py is used as is). Needs a shell with block-device access over adb:
# a recovery (TWRP/OrangeFox flashed to boot_b: owner approval, see docs/backup-and-restore.md) or
# Android with root. Only reads. Our iOS root (16 GiB HFS+) ends long before the partition tail.
#   scripts/laurel/log-pull.sh logs/laurel-sweetlog-$(date +%H%M).txt
set -eu
. "$(dirname "$0")/../lib/env.sh"
out=${1:?usage: log-pull.sh OUT.txt}
blocks=1025
dev=$(adb shell 'for d in /dev/block/by-name/userdata /dev/block/bootdevice/by-name/userdata; do [ -e $d ] && readlink -f $d && break; done' | tr -d '\r')
[ -n "$dev" ] || { echo "log-pull: userdata block device not found over adb" >&2; exit 1; }
bytes=$(adb shell blockdev --getsize64 "$dev" | tr -d '\r')
skip=$((bytes / 4096 - blocks))
adb exec-out "dd if=$dev bs=4096 skip=$skip count=$blocks 2>/dev/null" > "$out.bin"
echo "log-pull: $dev: $bytes bytes, blocks $skip..$((skip + blocks - 1)) -> $out.bin ($(stat -c %s "$out.bin") bytes)" >&2
head -c 8 "$out.bin" | grep -q SWEETLOG || { echo "log-pull: no SWEETLOG header: the kernel never flushed (ufsrw=1 and a writable userdata needed)" >&2; exit 2; }
python3 -I "$EXT/ios-topaz/tools/sweet-log.py" "$out.bin" "$out"
echo "log-pull: $out"
