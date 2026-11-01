#!/bin/bash
# The stock wallpapers of a mounted Mi A3 iOS 16 root as PNG (scripts/laurel/root.sh calls it; on by default, WALLPAPER_PNG=0 skips).
#   sudo scripts/laurel/root-wallpaper.sh MOUNTED_ROOT      (macOS: sips; Linux: heif-convert from libheif)
# Why [V ios-flame HANDOFF 289-295 + 20H392 root]: the default wallpaper (id 7400 "WWDC 2022", CollectionsPoster, a CA package per
# screen class in /Library/Wallpaper/Collections/iOS_16~iphone.wallpaperCollection) is made of HEIC layers. iOS 16 decodes HEVC with
# Apple's video hardware only; on a phone without it ImageIO gives an image with no data, the opaque layer is drawn black (flame:
# "Lock screen black block = HEIC"; it wrote PNGs over the files by hand on its phone). The files keep their names: ImageIO goes by
# the content, the .caml files name the .HEIC. Photos and other HEIC images stay blank: that needs a software HEVC decoder.
# One line at the end: "laurel-root: wallpaper: on: N HEIC layers as PNG ..." or "laurel-root: wallpaper: off: <reason>". A failed
# conversion leaves its file as it was and turns off nothing else. Idempotent. Details: docs/laurel_sprout/metal.md section 11.
set -euo pipefail
R=${1:?usage: $0 MOUNTED_ROOT}
W=$R/Library/Wallpaper
[ "${WALLPAPER_PNG:-1}" != 0 ] || { echo "laurel-root: wallpaper: off: WALLPAPER_PNG=0"; exit 0; }
[ -d "$W/Collections" ] || { echo "laurel-root: wallpaper: off: no $W/Collections"; exit 0; }
if command -v heif-convert >/dev/null; then
  conv='heif-convert -q 100 "$1" "$2" >/dev/null 2>&1'
elif command -v sips >/dev/null; then
  conv='sips -s format png "$1" --out "$2" >/dev/null 2>&1'
else
  echo "laurel-root: wallpaper: off: no heif-convert (Linux: libheif) and no sips (macOS): the stock wallpapers stay HEIC, black on this phone"
  exit 0
fi
NPROC=${NPROC:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu)}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/laurel-wallpaper.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
# one layer: an HEIF file (bytes 4-7 "ftyp") becomes a PNG of the same name, mode and owner; prints "png" or "fail"
one() {
  f=$1; t=$tmp/$$-$(printf '%s' "$f" | cksum | cut -d' ' -f1).png
  [ "$(dd if="$f" bs=1 skip=4 count=4 2>/dev/null)" = ftyp ] || { echo skip; return; }
  if ! sh -c "$conv" sh "$f" "$t" || [ ! -s "$t" ] || [ "$(dd if="$t" bs=1 skip=1 count=3 2>/dev/null)" != PNG ]; then
    rm -f "$t"; echo "fail $f"; return
  fi
  cat "$t" > "$f"; rm -f "$t"; echo png
}
export -f one; export conv tmp
find "$W/Collections" -type f -iname '*.heic' -print0 | xargs -0 -n1 -P "$NPROC" bash -c 'one "$0"' > "$tmp/result"
png=$(grep -c '^png' "$tmp/result" || true); skip=$(grep -c '^skip' "$tmp/result" || true); fail=$(grep -c '^fail' "$tmp/result" || true)
sed -n 's/^fail /laurel-root: wallpaper: not converted: /p' "$tmp/result" | head -5
size=$(find "$W/Collections" -type f -iname '*.heic' -exec cat {} + | wc -c)
if [ $((png + skip)) = 0 ]; then
  echo "laurel-root: wallpaper: off: no layer could be converted ($fail failed): the stock wallpapers stay HEIC, black on this phone"
  exit 0
fi
echo "laurel-root: wallpaper: on: $png HEIC layers as PNG ($skip were already, $fail failed), $((size / 1048576)) MiB in all"
