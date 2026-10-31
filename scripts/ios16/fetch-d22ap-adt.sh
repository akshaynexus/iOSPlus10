#!/bin/sh
# Get the Apple D22AP (iPhone X) device tree that mkadt.py reads for /product (MobileGestalt identity).
# Only the DeviceTree member of the IPSW is downloaded (op10tool ipsw-get), then unpacked (op10tool im4p).
#   scripts/ios16/fetch-d22ap-adt.sh
# Output: $APPLE/d22ap.adt (default ~/op10-apple, never in git). scripts/laurel/mkadt.py reads it there; when the
# slop submodule is checked out it is also linked to external/slop/research/ipsw-x/d22ap.adt (slop's mkadt.py).
set -eu
. "$(dirname "$0")/../lib/env.sh"
[ -x "$OUT/bin/op10tool" ] || "$REPO/scripts/setup/build-op10tool.sh"
APPLE=${APPLE:-$HOME/op10-apple}
URL=${IPSW_URL:-https://updates.cdn-apple.com/2025FallFCS/fullrestores/122-77006/1158E502-D76D-4226-AA06-ED5E30CD1111/iPhone10,3,iPhone10,6_16.7.16_20H392_Restore.ipsw}
mkdir -p "$APPLE/dt"
"$OUT/bin/op10tool" ipsw-get -j 1 "$URL" "$APPLE/dt" DeviceTree.d22ap.im4p
im4p=$APPLE/dt/DeviceTree.d22ap.im4p
"$OUT/bin/op10tool" im4p "$im4p" "$APPLE/d22ap.adt"
if [ -f "$EXT/slop/README.md" ] || [ -d "$EXT/slop/tools" ]; then
  mkdir -p "$EXT/slop/research/ipsw-x"
  ln -sf "$APPLE/d22ap.adt" "$EXT/slop/research/ipsw-x/d22ap.adt"
fi
ls -l "$APPLE/d22ap.adt"
