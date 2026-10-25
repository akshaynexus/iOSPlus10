#!/bin/sh
# Extract the stock audio configuration of the NE2211 from the vendor/odm/vendor_dlkm images
# (read-only) into out/audio-src/ (git-ignored: vendor files, never commit them).
#   scripts/bg.sh audio-vendor scripts/audio/extract-vendor-audio.sh
# Input: out/camera/payload/{vendor,odm,vendor_dlkm}.img (scripts/camera/inventory.sh makes them
# from the OTA with payload-dumper-go). Override with PAYLOAD=dir.
# Needs: fsck.erofs (erofs-utils), debugfs (e2fsprogs; macOS: brew install e2fsprogs, keg-only,
# the script finds it). scripts/setup/native-tools.sh installs both.
# Output:
#   out/audio-src/vendor/etc/...      the vendor /etc audio files (ACDB, AudioReach, mixer paths)
#   out/audio-src/odm/...             odm audio files (OnePlus overrides, TFA98xx container)
#   out/audio-src/vendor_dlkm/...     audio kernel modules (*.ko: symbols/strings only)
#   out/audio-src/LISTING.txt         every audio-related path in the three images
#   out/audio-src/SHA256SUMS
set -eu
. "$(dirname "$0")/../lib/env.sh"
P=${PAYLOAD:-$OUT/camera/payload}
X=$OUT/audio-src
DEBUGFS=$(command -v debugfs || echo /opt/homebrew/opt/e2fsprogs/sbin/debugfs)
command -v fsck.erofs >/dev/null || { echo "fsck.erofs missing (scripts/setup/native-tools.sh)" >&2; exit 1; }
mkdir -p "$X"
rm -rf "${X:?}/vendor" "${X:?}/odm" "${X:?}/vendor_dlkm" "${X:?}/.full"
mkdir -p "$X/.full"

# Full EROFS extraction into a scratch tree (~1-2 GB), then keep the audio files only.
# --overwrite: macOS file systems are case-insensitive; odm has names that differ in case only.
for img in vendor odm; do
  fsck.erofs --no-preserve --overwrite --extract="$X/.full/$img" "$P/$img.img" >/dev/null
done
# vendor_dlkm is ext4: debugfs rdump of /lib/modules
mkdir -p "$X/.full/vendor_dlkm"
"$DEBUGFS" -R "rdump /lib $X/.full/vendor_dlkm" "$P/vendor_dlkm.img" >/dev/null 2>&1 || true

PAT='acdb|audio|mixer_path|resourcemanager|card-def|tfa|\.cnt$|sia81|aw88|ar_|agm|pal|kvh2xml|usecase|speaker|spk|graph|gsl|\.qwsp$|\.acdb$|sound'
(cd "$X/.full" && find . -type f | sed 's|^\./||' | grep -Ei "$PAT" | grep -v -E '\.(apk|odex|vdex|art|oat)$' | sort) > "$X/LISTING.txt"
while IFS= read -r f; do
  mkdir -p "$X/$(dirname "$f")"
  cp "$X/.full/$f" "$X/$f"
done < "$X/LISTING.txt"
rm -rf "${X:?}/.full"
(cd "$X" && find vendor odm vendor_dlkm -type f -exec shasum -a 256 {} + | sort -k2) > "$X/SHA256SUMS"
wc -l "$X/LISTING.txt"
grep -Ei 'acdb|tfa|\.cnt|mixer_paths|resourcemanager|card-defs|platform_info' "$X/LISTING.txt" | head -80
