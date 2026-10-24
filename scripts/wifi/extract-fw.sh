#!/bin/sh
# Extract the QCA6490 WLAN firmware of the NE2211 from the stock modem (NON-HLOS) image.
#   scripts/wifi/extract-fw.sh [--dump | MODEM_IMG]
# Source, first match: the MODEM_IMG argument (or $MODEM_IMG); --dump: the read-only partition
# dump $BACKUP/partitions/modem_a.img.gz; out/firmware/modem/modem.img when it exists (from this
# script or scripts/audio/extract-adsp-fw.sh); else the full OTA ($OTA, default
# $BACKUP/NE2211_16.0.3.530_EX01_full.zip) with payload-dumper-go -p modem.
# Output (git-ignored, vendor firmware: never commit it), all from image/ of the FAT image:
#   out/firmware/wlan/amss.bin, amss20.bin     WLAN firmware (cnss2 loads amss20.bin when the chip's
#                                              major version is 2, else amss.bin)
#   out/firmware/wlan/m3.bin                   M3 firmware
#   out/firmware/wlan/regdb.bin                regulatory database
#   out/firmware/wlan/bdwlan.eNN, bdwlan.elf   board data (ELF); NN = QMI board id in hex
#   out/firmware/wlan/bdwlang.eNN, bdwlang.elf board data for "GF" chips (QMI chip_id bit 4)
#   out/firmware/wlan/LISTING.txt, SHA256SUMS  the image/ listing and sha256 of every file
# Long with the OTA (payload extraction of ~290 MB): scripts/bg.sh wifi-fw scripts/wifi/extract-fw.sh
set -eu
. "$(dirname "$0")/../lib/env.sh"
OTA=${OTA:-$BACKUP/NE2211_16.0.3.530_EX01_full.zip}
M=$OUT/firmware/modem
W=$OUT/firmware/wlan
mkdir -p "$M" "$W"

case "${1:-}" in
--dump)
  src=$BACKUP/partitions/modem_a.img.gz
  [ -f "$src" ] || { echo "no $src (scripts/backup/dump-partitions.sh)" >&2; exit 1; }
  gunzip -c "$src" > "$M/modem.img"
  IMG=$M/modem.img ;;
"") IMG=${MODEM_IMG:-} ;;
*) IMG=$1 ;;
esac
if [ -z "$IMG" ] && [ -f "$M/modem.img" ]; then IMG=$M/modem.img; fi
if [ -z "$IMG" ]; then
  [ -f "$OTA" ] || { echo "no OTA zip $OTA (scripts/backup/fetch-stock-ota.sh)" >&2; exit 1; }
  command -v payload-dumper-go >/dev/null || { echo "payload-dumper-go missing (docs/setup-*.md)" >&2; exit 1; }
  rm -rf "$M/payload"
  payload-dumper-go -o "$M/payload" -p modem "$OTA"
  mv "$M/payload/modem.img" "$M/modem.img"
  rm -rf "$M/payload"
  IMG=$M/modem.img
fi
[ -f "$IMG" ] || { echo "modem image not found: $IMG" >&2; exit 1; }

# The FAT image is untrusted input: run the reader isolated (-I), from the repo, not from out/.
F="python3 -I $REPO/scripts/audio/fatcopy.py"
$F "$IMG" list image > "$W/LISTING.txt"
rm -f "$W"/amss*.bin "$W"/m3.bin "$W"/regdb.bin "$W"/bdwlan.* "$W"/bdwlang.*
for p in 'amss.bin' 'amss20.bin' 'm3.bin' 'regdb.bin' 'bdwlan.*' 'bdwlang.*'; do
  $F "$IMG" get image "$p" "$W" > /dev/null
done

# Every WLAN file in the listing must now exist with the listed size.
missing=$(awk '$1 == "-" && $3 ~ /^(amss(20)?\.bin|m3\.bin|regdb\.bin|bdwlang?\..*)$/ {print $3, $2}' "$W/LISTING.txt" |
  while read -r name size; do
    if [ ! -f "$W/$name" ] || [ "$(wc -c < "$W/$name" | tr -d ' ')" != "$size" ]; then echo "$name"; fi
  done)
[ -z "$missing" ] || { echo "missing or wrong size: $missing" >&2; exit 1; }
for f in amss.bin amss20.bin m3.bin regdb.bin bdwlan.elf; do
  [ -s "$W/$f" ] || { echo "required WLAN file missing: $f" >&2; exit 1; }
done

(cd "$W" && { sha256sum amss*.bin m3.bin regdb.bin bdwlan.* bdwlang.* 2>/dev/null ||
  shasum -a 256 amss*.bin m3.bin regdb.bin bdwlan.* bdwlang.*; } > SHA256SUMS)
echo "modem.img sha256: $( (sha256sum "$IMG" 2>/dev/null || shasum -a 256 "$IMG") | cut -d' ' -f1)"
echo "firmware: $(strings -n 8 "$W/amss.bin" | grep -m1 QC_IMAGE_VERSION_STRING || echo 'no version string')"
echo "$(find "$W" -name 'bdwlan.*' | wc -l | tr -d ' ') bdwlan + $(find "$W" -name 'bdwlang.*' | wc -l | tr -d ' ') bdwlang board files"
echo "$(wc -l < "$W/SHA256SUMS" | tr -d ' ') files in $W (SHA256SUMS, LISTING.txt)"
