#!/bin/sh
# Convert the raw iOS root image to an Android sparse image for `fastboot flash userdata`.
#   scripts/ios16-root-simg.sh [IN.img]        (default $APPLE/ios16-root.img -> $APPLE/ios16-root.simg)
# Uses scripts/img2simg.py (pure Python; holes -> DONT_CARE, uniform blocks -> FILL), checked
# byte-identical against AOSP simg2img.
set -eu
. "$(dirname "$0")/env.sh"
APPLE=${APPLE:-$HOME/op10-apple}
IN=${1:-$APPLE/ios16-root.img}
OUTS=${IN%.img}.simg
python3 "$REPO/scripts/img2simg.py" "$IN" "$OUTS"
ls -l "$IN" "$OUTS"
shasum -a 256 "$OUTS"
