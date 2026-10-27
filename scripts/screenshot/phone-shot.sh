#!/bin/sh
# Screenshot of the running phone over SSH: the render server's picture of the main display (before our
# framebuffer copy), as logs/shots/shot-TIME.png. A fault seen on the panel but not here is in the kernel
# framebuffer stage; a fault seen here is in iOS / Metal.
#   scripts/screenshot/phone-shot.sh [NAME]      NAME default shot-YYYYmmdd-HHMMSS
# Needs userland/screenshot/build.sh output and scripts/net/ssh-phone.sh. Never writes a partition.
set -eu
REPO=$(cd "$(dirname "$0")/../.." && pwd)
SSH=$REPO/scripts/net/ssh-phone.sh
SRC=$REPO/out/screenshot/userland/negroni-shot
BIN=/usr/local/bin/negroni-shot
NAME=${1:-shot-$(date +%Y%m%d-%H%M%S)}
[ -f "$SRC" ] || "$REPO/userland/screenshot/build.sh" >/dev/null
want=$(shasum -a 256 "$SRC" | cut -d' ' -f1)
have=$("$SSH" "shasum -a 256 $BIN 2>/dev/null | cut -d' ' -f1" || true)
if [ "$want" != "$have" ]; then
  "$SSH" "mkdir -p /usr/local/bin && rm -f $BIN.new"
  "$SSH" push "$SRC" "$BIN.new"
  "$SSH" "chmod 755 $BIN.new && mv -f $BIN.new $BIN"
fi
"$SSH" "$BIN /private/var/tmp/$NAME.png"
mkdir -p "$REPO/logs/shots"
"$SSH" pull "/private/var/tmp/$NAME.png" "$REPO/logs/shots/$NAME.png"
"$SSH" "rm -f /private/var/tmp/$NAME.png"
echo "$REPO/logs/shots/$NAME.png"
