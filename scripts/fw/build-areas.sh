#!/bin/sh
# Build and check the three firmware area images for the end of userdata (host only, no phone).
#   scripts/fw/build-areas.sh
# Inputs: out/firmware/gpu (scripts/fw/extract-gpu-fw.sh), out/firmware/adsp
# (scripts/audio/extract-adsp-fw.sh), out/firmware/wlan (scripts/wifi/extract-fw.sh).
# Output (git-ignored, vendor firmware: never commit it):
#   out/firmware/gpu-area.bin    8 MiB   mkfwarea.py      -> userdata blocks N-3073 .. N-1026
#   out/firmware/adsp-area.bin   32 MiB  mkadsparea.py    -> userdata blocks N-11265 .. N-3074
#   out/firmware/wlan-area.bin   32 MiB  mkwlanarea.py    -> userdata blocks N-19457 .. N-11266
#   out/firmware/AREAS.sha256    sha256 of the three images
# Every image is checked with scripts/fw/checkarea.py (the kernel reader rules).
# Write them with scripts/fw/write-areas.sh (owner approval needed).
set -eu
. "$(dirname "$0")/../lib/env.sh"
F=$OUT/firmware
G=$F/gpu
PY="python3 -I"
for f in a730_zap.mdt a730_zap.b00 a730_zap.b01 a730_zap.b02 a730_zap.mbn a730_sqe.fw gmu_gen70000.bin; do
  [ -s "$G/$f" ] || { echo "missing $G/$f (scripts/fw/extract-gpu-fw.sh)" >&2; exit 1; }
done
$PY "$EXT/slop/negroni-ios/tools/mkfwarea.py" "$F/gpu-area.bin" \
  "$G/a730_zap.mdt" "$G/a730_zap.b00" "$G/a730_zap.b01" "$G/a730_zap.b02" "$G/a730_zap.mbn" \
  "$G/gmu_gen70000.bin" "$G/a730_sqe.fw"
$PY "$REPO/scripts/audio/mkadsparea.py" "$F/adsp-area.bin" "$F/adsp"
$PY "$REPO/scripts/wifi/mkwlanarea.py" "$F/wlan-area.bin" "$F/wlan"
for k in gpu adsp wlan; do
  $PY "$REPO/scripts/fw/checkarea.py" "$k" "$F/$k-area.bin"
done
(cd "$F" && shasum -a 256 gpu-area.bin adsp-area.bin wlan-area.bin) > "$F/AREAS.sha256"
cat "$F/AREAS.sha256"
