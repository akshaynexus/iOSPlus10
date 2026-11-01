#!/bin/sh
# Make patches/laurel/xnu/2770-laurel-ipa-v42.patch from the IPA dev trees: out/ipa2-dev/a = the files of the
# patched laurel tree before 2770, out/ipa2-dev/b = the same files with the 2770 changes + the new files.
# The patch's description (the lines before the first "diff") is kept. Development helper; quick.
#   scripts/laurel/ipa-patch.sh
set -eu
. "$(dirname "$0")/../lib/env.sh"
D=$OUT/ipa2-dev
P=$REPO/patches/laurel/xnu/2770-laurel-ipa-v42.patch
[ -d "$D/a" ] && [ -d "$D/b" ] || { echo "ipa-patch: no $D/a and $D/b" >&2; exit 1; }
if [ -f "$P" ]; then
  awk '/^diff /{exit} {print}' "$P" > "$P.tmp"
else
  printf 'laurel 2770: IPA v4.2 AP side (see docs/laurel_sprout/cellular.md)\n\n' > "$P.tmp"
fi
(cd "$D" && diff -ruN a b) >> "$P.tmp" || true
mv "$P.tmp" "$P"
echo "ipa-patch: $P ($(grep -c '^diff ' "$P") files)"
