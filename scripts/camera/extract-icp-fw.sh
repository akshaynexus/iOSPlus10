#!/bin/sh
# Copy the camera ICP firmware (CAMERA_ICP.mdt + .b00-.b20, OPLUS-signed split image) into the ADSP
# firmware area input directory, so scripts/fw/build-areas.sh (scripts/audio/mkadsparea.py) adds it.
# Patch 0316 (negronicam=6) reads it from that area. Vendor firmware: out/ is git-ignored, never commit it.
#   scripts/camera/extract-icp-fw.sh [SRC_DIR]
# SRC_DIR default: out/camera/x/vendor-firmware (scripts/camera/inventory.sh extracts /vendor/firmware).
set -eu
. "$(dirname "$0")/../lib/env.sh"
S=${1:-$OUT/camera/x/vendor-firmware}
D=$OUT/firmware/adsp
[ -s "$S/CAMERA_ICP.mdt" ] || { echo "no $S/CAMERA_ICP.mdt (run scripts/camera/inventory.sh)" >&2; exit 1; }
[ -d "$D" ] || { echo "no $D (run scripts/audio/extract-adsp-fw.sh first)" >&2; exit 1; }
for f in "$S"/CAMERA_ICP.mdt "$S"/CAMERA_ICP.b[0-9][0-9]; do
  cp "$f" "$D/"
done
(cd "$D" && shasum -a 256 CAMERA_ICP.mdt CAMERA_ICP.b[0-9][0-9])
echo "next: scripts/fw/build-areas.sh (adsp-area.bin now holds the ICP files)"
