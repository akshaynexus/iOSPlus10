#!/bin/sh
# iOS 16 test option "backboardd on Metal": add it to a mounted Mi A3 iOS 16 root that has the default GPU and Metal stages (scripts/laurel/root.sh). Off by default; a root without this script is unchanged.
#   METAL_BACKBOARDD=1 sudo scripts/laurel/root.sh ...      calls this after root-add-metal.sh
#   sudo scripts/laurel/root-add-bbd-metal.sh MOUNTED_ROOT  by hand
# Input: out/metal-bbd from scripts/laurel/ios16-bbd-metal-build.sh. Writes: the plug-in, the wrapper /usr/libexec/backboardd, the flag /private/var/db/negronimetal/backboardd-metal.
# Undo on a running phone, no new root: rm /private/var/db/negronimetal/backboardd-metal, restart backboardd: the plug-in gives no device, CoreAnimation takes GL. Docs: docs/laurel_sprout/ios26-metal.md section 6.
set -eu
R=${1:?usage: $0 MOUNTED_ROOT}
REPO=$(cd "$(dirname "$0")/../.." && pwd)
S=$REPO/out/metal-bbd
P=$S/stage/System/Library/Extensions/NegroniMetal.bundle/NegroniMetal
W=$S/backboardd.wrap
if [ ! -s "$P" ] || [ ! -s "$W" ]; then
  echo "laurel-root: bbd-metal: off: no $S (scripts/laurel/ios16-bbd-metal-build.sh): the root stays on the default GL path"; exit 1
fi
if [ ! -e "$R/usr/libexec/real/backboardd" ] || [ ! -d "$R/System/Library/Extensions/NegroniMetal.bundle" ]; then
  echo "laurel-root: bbd-metal: off: the root has no GL wrapper or no Metal stage (root-add-gpu.sh, root-add-metal.sh first)"; exit 1
fi
install -m 755 "$P" "$R/System/Library/Extensions/NegroniMetal.bundle/NegroniMetal"
install -m 755 "$W" "$R/usr/libexec/backboardd"
D=$R/private/var/db/negronimetal
: > "$D/backboardd-metal"
chmod 644 "$D/backboardd-metal"
[ "$(id -u)" != 0 ] || chown 0:0 "$R/System/Library/Extensions/NegroniMetal.bundle/NegroniMetal" "$R/usr/libexec/backboardd" "$D/backboardd-metal"
echo "laurel-root: bbd-metal: on: backboardd takes Metal from the boot after the gate's pass; GL stays the fallback; undo: rm /private/var/db/negronimetal/backboardd-metal"
