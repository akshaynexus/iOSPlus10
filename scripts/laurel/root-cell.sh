#!/bin/bash
# Mi A3 root: the cellular bridge for SpringBoard (docs/laurel_sprout/cellular.md section 9): SIM, bars, network name in iOS from kern.laurel_cell_state.
#   root-cell.sh MOUNTED_ROOT     env: CELL=0 skips. NOTCH=0 or STATUSBAR=0 also skip it: laurel-springboard (root-statusbar.py part 2) inserts the dylib.
# Stage: out/laurel/cell/root (scripts/laurel/cell-build.sh). Exit 1 = wanted and cannot be installed: the feature table lists it as missing.
set -euo pipefail
R=${1:?usage: root-cell.sh MOUNTED_ROOT}
REPO=$(cd "$(dirname "$0")/../.." && pwd)
for s in CELL NOTCH STATUSBAR; do
  if [ "$(printenv "$s" || echo 1)" = 0 ]; then echo "root-cell: off: $s=0"; exit 0; fi
done
F=usr/local/lib/liblaurel-cellbar.dylib
S=$REPO/out/laurel/cell/root/$F
[ -s "$S" ] || { echo "root-cell: WARNING: no $S (scripts/laurel/cell-build.sh first)" >&2; exit 1; }
file -b "$S" 2>/dev/null | grep -q 'dynamically linked shared library' || { echo "root-cell: WARNING: $S is not a dylib" >&2; exit 1; }
mkdir -p "$R/usr/local/lib"
cp "$S" "$R/$F.new"
if [ "$(id -u)" = 0 ]; then chown 0:0 "$R/$F.new"; fi
chmod 755 "$R/$F.new"
mv "$R/$F.new" "$R/$F"
echo "root-cell: on: /$F sha256 $(sha256sum "$R/$F" | cut -d' ' -f1)"
# the data session in configd: daemon + launchd job (section 11). A kernel without kern.laurel_cell_net: it exits at once
D=usr/local/libexec/laurel-celld
S=$REPO/out/laurel/cell/root/$D
[ -s "$S" ] || { echo "root-cell: WARNING: no $S (scripts/laurel/cell-build.sh first)" >&2; exit 1; }
file -b "$S" 2>/dev/null | grep -q 'Mach-O' || [ "$(head -c4 "$S" | od -An -tx1 | tr -d ' ')" = cffaedfe ] || { echo "root-cell: WARNING: $S is not a Mach-O" >&2; exit 1; }
mkdir -p "$R/usr/local/libexec"
cp "$S" "$R/$D.new"
if [ "$(id -u)" = 0 ]; then chown 0:0 "$R/$D.new"; fi
chmod 755 "$R/$D.new"
mv "$R/$D.new" "$R/$D"
python3 -I "$REPO/scripts/laurel/celld-job.py" "$R" on
echo "root-cell: on: /$D sha256 $(sha256sum "$R/$D" | cut -d' ' -f1)"
