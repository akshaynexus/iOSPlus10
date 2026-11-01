#!/bin/bash
# HEVC/HEIC software decoder in a mounted Mi A3 iOS 16 root (scripts/laurel/root.sh calls it; on by default, HEVC=0 skips).
#   sudo scripts/laurel/root-hevc.sh MOUNTED_ROOT
# Puts out/laurel/hevc/HEVCH8.videodecoder (scripts/laurel/hevc-build.sh) at /System/Library/VideoDecoders/HEVCH8.videodecoder: a slot on
# VideoToolbox's own fixed decoder list that the iPhone X system leaves empty, so nothing is injected and no system file changes.
# Ad hoc signed, no entitlements: the kernel's AMFI stand-in treats a signed file on the root as platform code [V NegroniCamera.driver in
# mediaserverd]. Every HEIC stays as Apple ships it. Details: docs/laurel_sprout/hevc.md.
# One line at the end: "laurel-root: hevc: on: ..." or "laurel-root: hevc: off: <reason>". Off = Apple's VCPHEVC.videocodec alone. Idempotent.
# Only HEVC=0 is a wanted off: the other reasons exit 1 and root.sh's table says `hevc missing`.
set -euo pipefail
R=${1:?usage: $0 MOUNTED_ROOT}
REPO=$(cd "$(dirname "$0")/../.." && pwd)
F=$R/System/Library/VideoDecoders/HEVCH8.videodecoder
S=$REPO/out/laurel/hevc/HEVCH8.videodecoder
if [ "${HEVC:-1}" = 0 ]; then
  rm -f "$F"
  echo "laurel-root: hevc: off: HEVC=0: Apple's VCPHEVC.videocodec alone"
  exit 0
fi
[ -d "$R/System/Library/VideoDecoders" ] || { echo "laurel-root: hevc: off: $R has no System/Library/VideoDecoders"; exit 1; }
if [ ! -s "$S" ]; then
  if [ -n "${SUDO_USER:-}" ]; then
    sudo -u "$SUDO_USER" "$REPO/scripts/laurel/hevc-build.sh" || true
  else
    "$REPO/scripts/laurel/hevc-build.sh" || true
  fi
fi
if [ ! -s "$S" ]; then
  rm -f "$F"
  echo "laurel-root: hevc: off: no $S (scripts/laurel/hevc-build.sh failed): Apple's VCPHEVC.videocodec alone"
  exit 1
fi
want=$(sed -n 's/ .*HEVCH8.videodecoder$//p' "$(dirname "$S")/SHA256SUMS" 2>/dev/null || true)
have=$(sha256sum "$S" 2>/dev/null | cut -d' ' -f1 || shasum -a 256 "$S" | cut -d' ' -f1)
if [ -z "$want" ] || [ "$want" != "$have" ]; then
  rm -f "$F"
  echo "laurel-root: hevc: off: $S does not match its SHA256SUMS: Apple's VCPHEVC.videocodec alone"
  exit 1
fi
install -m 755 "$S" "$F"
[ "$(id -u)" != 0 ] || chown 0:0 "$F"
echo "laurel-root: hevc: on: HEVCH8.videodecoder, $(wc -c < "$F") bytes, sha256 ${have%"${have#????????????????}"}"
