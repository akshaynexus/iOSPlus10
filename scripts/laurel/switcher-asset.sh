#!/bin/sh
# The app's helper script with the numbers of this repo: scripts/lib/laurel-layout.sh and the fence text of patch 2950. One source for the app and the host test.
#   scripts/laurel/switcher-asset.sh OUT
set -eu
. "$(dirname "$0")/../lib/env.sh"
. "$REPO/scripts/lib/laurel-layout.sh"
M=$(sed -n 's/^#define LDB_KERNEL_MARKER *"\([^"]*\)".*/\1/p' "$REPO/tools/laurel-dualboot/laurel_dualboot.h")
[ -n "$M" ] || { echo "switcher-asset: no LDB_KERNEL_MARKER" >&2; exit 1; }
sed -e "s/@FENCE_MARKER@/$M/" -e "s/@IOSROOT_BYTES@/$IOSROOT_BYTES/" -e "s/@USERDATA_BYTES@/$USERDATA_BYTES/" "$REPO/tools/laurel-switcher/assets/to-ios.sh" > "$1"
if grep -q '@[A-Z_]*@' "$1"; then echo "switcher-asset: name left in $1" >&2; exit 1; fi
