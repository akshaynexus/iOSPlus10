#!/bin/sh
# Mi A3: read the persistent console logs from the userdata partition over adb, from another system
# (a recovery on boot_b, or Android with root: owner approval, docs/backup-and-restore.md). Only reads.
#   scripts/laurel/log-pull.sh logs/laurel-pull-$(date +%H%M)
# 1. The boot log area of kernel patch 2900 (parked, patches/laurel/parked/; negroni 0367 layout): 9216 blocks at partition block
#    N-28673 (N = partition size in 4096-byte blocks), superblock "NEGRBLOG", 8 slots of one boot each.
#    Decoded with op10tool bootlog --file into OUT/bootlog-<boot>.txt.
# 2. If that area was never written (kernel before 2900, or "LAUREL BOOTLOG: off"): the topaz 0047 area,
#    the last 1025 blocks ("SWEETLOG", ufsrw=1), decoded with external/ios-topaz/tools/sweet-log.py.
# With a partition `iosroot` only the last 1025 blocks of it are read (next lines). Reads with no write; the next iOS boot overwrites this log within seconds, so read it before that boot.
# On a running iOS with SSH the same area comes from /dev/laurelbootlog: scripts/laurel/phone-ssh.sh bootlog.
# Over USB without SSH (a good boot): out/bin/op10tool bootlog.
set -eu
. "$(dirname "$0")/../lib/env.sh"
out=${1:?usage: log-pull.sh OUTDIR}
mkdir -p "$out"
# The iOS root in its own partition `iosroot` (branch t3/laurel-dual-boot-fix2, patch 2950, LDB_LOG_BLOCKS): the console log is its last 1025 blocks. iOS 26 first boot: docs/laurel_sprout/ios26-first-boot.md.
ios=$(adb shell 'for d in /dev/block/by-name/iosroot /dev/block/bootdevice/by-name/iosroot; do [ -e $d ] && readlink -f $d && break; done' | tr -d '\r')
if [ -n "$ios" ]; then
  bytes=$(adb shell blockdev --getsize64 "$ios" | tr -d '\r')
  n=$((bytes / 4096))
  skip=$((n - 1025))
  adb exec-out "dd if=$ios bs=4096 skip=$skip count=1025 2>/dev/null" > "$out/sweetlog.bin"
  echo "log-pull: $ios (iosroot): $bytes bytes, log blocks $skip..$((skip + 1024)) -> $out/sweetlog.bin" >&2
  [ "$(wc -c < "$out/sweetlog.bin" | tr -d ' ')" = $((1025 * 4096)) ] || { echo "log-pull: short read: no root on adb? (adb root, or su)" >&2; exit 2; }
  head -c 8 "$out/sweetlog.bin" | grep -q SWEETLOG || { echo "log-pull: no SWEETLOG header at the end of iosroot: this boot never flushed (needs ufsrw=1 and a kernel past the root mount)" >&2; exit 2; }
  python3 -I "${SWEETLOG_TOOL:-$EXT/ios-topaz/tools/sweet-log.py}" "$out/sweetlog.bin" "$out/sweetlog.txt"
  echo "log-pull: $out/sweetlog.txt"
  exit 0
fi
dev=$(adb shell 'for d in /dev/block/by-name/userdata /dev/block/bootdevice/by-name/userdata; do [ -e $d ] && readlink -f $d && break; done' | tr -d '\r')
[ -n "$dev" ] || { echo "log-pull: userdata block device not found over adb" >&2; exit 1; }
bytes=$(adb shell blockdev --getsize64 "$dev" | tr -d '\r')
n=$((bytes / 4096))
skip=$((n - 28673))
adb exec-out "dd if=$dev bs=4096 skip=$skip count=9216 2>/dev/null" > "$out/bootlog-area.bin"
echo "log-pull: $dev: $bytes bytes, boot log area blocks $skip..$((skip + 9215)) -> $out/bootlog-area.bin" >&2
if head -c 8 "$out/bootlog-area.bin" | grep -q NEGRBLOG; then
  OP=$REPO/out/bin/op10tool
  [ -x "$OP" ] || "$REPO/scripts/setup/build-op10tool.sh"
  "$OP" bootlog --file "$out/bootlog-area.bin" --out "$out"
  exit 0
fi
echo "log-pull: no boot log superblock: trying the topaz SWEETLOG area (last 1025 blocks)" >&2
skip=$((n - 1025))
adb exec-out "dd if=$dev bs=4096 skip=$skip count=1025 2>/dev/null" > "$out/sweetlog.bin"
head -c 8 "$out/sweetlog.bin" | grep -q SWEETLOG || { echo "log-pull: no SWEETLOG header either: the kernel never flushed" >&2; exit 2; }
python3 -I "$EXT/ios-topaz/tools/sweet-log.py" "$out/sweetlog.bin" "$out/sweetlog.txt"
echo "log-pull: $out/sweetlog.txt"
