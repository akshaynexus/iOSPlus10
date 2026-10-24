#!/bin/sh
# Convert the raw iOS root image to an Android sparse image for `fastboot flash userdata`.
#   scripts/ios16-root-simg.sh [IN.img]        (default $APPLE/ios16-root.img -> $APPLE/ios16-root.simg)
# Runs img2simg in the build container (macOS) or on the host if img2simg exists (Linux).
set -eu
. "$(dirname "$0")/env.sh"
APPLE=${APPLE:-$HOME/op10-apple}
IN=${1:-$APPLE/ios16-root.img}
OUTS=${IN%.img}.simg
if command -v img2simg >/dev/null 2>&1; then
  img2simg "$IN" "$OUTS"
else
  docker run --rm --platform linux/amd64 -v "$(dirname "$IN"):/data" "$IMAGE" \
    img2simg "/data/$(basename "$IN")" "/data/$(basename "$OUTS")"
fi
ls -l "$IN" "$OUTS"
shasum -a 256 "$OUTS"
