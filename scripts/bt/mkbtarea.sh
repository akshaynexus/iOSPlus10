#!/bin/sh
# Put the Bluetooth firmware into the WLAN firmware area (patch 0331, negronibt=3). Host only, no phone.
#   scripts/bt/mkbtarea.sh
# Inputs: out/bt/firmware (scripts/bt/fetch-firmware.sh), out/firmware/wlan (scripts/wifi/extract-fw.sh).
# 1. scripts/bt/mkbtpack.py -> out/firmware/wlan/negroni-bt.bin (one pack file: 16 KiB header + the 105 hp* files)
# 2. scripts/wifi/mkwlanarea.py -> out/firmware/wlan-area.bin (32 MiB; every file of out/firmware/wlan, so the
#    pack is one more entry next to amss.bin, m3.bin, ...), then scripts/fw/checkarea.py wlan.
# The area keeps its place: userdata blocks N-19457 .. N-11266 (N = 58672399 on the NE2211), byte 0 of the area =
# block N-19457. The kernel (negroni_bt_hci.c step 12) reads the area header, finds "negroni-bt.bin", reads the
# pack header at that entry's offset, then each file at entry offset + pack offset.
# Write it like the other areas (ASK THE OWNER FIRST, it writes userdata):
#   AREAS=1 scripts/ios16/root-simg.sh          (the areas go into the userdata flash image), or
#   AREAS=wlan CONFIRM=yes scripts/fw/write-areas.sh
#   (both = dd if=out/firmware/wlan-area.bin of=userdata bs=4096 seek=$((N-19457)) conv=notrunc,fsync)
# A `fastboot flash userdata` of an image without the areas (for example when iOS is flashed back) erases it.
# Vendor firmware: never commit the outputs. scripts/wifi/extract-fw.sh re-creates out/firmware/wlan: run this
# script again after it.
set -eu
. "$(dirname "$0")/../lib/env.sh"
F=$OUT/firmware
PY="python3 -I"
[ -f "$F/wlan/m3.bin" ] || { echo "no $F/wlan/m3.bin (scripts/wifi/extract-fw.sh)" >&2; exit 1; }
$PY "$REPO/scripts/bt/mkbtpack.py" "$F/wlan/negroni-bt.bin" "$OUT/bt/firmware"
$PY "$REPO/scripts/wifi/mkwlanarea.py" "$F/wlan-area.bin" "$F/wlan"
$PY "$REPO/scripts/fw/checkarea.py" wlan "$F/wlan-area.bin"
if [ -f "$F/AREAS.sha256" ]; then
  grep -v ' wlan-area.bin$' "$F/AREAS.sha256" > "$F/AREAS.sha256.new" || true
  (cd "$F" && shasum -a 256 wlan-area.bin) >> "$F/AREAS.sha256.new"
  mv "$F/AREAS.sha256.new" "$F/AREAS.sha256"
fi
