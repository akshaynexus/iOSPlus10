#!/bin/sh
# Convert the raw iOS root image to an Android sparse image for `fastboot flash userdata`.
#   scripts/ios16/root-simg.sh [IN.img]        (default $APPLE/ios16-root.img -> $APPLE/ios16-root.simg)
# Uses `op10tool img2simg` (holes -> DONT_CARE, uniform blocks -> FILL); its output decodes
# byte-identical with AOSP simg2img (tools/op10tool/tests).
set -eu
. "$(dirname "$0")/../lib/env.sh"
APPLE=${APPLE:-$HOME/op10-apple}
IN=${1:-$APPLE/ios16-root.img}
OUTS=${IN%.img}.simg
"$OUT/bin/op10tool" img2simg "$IN" "$OUTS"
ls -l "$IN" "$OUTS"
shasum -a 256 "$OUTS"
