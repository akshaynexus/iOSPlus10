#!/bin/sh
# Get the Apple D22AP (iPhone X) device tree that mkadt.py reads for /product (MobileGestalt identity).
# Only the DeviceTree member of the IPSW is downloaded (HTTP range requests, external/slop/tools/remotezip.py).
#   scripts/fetch-d22ap-adt.sh
# Output: $APPLE/d22ap.adt (default ~/op10-apple, never in git), linked to the path mkadt.py expects:
# external/slop/research/ipsw-x/d22ap.adt (research/ is git-ignored in slop).
set -eu
. "$(dirname "$0")/env.sh"
APPLE=${APPLE:-$HOME/op10-apple}
URL=${IPSW_URL:-https://updates.cdn-apple.com/2025FallFCS/fullrestores/122-77006/1158E502-D76D-4226-AA06-ED5E30CD1111/iPhone10,3,iPhone10,6_16.7.16_20H392_Restore.ipsw}
mkdir -p "$APPLE/dt"
python3 "$EXT/slop/tools/remotezip.py" "$URL" DeviceTree.d22ap.im4p "$APPLE/dt"
im4p=$(find "$APPLE/dt" -name 'DeviceTree.d22ap.im4p' | head -1)
python3 "$REPO/scripts/im4p-extract.py" "$im4p" "$APPLE/d22ap.adt"
mkdir -p "$EXT/slop/research/ipsw-x"
ln -sf "$APPLE/d22ap.adt" "$EXT/slop/research/ipsw-x/d22ap.adt"
ls -l "$EXT/slop/research/ipsw-x/d22ap.adt"
