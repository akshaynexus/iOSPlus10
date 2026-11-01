#!/bin/sh
# Make one laurel kernel patch from two dev trees (development helper; quick).
#   scripts/laurel/crad-patch.sh PATCH-NAME TITLE-FILE-OR-EMPTY OLD NEW
#     OLD, NEW   directories under out/crad-dev with the touched files at their tree paths
# The patch's description (the lines before the first "diff") is kept when the patch exists; else TITLE is the text.
# a = the patched laurel tree before the patch (scripts/laurel/kernel-linux.sh AUDIT=1), b = with the change. kcheck each file with scripts/laurel/kcheck.sh.
set -eu
. "$(dirname "$0")/../lib/env.sh"
N=$1; T=$2; A=$3; B=$4
D=$OUT/crad-dev
P=$REPO/patches/laurel/xnu/$N.patch
[ -d "$D/$A" ] && [ -d "$D/$B" ] || { echo "crad-patch: no $D/$A or $D/$B" >&2; exit 1; }
W=$D/.w.$$
mkdir -p "$W"
ln -s "../$A" "$W/a"
ln -s "../$B" "$W/b"
if [ -f "$P" ]; then awk '/^diff /{exit} {print}' "$P" > "$P.tmp"; else printf '%s\n\n' "$T" > "$P.tmp"; fi
(cd "$W" && diff -ruN a/ b/ | sed -e 's|^diff -ruN a//*|diff -ruN a/|' -e 's| b//*| b/|' -e 's|^--- a//*|--- a/|' -e 's|^+++ b//*|+++ b/|') >> "$P.tmp" || true
rm -rf "$W"
mv "$P.tmp" "$P"
echo "crad-patch: $P ($(grep -c '^diff ' "$P") files, $(wc -l < "$P") lines)"
