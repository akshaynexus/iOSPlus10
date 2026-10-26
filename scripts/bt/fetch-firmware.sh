#!/bin/sh
# Extract the QCA6490 Bluetooth firmware of the NE2211 from the stock "bluetooth" partition
# (FAT16 image, Android mounts it at /vendor/bt_firmware; files in image/).
#   scripts/bt/fetch-firmware.sh [--ota | BT_IMG]
# Source, first match: the BT_IMG argument; out/bt/bluetooth.img when it exists; the read-only
# partition dump $BACKUP/partitions/bluetooth_a.img.gz; --ota: payload-dumper-go -p bluetooth
# from $OTA (default $BACKUP/NE2211_16.0.3.530_EX01_full.zip).
# Output (git-ignored; Qualcomm proprietary firmware, no redistribution license: never commit it):
#   out/bt/firmware/hpbtfw2N.tlv   rampatch (TLV) for ROM version 2.0 / 2.1
#   out/bt/firmware/hpnv2N*.bNN    NVM (TLV) per board id; .bin = default; g = "GF" chips
#   out/bt/firmware/LISTING.txt, SHA256SUMS
set -eu
. "$(dirname "$0")/../lib/env.sh"
OTA=${OTA:-$BACKUP/NE2211_16.0.3.530_EX01_full.zip}
B=$OUT/bt
W=$B/firmware
mkdir -p "$B" "$W"
IMG=
case "${1:-}" in
--ota)
  [ -f "$OTA" ] || { echo "no OTA zip $OTA" >&2; exit 1; }
  command -v payload-dumper-go >/dev/null || { echo "payload-dumper-go missing (docs/setup-*.md)" >&2; exit 1; }
  rm -rf "$B/payload"
  payload-dumper-go -o "$B/payload" -p bluetooth "$OTA"
  mv "$B/payload/bluetooth.img" "$B/bluetooth.img"
  rm -rf "$B/payload"
  IMG=$B/bluetooth.img ;;
"") ;;
*) IMG=$1 ;;
esac
if [ -z "$IMG" ] && [ -f "$B/bluetooth.img" ]; then IMG=$B/bluetooth.img; fi
if [ -z "$IMG" ]; then
  src=$BACKUP/partitions/bluetooth_a.img.gz
  [ -f "$src" ] || { echo "no $src (scripts/backup/dump-partitions.sh) and no out/bt/bluetooth.img (use --ota)" >&2; exit 1; }
  gunzip -c "$src" > "$B/bluetooth.img"
  IMG=$B/bluetooth.img
fi
# the FAT image is untrusted input: isolated reader (-I), run from the repo
F="python3 -I $REPO/scripts/audio/fatcopy.py"
$F "$IMG" list image > "$W/LISTING.txt"
rm -f "$W"/hpbtfw* "$W"/hpnv*
$F "$IMG" get image 'hp*' "$W" > /dev/null
(cd "$W" && shasum -a 256 hp* > SHA256SUMS)
echo "$(ls "$W"/hp* | wc -l | tr -d ' ') files in $W"
grep -E 'hpbtfw2[01]\.tlv|hpnv2[01]\.bin' "$W/SHA256SUMS"
