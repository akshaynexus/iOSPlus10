#!/bin/sh
# Look for the Goodix fingerprint trusted application (TA) in the files we own: the partition dump
# (~/op10-backup/partitions/*.img.gz, incl. modem = /vendor/firmware_mnt, tz, oplus_sec) and the
# unpacked HAL. Read-only string scans (ASCII and UTF-16LE FAT long names); no decryption.
#   scripts/bg.sh fp-ta-scan scripts/fp/find-ta.sh
# Output: out/fp/lists/ta-scan.txt (per image: hit counts and the matching names), exit 0.
#   scripts/bg.sh fp-ta-scan2 env PAT="gdx|fpta" IMAGES="modem_a tz_a" OUTNAME=ta-scan2 scripts/fp/find-ta.sh   (bg.sh does not pass env: use env)
set -eu
. "$(dirname "$0")/../lib/env.sh"
P=${PARTS:-$BACKUP/partitions}
O=$OUT/fp/lists/${OUTNAME:-ta-scan}.txt
mkdir -p "$OUT/fp/lists"
: > "$O"
PAT=${PAT:-'goodix|Goodix|GOODIX|delmar|Delmar|gf_ta|gfta|goodixfp|gf_fp|GFFP'}
for f in "$P"/*.img.gz; do
  n=$(basename "$f" .img.gz)
  case "$n" in *_b|gpt-*) continue ;; esac
  if [ -n "${IMAGES:-}" ]; then case " $IMAGES " in *" $n "*) ;; *) continue ;; esac; fi
  hits=$(gzip -dc "$f" | LC_ALL=C grep -a -o -E "[A-Za-z0-9_./-]{0,32}($PAT)[A-Za-z0-9_./-]{0,32}" | sort | uniq -c | sort -rn | head -40 || true)
  # FAT long file names are UTF-16LE: "g\0o\0o\0d\0i\0x\0"
  u16=$(gzip -dc "$f" | LC_ALL=C grep -a -o -E "${U16PAT:-g.o.o.d.i.x.[^\n]{0,60}|G.o.o.d.i.x.[^\n]{0,60}}" | tr -d '\0' | sort | uniq -c | sort -rn | head -20 || true)
  if [ -n "$hits" ] || [ -n "$u16" ]; then
    { echo "== $n"; [ -n "$hits" ] && echo "$hits"; [ -n "$u16" ] && { echo "-- utf16 names"; echo "$u16"; }; } >> "$O"
  fi
done
echo "== done $(date -u +%FT%TZ)" >> "$O"
cat "$O"
