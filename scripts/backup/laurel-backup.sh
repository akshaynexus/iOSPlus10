#!/bin/sh
# Read-only backup of the Mi A3 (laurel_sprout) under LineageOS, over adb root (Rooted debugging). macOS and Linux.
#
#   scripts/bg.sh laurel-backup scripts/backup/laurel-backup.sh partitions   every partition except userdata + the GPT
#   scripts/bg.sh laurel-backup scripts/backup/laurel-backup.sh data         the files of /data, phone unlocked
#   scripts/bg.sh laurel-backup scripts/backup/laurel-backup.sh all          both
#
# Output: ~/laurel-backup/android-<date>/ (mode 700, never in git; OUT= overrides). It holds calibration, IMEI data and
# private files, so it stays on this computer. This script writes nothing to the phone. Run `data` again right before
# the first write to the phone: it is a copy of one moment.
#
# adb exec-out reports no remote failure, so nothing here trusts its exit code: each partition is compared with a hash
# made on the phone, and the data archive must pass gzip -t and a full tar listing.
#
# Limits of `data`: it is a copy of files for salvage, not a block image. The file-based and metadata encryption keys
# stay in the phone's keymaster, and a tar copy has no encryption policies. After a format, apps and accounts are set up
# again and files are copied back by hand. A partition restored with fastboot has the SHA-256 in SHA256SUMS.
set -eu
WHAT=${1:-all}
case "$WHAT" in partitions|data|all) ;; *) sed -n 2,8p "$0"; exit 2 ;; esac

die() { echo "laurel-backup: FAILED: $*" >&2; exit 1; }
if command -v sha256sum >/dev/null 2>&1; then sha() { sha256sum | cut -d' ' -f1; }; else sha() { shasum -a 256 | cut -d' ' -f1; }; fi
ph() { adb shell "$1" | tr -d '\r'; }    # for reads only: every answer is checked by its caller

[ "$(ph 'getprop ro.product.device')" = laurel_sprout ] || die "the phone on the cable is not laurel_sprout"
[ "$(ph 'id -u')" = 0 ] || die "no root: turn on Rooted debugging, then run: adb root"

OUT=${OUT:-$HOME/laurel-backup/android-$(date +%Y%m%d-%H%M)}
mkdir -p "$OUT"; chmod 700 "$OUT"; cd "$OUT"
echo "laurel-backup: $OUT"
ph 'getprop ro.lineage.version; getprop ro.boot.slot_suffix' > build.txt

partitions() {
  names=$(ph 'ls /dev/block/by-name' | grep -Ev '^(userdata|logdump|rawdump|sd[a-z])$')
  [ -n "$names" ] || die "no partition names"
  : > SHA256SUMS
  n=0
  for p in $names; do
    want=$(ph "sha256sum /dev/block/by-name/$p" | cut -d' ' -f1)
    case "$want" in [0-9a-f]*) [ ${#want} = 64 ] || die "$p: no hash from the phone" ;; *) die "$p: no hash from the phone" ;; esac
    adb exec-out "gzip -c /dev/block/by-name/$p 2>/dev/null" > "$p.img.gz"
    got=$(gzip -dc "$p.img.gz" | sha)
    [ "$got" = "$want" ] || die "$p: hash differs (phone $want, here $got)"
    echo "$want  $p.img" >> SHA256SUMS
    n=$((n + 1))
    printf '%-24s %s\n' "$p" "$(du -h "$p.img.gz" | cut -f1)"
  done
  # The GPT of each LUN: first and last 1 MiB. Never restored by a script; CLAUDE.md forbids a GPT write.
  for d in $(ph 'ls /sys/block' | grep -E '^sd[a-z]$'); do
    bytes=$(ph "blockdev --getsize64 /dev/block/$d")
    [ "$bytes" -gt 2097152 ] || die "$d: bad size $bytes"
    skip=$((bytes / 1048576 - 1))
    adb exec-out "dd if=/dev/block/$d bs=1048576 count=1 2>/dev/null" > "gpt-$d-head.bin"
    adb exec-out "dd if=/dev/block/$d bs=1048576 skip=$skip count=1 2>/dev/null" > "gpt-$d-tail.bin"
    for f in head tail; do
      [ "$(wc -c < "gpt-$d-$f.bin" | tr -d ' ')" = 1048576 ] || die "$d: $f is not 1 MiB"
    done
    want=$(ph "dd if=/dev/block/$d bs=1048576 count=1 2>/dev/null | sha256sum" | cut -d' ' -f1)
    [ "$(sha < "gpt-$d-head.bin")" = "$want" ] || die "$d: GPT head hash differs"
    echo "$want  gpt-$d-head.bin" >> SHA256SUMS
  done
  echo "laurel-backup: partitions ok: $n + GPT, $(du -sh . | cut -f1)"
}

data() {
  [ "$(ph 'getprop sys.user.0.ce_available')" = true ] || die "the phone has not been unlocked since boot: unlock it once, then run again"
  adb exec-out 'cd /data && tar -czf - --exclude=./gsi --exclude=./user/0 . 2>/dev/null' > data.tar.gz
  gzip -t data.tar.gz || die "data.tar.gz is damaged"
  tar -tzf data.tar.gz > data-files.txt || die "data.tar.gz does not list"
  n=$(wc -l < data-files.txt | tr -d ' ')
  [ "$n" -gt 1000 ] || die "only $n entries: this is not /data"
  # The private files of user 0 are in ./data, which /data/user/0 only mirrors. Their names stay in data-files.txt, out of the log.
  grep -q '^\./data/' data-files.txt || die "no ./data in the archive"
  grep -q '^\./media/' data-files.txt || die "no ./media in the archive"
  sha < data.tar.gz > data.tar.gz.sha256
  echo "laurel-backup: data ok: $n entries, $(du -h data.tar.gz | cut -f1)"
}

case "$WHAT" in
  partitions) partitions ;;
  data) data ;;
  all) partitions; data ;;
esac
echo "laurel-backup: done: $OUT"
