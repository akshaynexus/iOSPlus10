#!/bin/sh
# Make patch 2786 from its dev tree (development helper; quick): out/celln-dev/{a,b}/bsd/dev/laurel_cell.c -> patches/laurel/xnu/2786-laurel-cell-radio-state.patch
# a = the file of the patched laurel tree before 2786 (scripts/laurel/kernel-linux.sh AUDIT=1, without 2786), b = the same file with the change.
# The patch's description (the lines before the first "diff") is kept.
set -eu
. "$(dirname "$0")/../lib/env.sh"
D=$OUT/celln-dev
P=$REPO/patches/laurel/xnu/2786-laurel-cell-radio-state.patch
[ -d "$D/a" ] && [ -d "$D/b" ] || { echo "cell-patch: no $D/a and $D/b" >&2; exit 1; }
awk '/^diff /{exit} {print}' "$P" > "$P.tmp"
(cd "$D" && diff -ruN a b) >> "$P.tmp" || true
mv "$P.tmp" "$P"
echo "cell-patch: $P ($(grep -c '^diff ' "$P") files)"
