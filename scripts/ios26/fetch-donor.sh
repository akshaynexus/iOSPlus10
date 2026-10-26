#!/bin/sh
# Get the small parts of the iOS 26 donor IPSW (no full download): the file list, the kernelcache,
# the DeviceTree(s) and the AGX GPU firmware. Range reads only (op10tool ipsw-get), then im4p unpack.
#   scripts/ios26/fetch-donor.sh            (run it with scripts/bg.sh: about 25 MB)
# ipsw-get writes each member under its base name in OUTDIR.
# Env: IPSW_URL (default iPhone12,3/12,5 26.5.2 23F84), DEV (d421ap = iPhone12,3; d431ap = iPhone12,5), KC (kernelcache.release.iphone12),
#      AGX (Firmware/agx/armfw_g12p.im4p), OUTDIR (default $APPLE/ios26/<build>-<dev>, never in git).
# docs/future-ios26.md explains the choice of donor.
set -eu
. "$(dirname "$0")/../lib/env.sh"
APPLE=${APPLE:-$HOME/op10-apple}
URL=${IPSW_URL:-https://updates.cdn-apple.com/2026SpringFCS/fullrestores/140-25381/6ABE5EEB-511D-4DF4-AB43-FE86D0A7718A/iPhone12,3,iPhone12,5_26.5.2_23F84_Restore.ipsw}
DEV=${DEV:-d421ap}
KC=${KC:-kernelcache.release.iphone12}
AGX=${AGX:-Firmware/agx/armfw_g12p.im4p}
BUILD=$(basename "$URL" | sed 's/.*_\([0-9A-Z]*\)_Restore\.ipsw/\1/')
OUTDIR=${OUTDIR:-$APPLE/ios26/$BUILD-$DEV}
mkdir -p "$OUTDIR"
python3 -I "$REPO/scripts/ios26/ipsw-ls.py" "$URL" > "$OUTDIR/ipsw-files.txt"
"$OUT/bin/op10tool" ipsw-get -j 8 "$URL" "$OUTDIR" "$KC" "Firmware/all_flash/DeviceTree.$DEV.im4p" "$AGX" BuildManifest.plist Restore.plist
"$OUT/bin/op10tool" im4p "$OUTDIR/$KC" "$OUTDIR/$KC.macho"
"$OUT/bin/op10tool" im4p "$OUTDIR/DeviceTree.$DEV.im4p" "$OUTDIR/$DEV.adt"
( cd "$OUTDIR" && shasum -a 256 "$KC" "$KC.macho" "$DEV.adt" > SHA256SUMS )
cat "$OUTDIR/SHA256SUMS"
ls -l "$OUTDIR"
