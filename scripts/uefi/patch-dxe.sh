#!/bin/sh
# Port the r0q (Galaxy S22) UEFI driver patches onto the NE2211 Qualcomm DXEs.
#   scripts/uefi/patch-dxe.sh [uefi.img]      (default ~/op10-backup/images/uefi.img)
# 1. op10tool uefi-unpack   -> out/uefi/modules/<GUID>/ (+ index.tsv)
# 2. op10tool uefi-portpatch per driver: r0q X.efi vs X.patched.efi (Device-Binaries/r0q) gives
#    the patch; it is matched by masked code context in our module -> out/uefi/patched/<r0q name>.efi
#    Extra arguments per driver (last column):
#    - PmicDxe: --skip 0x131c8, the r0q power-button check has no counterpart in the OnePlus build.
#    - TzDxeLA: the patch is a data byte (global "TZ applet" flag, accessed via [x22,#1372]);
#      code context cannot find data, so it is applied as a checked byte: 0xf55c 00 -> 01.
# A driver whose port fails is reported and left unpatched (see docs/uefi-binaries.md).
set -eu
. "$(dirname "$0")/../lib/env.sh"
IMG=${1:-$BACKUP/images/uefi.img}
R=$EXT/Mu-Silicium-negroni/Binaries/r0q/QcomPkg/Drivers
M=$OUT/uefi/modules
P=$OUT/uefi/patched
OP=$OUT/bin/op10tool
[ -x "$OP" ] || "$REPO/scripts/setup/build-op10tool.sh"
"$OP" uefi-unpack "$IMG" "$M"
mkdir -p "$P"
guid() { awk -F'\t' -v n="$1" '$3 == n { print $1 }' "$M/index.tsv"; }

# our UI name | r0q path (without .efi) | output name | extra arguments
while IFS='|' read -r name ref outname extra; do
  [ -n "$name" ] || continue
  g=$(guid "$name")
  [ -n "$g" ] || { echo "== $name: not found in uefi.img"; continue; }
  echo "== $name ($g)"
  # shellcheck disable=SC2086
  if "$OP" uefi-portpatch "$R/$ref.efi" "$R/$ref.patched.efi" \
       "$M/$g/pe32.efi" "$P/$outname.efi" $extra; then :; else
    echo "   FAILED: $name"; rm -f "$P/$outname.efi"
  fi
done <<'EOF'
ClockDxe|ClockDxe/ClockDxe|ClockDxe|
PmicDxe|PmicDxe/PmicDxeLa|PmicDxeLa|--skip 0x131c8
SPMI|SPMIDxe/SPMIDxe|SPMIDxe|
TzDxeLA|TzDxe/TzDxeLA|TzDxeLA|--skip 0xf51c --byte f55c=00:01
UFSDxe|UFSDxe/UFSDxe|UFSDxe|
UsbConfigDxe|UsbConfigDxe/UsbConfigDxe|UsbConfigDxe|
UsbMsdDxe|UsbMsdDxe/UsbMsdDxe|UsbMsdDxe|
EOF
ls -l "$P"
