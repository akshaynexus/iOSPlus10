#!/bin/sh
# Get the small parts of the iOS 26 donor IPSW (no full download): the file list, the kernelcache,
# the DeviceTree(s) and the AGX GPU firmware. Range reads only (op10tool ipsw-get), then im4p unpack.
#   scripts/ios26/fetch-donor.sh                       negroni donor (default DEV=d421ap, iPhone12,3, docs/future-ios26.md)
#   DEV=n104ap scripts/ios26/fetch-donor.sh            Mi A3 donor (iPhone12,1, docs/laurel_sprout/ios26-userland.md); under scripts/bg.sh use: env DEV=n104ap ...
# Run it with scripts/bg.sh: about 25 MB. ipsw-get writes each member under its base name in OUTDIR.
# Env: DEV, and the names of scripts/ios26/donor.sh (IPSW_URL, KC, AGX), OUTDIR (default $APPLE/ios26/<build>-<dev>, never in git).
set -eu
. "$(dirname "$0")/../lib/env.sh"
. "$(dirname "$0")/donor.sh"
OUTDIR=${OUTDIR:-$APPLE/ios26/$BUILD-$DEV}
mkdir -p "$OUTDIR"
python3 -I "$REPO/scripts/ios26/ipsw-ls.py" "$IPSW_URL" > "$OUTDIR/ipsw-files.txt"
"$OUT/bin/op10tool" ipsw-get -j 8 "$IPSW_URL" "$OUTDIR" "$KC" "Firmware/all_flash/DeviceTree.$DEV.im4p" "$AGX" BuildManifest.plist Restore.plist
"$OUT/bin/op10tool" im4p "$OUTDIR/$KC" "$OUTDIR/$KC.macho"
"$OUT/bin/op10tool" im4p "$OUTDIR/DeviceTree.$DEV.im4p" "$OUTDIR/$DEV.adt"
( cd "$OUTDIR" && sha256_list "$KC" "$KC.macho" "$DEV.adt" > SHA256SUMS )
cat "$OUTDIR/SHA256SUMS"
ls -l "$OUTDIR"
