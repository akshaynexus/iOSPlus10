#!/bin/bash
# The Mi A3 flashlight in the iOS 16 root (kernel side: patches/laurel/xnu/2780, /dev/laureltorch).
#   sudo scripts/laurel/root-flashlight.sh MOUNTED_ROOT      (root.sh step 2 calls this; TORCH=0 skips)
# Installs /System/Library/Audio/Plug-Ins/HAL/LaurelFlashlight.driver (root:wheel, 755/644): the mediaserverd plug-in
# that gives FigFlashlight (Control Center, AVFlashlight) a torch device and starts its server
# (userland/laurel/flashlight/README.md). The kernel publishes the Control Center button (IODeviceTree:/product/camera
# flash) only when this file is in the root, so a root without it has no button. Works on macOS and Linux.
# Needs out/laurel/flashlight/LaurelFlashlight.driver (userland/laurel/flashlight/build.sh; built here if missing).
# A plug-in that cannot be built (no theos toolchain / SDK) is a warning: the root goes on without it.
# Undo: delete the driver (or create /var/db/laurel/flashlight-off on the phone).
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
SRC=$REPO/out/laurel/flashlight/LaurelFlashlight.driver
R=${1:?usage: $0 MOUNTED_ROOT}
if [ "${TORCH:-1}" = 0 ]; then echo "root-flashlight: skipped (TORCH=0): no flashlight button"; exit 0; fi
[ -d "$R/System/Library/xpc" ] || { echo "root-flashlight: $R is not an iOS root" >&2; exit 1; }
if [ ! -f "$SRC/LaurelFlashlight" ]; then
  if [ -n "${SUDO_USER:-}" ]; then b() { sudo -u "$SUDO_USER" "$REPO/userland/laurel/flashlight/build.sh"; }; else b() { "$REPO/userland/laurel/flashlight/build.sh"; }; fi
  if ! b || [ ! -f "$SRC/LaurelFlashlight" ]; then
    echo "root-flashlight: WARNING: LaurelFlashlight.driver could not be built (theos toolchain/SDK: run scripts/laurel/kernel-linux.sh once); flashlight skipped, root unchanged" >&2
    exit 0
  fi
fi
HAL=$R/System/Library/Audio/Plug-Ins/HAL
mkdir -p "$HAL"
rm -rf "${HAL:?}/LaurelFlashlight.driver"
cp -R "$SRC" "$HAL/LaurelFlashlight.driver"
[ "$(id -u)" != 0 ] || chown -R 0:0 "$HAL/LaurelFlashlight.driver"
find "$HAL/LaurelFlashlight.driver" -type d -exec chmod 755 {} +
find "$HAL/LaurelFlashlight.driver" -type f -exec chmod 644 {} +
chmod 755 "$HAL/LaurelFlashlight.driver/LaurelFlashlight"
sum=$( (sha256sum "$HAL/LaurelFlashlight.driver/LaurelFlashlight" 2>/dev/null || shasum -a 256 "$HAL/LaurelFlashlight.driver/LaurelFlashlight") | cut -c1-16)
echo "root-flashlight: /System/Library/Audio/Plug-Ins/HAL/LaurelFlashlight.driver installed ($sum...)"
