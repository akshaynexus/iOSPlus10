#!/bin/sh
# Read-only backup of the phone's partitions over adb root (Magisk).
#
#   scripts/dump-partitions.sh [outdir]      (default ~/op10-backup/partitions)
#
# Each partition is streamed through gzip; SHA256SUMS holds the hash of the RAW data,
# computed on the phone. Skipped: super, userdata (too large / user data), logdump,
# rawdump (crash logs) and the whole-LUN entries sda..sdf. The GPT of each LUN is saved
# as the first and last 1 MiB (gpt-sdX-head.bin / -tail.bin).
# Restore one partition: gunzip -c X.img.gz > X.img && fastboot flash X X.img
set -eu
OUT=${1:-$HOME/op10-backup/partitions}
SKIP='^(super|userdata|logdump|rawdump|sd[a-z])$'
mkdir -p "$OUT"
cd "$OUT"

rsh() { adb shell "su -c '$1'" | tr -d '\r'; }

names=$(rsh 'ls /dev/block/by-name' | grep -Ev "$SKIP")
: > SHA256SUMS
for p in $names; do
  adb exec-out "su -c 'gzip -c /dev/block/by-name/$p'" > "$p.img.gz"
  h=$(rsh "sha256sum /dev/block/by-name/$p" | cut -d' ' -f1)
  echo "$h  $p.img" >> SHA256SUMS
  printf '%-24s %s\n' "$p" "$(du -h "$p.img.gz" | cut -f1)"
done

for d in $(rsh 'ls /sys/block' | grep -E '^sd[a-z]$'); do
  sz=$(rsh "cat /sys/block/$d/size")
  adb exec-out "su -c 'dd if=/dev/block/$d bs=1048576 count=1 2>/dev/null'" > "gpt-$d-head.bin"
  adb exec-out "su -c 'dd if=/dev/block/$d bs=512 skip=$((sz - 2048)) count=2048 2>/dev/null'" > "gpt-$d-tail.bin"
done
echo "done: $(ls *.img.gz | wc -l) partitions, $(du -sh . | cut -f1)"
