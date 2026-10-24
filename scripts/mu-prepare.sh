#!/bin/sh
# Prepare the Mu-Silicium negroni tree for a build (host side, macOS or Linux; needs git + python3).
#   scripts/mu-prepare.sh [uefi.img]
# Run scripts/setup-mu.sh once before this.
# 1. UniXNU DarwinBoot submodule + the port's DarwinBoot patch (refusal stays on screen 20 s).
# 2. Qualcomm DXEs from the stock uefi.img with the r0q patches ported (scripts/mu-patch-dxe.sh).
# 3. Binaries/negroni from those modules (scripts/mu-binaries.py), installed into the Mu tree.
# 4. Check that every Binaries/negroni path that negroniPkg references exists.
set -eu
. "$(dirname "$0")/env.sh"
MU=$EXT/Mu-Silicium-negroni
UNIXNU=$EXT/UniXNU

git -C "$UNIXNU" submodule update -q --init --depth 1 drivers/DarwinBoot
DB=$UNIXNU/drivers/DarwinBoot
if git -C "$DB" apply --check "$EXT/slop/uefi/negroni/DarwinBoot/refusal-on-screen.patch" 2>/dev/null; then
  git -C "$DB" apply "$EXT/slop/uefi/negroni/DarwinBoot/refusal-on-screen.patch"
  echo "DarwinBoot: refusal-on-screen.patch applied"
else
  echo "DarwinBoot: refusal-on-screen.patch already applied (or does not apply)"
fi

"$REPO/scripts/mu-patch-dxe.sh" "${1:-$BACKUP/images/uefi.img}"
python3 "$REPO/scripts/mu-binaries.py" "$MU/Binaries/r0q" "$OUT/uefi/modules" "$OUT/uefi/patched" \
  "$OUT/uefi/Binaries-negroni"
rm -rf "$MU/Binaries/negroni"
cp -R "$OUT/uefi/Binaries-negroni" "$MU/Binaries/negroni"

miss=0
for f in $(grep -rhoE 'Binaries/negroni/[^ |]+' "$MU/Platforms/OnePlus/negroniPkg" | sort -u); do
  [ -e "$MU/$f" ] || { echo "MISSING $f"; miss=1; }
done
[ "$miss" = 0 ] && echo "all Binaries/negroni references present"
exit $miss
