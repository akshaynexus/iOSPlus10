#!/bin/sh
# Make the laurel IPA patches from their dev trees (development helper; quick):
#   scripts/laurel/ipa-patch.sh pas   out/ipa3-dev/pas/{a,b} -> patches/laurel/xnu/2775-laurel-pas-load.patch
#   scripts/laurel/ipa-patch.sh ipa   out/ipa3-dev/ipa/{a,b} -> patches/laurel/xnu/2780-laurel-ipa-v42.patch
#   scripts/laurel/ipa-patch.sh gsi   out/ipa3-dev/gsi/{a,b} -> patches/laurel/xnu/2782-laurel-ipa-gsi-channels.patch
# a = the files of the patched laurel tree before the patch, b = the same files with its changes + the new files
# (copies from out/laurel-kernel/xnu-src after editing there; kcheck each file with scripts/laurel/kcheck.sh).
# The patch's description (the lines before the first "diff") is kept.
set -eu
. "$(dirname "$0")/../lib/env.sh"
case "${1:-ipa}" in
pas) D=$OUT/ipa3-dev/pas; P=$REPO/patches/laurel/xnu/2775-laurel-pas-load.patch
     T='laurel 2775: one shared TrustZone PAS loader (bsd/dev/topaz_pas.c)' ;;
ipa) D=$OUT/ipa3-dev/ipa; P=$REPO/patches/laurel/xnu/2780-laurel-ipa-v42.patch
     T='laurel 2780: IPA v4.2 AP side (see docs/laurel_sprout/cellular.md)' ;;
gsi) D=$OUT/ipa3-dev/gsi; P=$REPO/patches/laurel/xnu/2782-laurel-ipa-gsi-channels.patch
     T='laurel 2782: IPA v4.2: allocate the GSI channels (see docs/laurel_sprout/cellular.md section 8)' ;;
*)   echo "usage: ipa-patch.sh pas|ipa|gsi" >&2; exit 2 ;;
esac
[ -d "$D/a" ] && [ -d "$D/b" ] || { echo "ipa-patch: no $D/a and $D/b" >&2; exit 1; }
if [ -f "$P" ]; then
  awk '/^diff /{exit} {print}' "$P" > "$P.tmp"
else
  printf '%s\n\n' "$T" > "$P.tmp"
fi
(cd "$D" && diff -ruN a b) >> "$P.tmp" || true
mv "$P.tmp" "$P"
echo "ipa-patch: $P ($(grep -c '^diff ' "$P") files)"
