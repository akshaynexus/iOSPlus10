#!/bin/sh
# Check that op10tool gives the same output as the Python tools it replaces.
#   tools/op10tool/tests/compare-python.sh
# Inputs: ~/op10-backup/images/uefi.img, ~/op10-apple/dt/.../DeviceTree.d22ap.im4p,
#         ~/op10-apple/20H392/087-86715-047.dmg (for ipsw-get). Works in out/test/ (git-ignored).
set -eu
REPO=$(cd "$(dirname "$0")/../../.." && pwd)
. "$REPO/scripts/lib/env.sh"
T=$OUT/test
OP=$OUT/bin/op10tool
PY=${PYREF:-$REPO/tools/op10tool/tests/python}     # reference Python versions
APPLE=${APPLE:-$HOME/op10-apple}
R=$EXT/Mu-Silicium-negroni/Binaries/r0q/QcomPkg/Drivers
rm -rf "$T"; mkdir -p "$T"
fail=0
check() { if "$@"; then echo "  same"; else echo "  DIFFERENT"; fail=1; fi; }

echo "== uefi-unpack"
python3 "$PY/unpack.py" "$BACKUP/images/uefi.img" "$T/py-mod" | tail -1
"$OP" uefi-unpack "$BACKUP/images/uefi.img" "$T/rs-mod"
check diff -rq "$T/py-mod" "$T/rs-mod"

echo "== uefi-portpatch (7 drivers)"
guid() { awk -F'\t' -v n="$1" '$3 == n { print $1 }' "$T/rs-mod/index.tsv"; }
while IFS='|' read -r name ref extra; do
  g=$(guid "$name")
  # shellcheck disable=SC2086
  python3 "$PY/portpatch.py" "$R/$ref.efi" "$R/$ref.patched.efi" "$T/rs-mod/$g/pe32.efi" "$T/py-$name.efi" $extra > "$T/py-$name.log"
  # shellcheck disable=SC2086
  "$OP" uefi-portpatch "$R/$ref.efi" "$R/$ref.patched.efi" "$T/rs-mod/$g/pe32.efi" "$T/rs-$name.efi" $extra > "$T/rs-$name.log"
  printf '%s' "$name"; check cmp -s "$T/py-$name.efi" "$T/rs-$name.efi"
  diff -q "$T/py-$name.log" "$T/rs-$name.log" >/dev/null || { echo "  log differs:"; diff "$T/py-$name.log" "$T/rs-$name.log" | head -6; }
done <<'EOF'
ClockDxe|ClockDxe/ClockDxe|
PmicDxe|PmicDxe/PmicDxeLa|--skip 0x131c8
SPMI|SPMIDxe/SPMIDxe|
TzDxeLA|TzDxe/TzDxeLA|--skip 0xf51c --byte f55c=00:01
UFSDxe|UFSDxe/UFSDxe|
UsbConfigDxe|UsbConfigDxe/UsbConfigDxe|
UsbMsdDxe|UsbMsdDxe/UsbMsdDxe|
EOF

echo "== im4p"
im=$(find "$APPLE/dt" -name 'DeviceTree.d22ap.im4p' | head -1)
python3 "$PY/im4p-extract.py" "$im" "$T/py.adt" >/dev/null
"$OP" im4p "$im" "$T/rs.adt" >/dev/null
check cmp -s "$T/py.adt" "$T/rs.adt"

echo "== img2simg (sparse file with holes, a fill run and random data)"
mkfile -n 64m "$T/t.img" 2>/dev/null || truncate -s 64M "$T/t.img"
printf 'hello' | dd of="$T/t.img" bs=1 seek=8192 conv=notrunc 2>/dev/null
dd if=/dev/urandom of="$T/t.img" bs=4096 seek=5000 count=5000 conv=notrunc 2>/dev/null
python3 "$PY/img2simg.py" "$T/t.img" "$T/py.simg" >/dev/null
"$OP" img2simg "$T/t.img" "$T/rs.simg" >/dev/null
check cmp -s "$T/py.simg" "$T/rs.simg"

echo "== ipsw-get (AppOS cryptex, 10 MB, deflated in the IPSW)"
URL=https://updates.cdn-apple.com/2025FallFCS/fullrestores/122-77006/1158E502-D76D-4226-AA06-ED5E30CD1111/iPhone10,3,iPhone10,6_16.7.16_20H392_Restore.ipsw
"$OP" ipsw-get -j 8 --chunk-mib 1 "$URL" "$T/ipsw" 087-86715-047.dmg | tail -1
check cmp -s "$APPLE/20H392/087-86715-047.dmg" "$T/ipsw/087-86715-047.dmg"

[ "$fail" = 0 ] && echo "ALL SAME" || { echo "SOME DIFFERENT"; exit 1; }
