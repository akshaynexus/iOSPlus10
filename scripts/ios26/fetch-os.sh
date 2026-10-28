#!/bin/bash
# Get the iOS 26 donor OS images for the root build (no full IPSW download): the OS volume (7.4 GB AEA), the
# SystemOS cryptex (2.0 GB AEA), the AppOS cryptex (14 MB, plain), their trust caches and root hashes.
# AEA keys come from Apple's public key service (ipsw fw aea --key reads com.apple.wkms.fcs-key-url).
#   scripts/bg.sh ios26-os scripts/ios26/fetch-os.sh
# Disk: the decrypted OS image is about 15 GB [U] and the SystemOS 5.2 GB [V]: needs NEED_GIB free (default 30);
# the script refuses with less. The Mac has about 12-14 GiB free (2026-10-27), so this does NOT run there today:
# run it on the Linux host (scripts/setup/docker-image.sh environment) or after the owner frees disk.
# Output: $APPLE/ios26/23F84-d421ap/os/ (never in git). STATUS: written, not run.
set -euo pipefail
. "$(dirname "$0")/../lib/env.sh"
APPLE=${APPLE:-$HOME/op10-apple}
URL=${IPSW_URL:-https://updates.cdn-apple.com/2026SpringFCS/fullrestores/140-25381/6ABE5EEB-511D-4DF4-AB43-FE86D0A7718A/iPhone12,3,iPhone12,5_26.5.2_23F84_Restore.ipsw}
D=${OUTDIR:-$APPLE/ios26/23F84-d421ap/os}
NEED_GIB=${NEED_GIB:-30}
free=$(df -g "$(dirname "$D")" 2>/dev/null | awk 'NR==2 {print $4}' || df -BG --output=avail "$(dirname "$D")" | tail -1 | tr -dc 0-9)
if [ "${free:-0}" -lt "$NEED_GIB" ]; then
  echo "only ${free} GiB free, need $NEED_GIB GiB (OS 7.4 GB AEA + decrypted image + SystemOS): not started" >&2; exit 1
fi
command -v ipsw >/dev/null || { echo "needs blacktop ipsw (brew install blacktop/tap/ipsw)" >&2; exit 1; }
mkdir -p "$D"
# Members from BuildManifest (23F84): OS, Cryptex1,SystemOS, Cryptex1,AppOS and their trust caches / root hashes
"$OUT/bin/op10tool" ipsw-get -j 16 "$URL" "$D" \
  094-55352-108.dmg.aea 094-55541-109.dmg.aea 094-54871-112.dmg \
  Firmware/094-55352-108.dmg.aea.trustcache Firmware/094-55541-109.dmg.aea.trustcache Firmware/094-54871-112.dmg.trustcache \
  Firmware/094-55352-108.dmg.aea.root_hash Firmware/094-55541-109.dmg.aea.root_hash Firmware/094-54871-112.dmg.root_hash
for a in "$D"/094-55352-108.dmg.aea "$D"/094-55541-109.dmg.aea; do
  ipsw fw aea --key "$a" > "$a.key"
  ipsw fw aea --output "$D" "$a"          # writes the .dmg next to it
  rm -f "$a"                              # keep only the decrypted image (disk)
done
(cd "$D" && shasum -a 256 ./*.dmg ./*.trustcache ./*.root_hash > SHA256SUMS)
ls -l "$D"
