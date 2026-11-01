#!/bin/bash
# Mi A3 (laurel_sprout) camera inventory from the stock vendor image (no phone needed).
#   scripts/bg.sh cam-inv scripts/laurel/camera-inventory.sh
#   VENDOR=path   vendor image: Android sparse or raw ext4, or a directory with the files
#                 (default ~/laurel-backup/stock/images/vendor.img, V12.0.26.0.RFQMIXM)
# Output (git-ignored, Xiaomi/Qualcomm files never go into git): out/laurel/camera/
#   lib/libmmcamera_laurus_*.so  the sensor driver libraries (mm-camera2, 32-bit ARM)
#   etc/camera_config.xml        the module table (sensor + CSI/CCI per camera id)
#   sensors.txt                  scripts/laurel/camera-sensors.py: name, slave address, chip ID register/value,
#                                power sequence, CSI lanes, modes per library
# docs/laurel_sprout/camera.md cites sensors.txt for the chip IDs the kernel patch 2770 checks.
set -euo pipefail
. "$(dirname "$0")/../lib/env.sh"
VENDOR=${VENDOR:-$HOME/laurel-backup/stock/images/vendor.img}
D=$OUT/laurel/camera
die() { echo "camera-inventory: $*" >&2; exit 1; }
[ -e "$VENDOR" ] || die "no vendor image $VENDOR (set VENDOR=)"
mkdir -p "$D/lib" "$D/etc"

if [ -d "$VENDOR" ]; then
  cp "$VENDOR"/libmmcamera_laurus_*.so "$D/lib/" 2>/dev/null || true
  cp "$VENDOR"/libactuator_dw9800.so "$VENDOR"/libactuator_laurus_dw9800w_qtech.so "$VENDOR"/libchromatix_laurus_imx586_*_common.so \
    "$VENDOR"/libchromatix_laurus_imx586_*_default_preview*.so "$D/lib/" 2>/dev/null || true
  cp "$VENDOR"/camera_config.xml "$D/etc/" 2>/dev/null || true
else
  command -v debugfs >/dev/null || die "missing debugfs (e2fsprogs)"
  raw=$VENDOR
  if file -b "$VENDOR" | grep -q 'Android sparse'; then
    command -v simg2img >/dev/null || die "missing simg2img (android-tools)"
    raw=$D/vendor.raw.img
    if [ ! -s "$raw" ] || [ "$raw" -ot "$VENDOR" ]; then
      echo "camera-inventory: simg2img $(basename "$VENDOR") ($(du -h "$VENDOR" | cut -f1))"
      simg2img "$VENDOR" "$raw"
    fi
  fi
  # laurel 2773: + the rear lens motor's libraries and the rear modules' tuning (scripts/laurel/camera-tuning.py)
  names=$(debugfs -R "ls -p /lib" "$raw" 2>/dev/null | awk -F/ '{print $6}' | grep -E '^(libmmcamera_laurus_.*|libactuator_dw9800|libactuator_laurus_dw9800w_qtech|libchromatix_laurus_imx586_(sunny|qtech)_(common|default_preview|default_preview_dw9800w))\.so$' || true)
  [ -n "$names" ] || die "no /lib/libmmcamera_laurus_*.so in $VENDOR"
  for n in $names; do debugfs -R "dump /lib/$n $D/lib/$n" "$raw" >/dev/null 2>&1; done
  debugfs -R "dump /etc/camera/camera_config.xml $D/etc/camera_config.xml" "$raw" >/dev/null 2>&1 || true
  rm -f "$D/vendor.raw.img"            # 1 GiB: not kept (clean-builds rule)
fi
ls "$D"/lib/libmmcamera_laurus_*.so >/dev/null 2>&1 || die "no sensor libraries extracted"
python3 -I "$REPO/scripts/laurel/camera-sensors.py" "$D"/lib/libmmcamera_laurus_*.so > "$D/sensors.txt"
cat "$D/sensors.txt"
[ -s "$D/etc/camera_config.xml" ] && grep -E '<(CameraId|SensorName|CCIMaster|CSIInfo|CSIDCore|LensInfo|Position|MountAngle)' "$D/etc/camera_config.xml" | head -80 || true
echo "camera-inventory: $D"
