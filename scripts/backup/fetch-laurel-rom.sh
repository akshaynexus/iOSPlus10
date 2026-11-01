#!/bin/sh
# Download and unpack the official Xiaomi Mi A3 (laurel_sprout) fastboot ROM.
# It gives the stock images for restore and the boot/dtbo/modem/dsp/bluetooth images for the port
# (device tree, firmware) without root on the phone. The files stay outside git.
#
#   scripts/backup/fetch-laurel-rom.sh [outdir]       default: ~/laurel-backup
#   (run in tmux: scripts/bg.sh laurel-rom scripts/backup/fetch-laurel-rom.sh)
# Build: V12.0.26.0.RFQMIXM (Android 11, 2022-08), the build on the phone on 2026-10-31.
# Needs: aria2c (fast, several mirrors) or curl (one mirror), tar.
set -eu
OUT=${1:-$HOME/laurel-backup}
VER=V12.0.26.0.RFQMIXM
FILE=laurel_sprout_global_images_${VER}_20220808.0000.00_11.0_2292e2c0b1.tgz
# Mirrors, fastest first (measured 2026-10-31 with an 8 MiB range: cdnorg 4.9 MiB/s, Aliyun SGP 4.0 MiB/s,
# bn 3.0 MiB/s, bigota 41 KiB/s). aria2c takes all of them at once and splits the file over them.
MIRRORS="cdnorg.d.miui.com bkt-sgp-miui-ota-update-alisgp.oss-ap-southeast-1.aliyuncs.com bn.d.miui.com bigota.d.miui.com"
MD5_PREFIX=2292e2c0b1   # Xiaomi puts the first 10 hex digits of the MD5 in the file name

mkdir -p "$OUT"
cd "$OUT"
if [ ! -f "$FILE" ]; then
  if command -v aria2c >/dev/null; then
    set --
    for m in $MIRRORS; do set -- "$@" "https://$m/$VER/$FILE"; done
    # -c continues a .part file; -x16 -s16 -k1M: 16 connections over the mirrors, 1 MiB pieces
    aria2c -c -x 16 -s 16 -j 1 -k 1M --file-allocation=none --uri-selector=adaptive \
      --max-tries=0 --retry-wait=5 --summary-interval=30 -o "$FILE.part" "$@"
  else
    curl -fL -C - -o "$FILE.part" "https://${MIRRORS%% *}/$VER/$FILE"
  fi
  mv "$FILE.part" "$FILE"
fi
md5=$( (md5sum "$FILE" 2>/dev/null || md5 -r "$FILE") | cut -c1-10)
[ "$md5" = "$MD5_PREFIX" ] || { echo "MD5 $md5 is not $MD5_PREFIX" >&2; exit 1; }
echo "MD5 prefix ok: $md5"
[ -d stock ] || { mkdir stock.partial && tar -xzf "$FILE" -C stock.partial --strip-components=1 && mv stock.partial stock; }
ls -la stock/images | head -60
