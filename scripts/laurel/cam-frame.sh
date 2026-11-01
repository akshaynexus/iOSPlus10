#!/bin/sh
# One rear-camera picture from the Mi A3 over the USB link (kernel patch 2771; docs/laurel_sprout/camera.md section 8).
#   scripts/laurel/cam-frame.sh [OUT_DIR]          (default logs/camera; the USB link must be up: make usblog)
#   scripts/laurel/cam-frame.sh --raw FILE.raw10   (convert a saved frame again; no phone)
# The phone captures 1.5 s (auto exposure settles), keeps the last frame; op10tool camframe reads it in 1400-byte
# parts (UDP 5141 "camread"), writes OUT_DIR/camframe-genN.raw10 (MIPI RAW10, 1280x720, RGGB) and a PNG
# (bilinear demosaic, grey-world white balance, sRGB gamma). Extra arguments go to op10tool camframe
# (--no-capture: the frame the phone already keeps; --bayer BGGR: other Bayer order). macOS and Linux.
set -eu
. "$(dirname "$0")/../lib/env.sh"
OP=$OUT/bin/op10tool
[ -x "$OP" ] || "$REPO/scripts/setup/build-op10tool.sh"
case "${1:-}" in
--raw) shift; f=${1:?usage: $0 --raw FILE.raw10}; shift
       exec "$OP" camframe --raw "$f" --out "$(dirname "$f")" "$@" ;;
-*|"") exec "$OP" camframe --out "$REPO/logs/camera" "$@" ;;
*)     d=$1; shift; exec "$OP" camframe --out "$d" "$@" ;;
esac
