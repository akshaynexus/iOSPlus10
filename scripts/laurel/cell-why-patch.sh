#!/bin/sh
# Make patch 2943 from its dev tree (development helper; quick): out/cden-dev/{a,b} -> patches/laurel/xnu/2943-laurel-cell-reject-cause.patch
# a = laurel_cell.c + TopazModem.cpp of the patched tree without 2943 (out/laurel-kernel/xnu-src/...), b = the same with the change + laurel_cell_why.h.
# The patch's description (the lines before the first "diff") is kept.
set -eu
. "$(dirname "$0")/../lib/env.sh"
D=$OUT/cden-dev
P=$REPO/patches/laurel/xnu/2943-laurel-cell-reject-cause.patch
[ -d "$D/a" ] && [ -d "$D/b" ] || { echo "cell-why-patch: no $D/a and $D/b" >&2; exit 1; }
[ -f "$P" ] && awk '/^diff /{exit} {print}' "$P" > "$P.tmp" || : > "$P.tmp"
(cd "$D" && diff -ruN a b) >> "$P.tmp" || true
mv "$P.tmp" "$P"
echo "cell-why-patch: $P ($(grep -c '^diff ' "$P") files)"
