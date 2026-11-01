#!/bin/bash
# The Mi A3 flashlight in the iOS 16 root (kernel side: patches/laurel/xnu/2781 + 2783, /dev/laureltorch).
#   sudo scripts/laurel/root-flashlight.sh MOUNTED_ROOT      (root.sh step 2 calls this, after root-camera.sh)
# One owner of the iOS side (both plug-ins replace the same method; the second one to load turns itself off):
#   NegroniCamera.driver in the root (the default): it owns the flashlight (userland/camera/camera_device.c torch_set);
#     a LaurelFlashlight.driver from an older root is removed.
#   no NegroniCamera.driver (CAMERA=0, or its build failed): installs /System/Library/Audio/Plug-Ins/HAL/LaurelFlashlight.driver
#     (root:wheel, 755/644; userland/laurel/flashlight/README.md).
#   TORCH=0: neither is used for the torch: writes the mark HAL/laurel-flashlight-off, the kernel then publishes no button.
# The kernel publishes the Control Center button (IODeviceTree:/product/camera flash) only with one of the two in the root.
# Works on macOS and Linux. Needs out/laurel/flashlight/LaurelFlashlight.driver for the second case (built here if missing;
# a plug-in that cannot be built (no theos toolchain / SDK) is a warning: the root goes on without it).
# Undo on the phone: /var/db/laurel/flashlight-off stops LaurelFlashlight; the boot-arg torch=0 stops the kernel side.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
SRC=$REPO/out/laurel/flashlight/LaurelFlashlight.driver
R=${1:?usage: $0 MOUNTED_ROOT}
[ -d "$R/System/Library/xpc" ] || { echo "root-flashlight: $R is not an iOS root" >&2; exit 1; }
HAL=$R/System/Library/Audio/Plug-Ins/HAL
mkdir -p "$HAL"
rm -f "$HAL/laurel-flashlight-off"
if [ "${TORCH:-1}" = 0 ]; then
  rm -rf "${HAL:?}/LaurelFlashlight.driver"
  : > "$HAL/laurel-flashlight-off"
  echo "root-flashlight: TORCH=0: no flashlight button (mark HAL/laurel-flashlight-off)"
  exit 0
fi
if [ -f "$HAL/NegroniCamera.driver/NegroniCamera" ]; then
  rm -rf "${HAL:?}/LaurelFlashlight.driver"
  echo "root-flashlight: NegroniCamera.driver is in the root: it owns the flashlight; no LaurelFlashlight.driver"
  exit 0
fi
if [ ! -f "$SRC/LaurelFlashlight" ]; then
  if [ -n "${SUDO_USER:-}" ]; then b() { sudo -u "$SUDO_USER" "$REPO/userland/laurel/flashlight/build.sh"; }; else b() { "$REPO/userland/laurel/flashlight/build.sh"; }; fi
  if ! b || [ ! -f "$SRC/LaurelFlashlight" ]; then
    echo "root-flashlight: WARNING: LaurelFlashlight.driver could not be built (theos toolchain/SDK: run scripts/laurel/kernel-linux.sh once); flashlight skipped, root unchanged" >&2
    exit 0
  fi
fi
rm -rf "${HAL:?}/LaurelFlashlight.driver"
cp -R "$SRC" "$HAL/LaurelFlashlight.driver"
[ "$(id -u)" != 0 ] || chown -R 0:0 "$HAL/LaurelFlashlight.driver"
find "$HAL/LaurelFlashlight.driver" -type d -exec chmod 755 {} +
find "$HAL/LaurelFlashlight.driver" -type f -exec chmod 644 {} +
chmod 755 "$HAL/LaurelFlashlight.driver/LaurelFlashlight"
sum=$( (sha256sum "$HAL/LaurelFlashlight.driver/LaurelFlashlight" 2>/dev/null || shasum -a 256 "$HAL/LaurelFlashlight.driver/LaurelFlashlight") | cut -c1-16)
echo "root-flashlight: /System/Library/Audio/Plug-Ins/HAL/LaurelFlashlight.driver installed ($sum...)"
