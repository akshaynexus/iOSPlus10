#!/bin/bash
# What iOS 16 20H392 needs for AirPlay and AirDrop: read from the root and the dyld cache, so
# docs/laurel_sprout/airplay-airdrop.md can say what is verified. All read-only.
#   scripts/bg.sh air-re scripts/debug/air-re.sh     -> out/air-re/bin/<daemons>, out/air-re/*-strings.txt, out/air-re/hal-plugins.txt
#   scripts/debug/air-re.sh syms IMAGE               -> out/air-re/IMAGE-syms.txt (one image of the dyld cache)
# Needs: python3, apfs-fuse (for the cache); ipsw only for "syms". The Cryptex dmg in ~/op10-apple/20H392, the root image
# ~/op10-apple/laurel-ios16-root.simg (same inputs as wifi-re.sh). macOS + Linux. Apple files stay in out/ (git-ignored).
set -euo pipefail
here=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
main=$(git -C "$here" worktree list --porcelain | sed -n '1s/^worktree //p')
APPLE=${APPLE:-$HOME/op10-apple}
ROOT=$APPLE/laurel-ios16-root.simg
W=$here/out/air-re
mnt=$here/out/mnt-cryptex
mkdir -p "$W/bin"

mount_cache() {
  [ -d "$mnt/root/System" ] && return 0
  mkdir -p "$mnt"
  apfs-fuse -o ro "$APPLE/20H392/087-86593-047.dmg" "$mnt"
}
DSC=$mnt/root/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64

if [ "${1:-}" = syms ]; then
  IPSW=${IPSW:-$(command -v ipsw || echo "$main/out/laurel-metal/ipsw/ipsw")}
  mount_cache
  "$IPSW" dyld symaddr "$DSC" --image "$2" > "$W/$2-syms.txt" 2>/dev/null || true
  wc -l "$W/$2-syms.txt"
  exit 0
fi

# Daemons outside the cache: one extract per file, so a missing path only skips that one.
for f in /usr/libexec/wifip2pd /usr/sbin/wifip2pd /usr/libexec/sharingd /usr/sbin/mDNSResponder /usr/sbin/mediaserverd \
  /usr/libexec/airplayd /usr/libexec/rapportd /usr/sbin/bluetoothd /usr/libexec/mediaremoted /usr/libexec/nearbyd \
  /usr/libexec/lockdownd /usr/libexec/d2d; do
  b=${f##*/}
  [ -s "$W/bin/$b" ] && continue
  t=$W/x-$b; rm -rf "$t"; mkdir -p "$t${f%/*}"   # the extractor needs the parent folder
  python3 -I "$here/scripts/audio/hfs-extract.py" "$ROOT" "$t" "$f" >/dev/null 2>&1 || true
  o=$(find "$t" -type f -name "$b" | head -1)
  if [ -n "$o" ]; then cp "$o" "$W/bin/$b"; echo "air-re: $f: $(wc -c < "$W/bin/$b") bytes"; else echo "air-re: $f: not in the root"; fi
  rm -rf "$t"
done
for b in "$W"/bin/*; do
  [ -f "$b" ] || continue
  n=${b##*/}
  [ -s "$W/$n-strings.txt" ] || strings -a "$b" > "$W/$n-strings.txt"
done
cat "$W"/*-strings.txt | wc -l
# HAL plug-ins and the launchd jobs: the names only
python3 -I "$here/scripts/audio/hfs-extract.py" "$ROOT" "$W/root" /System/Library/Audio/Plug-Ins/HAL /Library/Audio/Plug-Ins/HAL >/dev/null 2>&1 || true
find "$W/root" -maxdepth 8 -name '*.driver' -o -maxdepth 8 -name '*.plugin' > "$W/hal-plugins.txt" 2>/dev/null || true
wc -l "$W/hal-plugins.txt"
# Text of the whole dyld cache (AirPlaySender, CoreUtils, MediaExperience, MediaRemote are inside it): grep this file for a key.
if [ ! -s "$W/dsc-strings.txt" ]; then
  mount_cache
  LC_ALL=C strings -a -n 6 "${DSC%/*}"/dyld_shared_cache_arm64* | grep -aiE 'airplay|mirror|bonjour|_raop|_airdrop|awdl|mobilegestalt|h264|videotoolbox|AppleAVE|H264Encoder|encoder|D2D|wifip2p' > "$W/dsc-strings.txt"
fi
wc -l "$W/dsc-strings.txt"
# The AirPlay images of the cache, one strings file each (ipsw): what they look for, and which frameworks they link.
IPSW=${IPSW:-$(command -v ipsw || echo "$main/out/laurel-metal/ipsw/ipsw")}
if [ -x "$IPSW" ]; then
  mount_cache
  for image in AirPlaySender APTransport AirPlaySupport MediaExperience; do
    [ -s "$W/$image-str.txt" ] || "$IPSW" dyld macho "$DSC" "$image" --strings > "$W/$image-str.txt" 2>/dev/null || true
    [ -s "$W/$image-load.txt" ] || "$IPSW" dyld macho "$DSC" "$image" --loads > "$W/$image-load.txt" 2>/dev/null || true
    wc -l "$W/$image-str.txt" "$W/$image-load.txt"
  done
fi
