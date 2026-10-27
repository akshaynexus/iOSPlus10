#!/bin/sh
# Extract the sensor DSP (SLPI) firmware of the NE2211 from the stock modem (NON-HLOS) FAT image and
# pack it for the ADSP firmware area (kernel patch 0376, boot-arg negronislpi).
#   scripts/sensors/extract-slpi-fw.sh
# Input: out/firmware/modem/modem.img (scripts/audio/extract-adsp-fw.sh makes it).
# Output (git-ignored, vendor firmware: never commit it):
#   out/firmware/slpi/slpi.mdt, slpi.bNN   (24 program headers; b22 has no file: BSS)
#   out/firmware/slpi/slpir.jsn, slpius.jsn  servreg domains (root_pd, sensor_pd)
#   out/firmware/slpi/SHA256SUMS
#   out/firmware/adsp/slpi.pak             one file for the ADSP area (scripts/sensors/mkslpipak.py)
# Then: scripts/fw/build-areas.sh (mkadsparea.py takes slpi.pak from out/firmware/adsp) and
# scripts/fw/write-areas.sh (owner approval). Takes a few seconds.
set -eu
. "$(dirname "$0")/../lib/env.sh"
M=$OUT/firmware/modem/modem.img
S=$OUT/firmware/slpi
A=$OUT/firmware/adsp
[ -f "$M" ] || { echo "no $M (scripts/audio/extract-adsp-fw.sh)" >&2; exit 1; }
mkdir -p "$S" "$A"
rm -f "$S"/slpi* "$S"/SHA256SUMS
# The FAT image is untrusted input: run the reader isolated (-I), from the repo, not from out/.
F="python3 -I $REPO/scripts/audio/fatcopy.py"
$F "$M" get image 'slpi*' "$S"
[ -s "$S/slpi.mdt" ] || { echo "no slpi.mdt in $M image/" >&2; exit 1; }
(cd "$S" && { sha256sum slpi* 2>/dev/null || shasum -a 256 slpi*; } > SHA256SUMS)
python3 -I "$REPO/scripts/sensors/mkslpipak.py" "$A/slpi.pak" "$S"
echo "next: scripts/fw/build-areas.sh, then scripts/fw/write-areas.sh (ask the owner)"
