#!/bin/sh
# Mark a kernel as the last good one for the boot menu (mu 0202, docs/laurel_sprout/boot-menu.md section 10): the next uefi-image.sh puts it into the
# payload as the entry "ios-lastgood", and the menu boots it by default after 2 iOS boots in a row that did not end well (ABL's retries say so), with no key
# and no computer. Run it after a boot the owner calls good.
#   scripts/laurel/mark-kernel-good.sh [KERNEL]      default: the kernel of the last image, from out/laurel/uefi/laurel-uefi-boot.img.stamp (kernel_sha256) =
#                                                     out/laurel-kernel-ios26/out/kernel.ios26.development.sweet.4k or out/laurel-kernel/out/kernel.development.sweet.4k
# Writes out/laurel/uefi/last-good/kernel (+ .stamp, + a note with the date and the source). Nothing on the phone changes until the next image is flashed.
set -eu
. "$(dirname "$0")/../lib/env.sh"
W=${UEFI_W:-$OUT/laurel/uefi}
K=${1:-}
if [ -z "$K" ]; then
  want=$(sed -n 's/^kernel_sha256=//p' "$W/laurel-uefi-boot.img.stamp" 2>/dev/null || true)
  for c in "$OUT/laurel-kernel-ios26/out/kernel.ios26.development.sweet.4k" "$OUT/laurel-kernel/out/kernel.development.sweet.4k"; do
    [ -f "$c" ] || continue
    if [ -n "$want" ] && [ "$(sha256sum "$c" | cut -d' ' -f1)" = "$want" ]; then K=$c; break; fi
  done
  [ -n "$K" ] || { echo "mark-kernel-good: no kernel matches the last image's stamp ($W/laurel-uefi-boot.img.stamp); give the path" >&2; exit 1; }
fi
[ -f "$K" ] || { echo "mark-kernel-good: no such kernel: $K" >&2; exit 1; }
[ -f "$K.stamp" ] || { echo "mark-kernel-good: $K has no .stamp (build-honest.md): not a kernel the build scripts made" >&2; exit 1; }
python3 -I "$REPO/scripts/laurel/build-stamp.py" kernel-check "$K" --no-repo
mkdir -p "$W/last-good"
cp "$K" "$W/last-good/kernel.new" && mv -f "$W/last-good/kernel.new" "$W/last-good/kernel"
cp "$K.stamp" "$W/last-good/kernel.stamp"
printf 'marked %s\nsource %s\nsha256 %s\n' "$(date -u +%Y%m%dT%H%M%SZ)" "$K" "$(sha256sum "$K" | cut -d' ' -f1)" > "$W/last-good/note.txt"
echo "mark-kernel-good: $W/last-good/kernel <- $K ($(head -1 "$K.stamp")); the next uefi-image.sh adds the entry ios-lastgood"
