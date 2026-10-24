#!/bin/sh
# Download only the three iOS 16.7.16 (iPhone10,3, 20H392) images that the root needs, from Apple's
# IPSW with parallel HTTP range requests (op10tool ipsw-get, 32 threads, CRC-32 checked, resumable):
#   087-86698-044.dmg  OS          (4.7 GB)
#   087-86593-047.dmg  SystemOS    (2.7 GB, cryptex)
#   087-86715-047.dmg  AppOS       (10 MB, cryptex)
# Output: $APPLE/20H392/ (default ~/op10-apple, never in git). Run in tmux:
#   scripts/bg.sh dmgs scripts/ios16/fetch-dmgs.sh
set -eu
. "$(dirname "$0")/../lib/env.sh"
APPLE=${APPLE:-$HOME/op10-apple}
URL=${IPSW_URL:-https://updates.cdn-apple.com/2025FallFCS/fullrestores/122-77006/1158E502-D76D-4226-AA06-ED5E30CD1111/iPhone10,3,iPhone10,6_16.7.16_20H392_Restore.ipsw}
D=$APPLE/20H392
mkdir -p "$D"
"$OUT/bin/op10tool" ipsw-get -j "${JOBS:-32}" "$URL" "$D" \
  087-86715-047.dmg 087-86593-047.dmg 087-86698-044.dmg
ls -l "$D"
