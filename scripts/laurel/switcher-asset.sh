#!/bin/sh
# The app's helper script and port with the numbers of this repo: scripts/lib/laurel-layout.sh and the fence text of patch 2950. One source for the app and the host test.
#   scripts/laurel/switcher-asset.sh OUTDIR     writes OUTDIR/to-ios.sh and OUTDIR/port
# The adbd port: random, high, made once: out/laurel/switcher/port (git-ignored; the app and switcher-setup.sh read the same file). LAUREL_SWITCH_PORT=N: the host test.
set -eu
. "$(dirname "$0")/../lib/env.sh"
. "$REPO/scripts/lib/laurel-layout.sh"
M=$(sed -n 's/^#define LDB_KERNEL_MARKER *"\([^"]*\)".*/\1/p' "$REPO/tools/laurel-dualboot/laurel_dualboot.h")
[ -n "$M" ] || { echo "switcher-asset: no LDB_KERNEL_MARKER" >&2; exit 1; }
PF=$OUT/laurel/switcher/port
if [ -z "${LAUREL_SWITCH_PORT:-}" ]; then
  mkdir -p "${PF%/*}"
  [ -s "$PF" ] || python3 -I -c 'import secrets; print(20000 + secrets.randbelow(40000))' > "$PF"
  LAUREL_SWITCH_PORT=$(cat "$PF")
fi
mkdir -p "$1"
sed -e "s/@FENCE_MARKER@/$M/" -e "s/@IOSROOT_BYTES@/$IOSROOT_BYTES/" -e "s/@USERDATA_BYTES@/$USERDATA_BYTES/" -e "s/@IOSROOT_FIRST@/$IOSROOT_FIRST/" -e "s/@USERDATA_FIRST@/$USERDATA_FIRST/" \
  -e "s/@FW_B@/$FW_B/" -e "s/@PORT@/$LAUREL_SWITCH_PORT/" "$REPO/tools/laurel-switcher/assets/to-ios.sh" > "$1/to-ios.sh"
printf '%s\n' "$LAUREL_SWITCH_PORT" > "$1/port"
if grep -q '@[A-Z_]*@' "$1/to-ios.sh"; then echo "switcher-asset: name left in $1/to-ios.sh" >&2; exit 1; fi
