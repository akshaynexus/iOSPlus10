#!/bin/bash
# Rear camera sensor tables in the Mi A3 iOS 16 root (kernel side: patches/laurel/xnu/2771, docs/laurel_sprout/camera.md).
#   sudo scripts/laurel/root-camera.sh MOUNTED_ROOT        (root.sh step 2 calls this; CAMERA=0 skips)
# macOS and Linux. Copies the phone's own stock sensor libraries (Xiaomi/Qualcomm files: never in git) to
#   ROOT/usr/share/firmware/laurel-camera/libmmcamera_laurus_{imx586_qtech,imx586_sunny,imx582_qtech}.so
# from out/laurel/camera/lib/ (scripts/laurel/camera-inventory.sh extracts them from the stock vendor image first).
# The kernel (laurel_cam_sensor.c) reads the init and 1280x720 tables from them at run time. Each file is checked
# here with scripts/laurel/camera-tables.py (the same layout the kernel parser checks); a file that fails is skipped.
# Without the libraries the step is a warning: the root builds, the kernel logs
#   LAUREL CAMERA: rear stream: off: no /usr/share/firmware/laurel-camera/libmmcamera_laurus_imx586_*.so (...)
set -euo pipefail
R=${1:?usage: $0 MOUNTED_ROOT}
REPO=$(cd "$(dirname "$0")/../.." && pwd)
L=$REPO/out/laurel/camera/lib
ts() { date +%H:%M:%S; }
if [ "${CAMERA:-1}" = 0 ]; then echo "$(ts) root-camera: skipped (CAMERA=0)"; exit 0; fi
[ -d "$R/System/Library" ] || { echo "root-camera: $R is not an iOS root" >&2; exit 1; }
D=$R/usr/share/firmware/laurel-camera
n=0
for s in imx586_qtech imx586_sunny imx582_qtech; do
  f=$L/libmmcamera_laurus_$s.so
  [ -s "$f" ] || continue
  if ! python3 -I "$REPO/scripts/laurel/camera-tables.py" "$f" > /dev/null; then
    echo "$(ts) root-camera: WARNING: $f: layout check failed; skipped" >&2
    continue
  fi
  mkdir -p "$D"
  install -m 644 "$f" "$D/"
  [ "$(id -u)" != 0 ] || chown 0:0 "$D/$(basename "$f")"
  n=$((n + 1))
done
if [ "$n" = 0 ]; then
  echo "$(ts) root-camera: WARNING: no sensor library in $L (scripts/laurel/camera-inventory.sh first); camera tables skipped" >&2
  exit 0
fi
echo "$(ts) root-camera: done ($n sensor libraries in /usr/share/firmware/laurel-camera)"
