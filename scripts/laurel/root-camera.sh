#!/bin/bash
# Rear camera in the Mi A3 iOS 16 root (kernel: patches/laurel/xnu/2771 + 2772; docs/laurel_sprout/camera.md section 9).
#   sudo scripts/laurel/root-camera.sh MOUNTED_ROOT        (root.sh step 2 calls this; CAMERA=0 skips)
# macOS and Linux. Steps (idempotent; each step that cannot run is a warning: the root builds, only the camera stays off):
#  1. the phone's own stock sensor libraries (Xiaomi/Qualcomm files: never in git) to
#     ROOT/usr/share/firmware/laurel-camera/libmmcamera_laurus_{imx586_qtech,imx586_sunny,imx582_qtech}.so from out/laurel/camera/lib/
#     (scripts/laurel/camera-inventory.sh extracts them from the stock vendor image first). The kernel (laurel_cam_sensor.c)
#     reads the init and 1280x720 tables from them at run time. Each file is checked here with scripts/laurel/camera-tables.py
#     (the same layout the kernel parser checks); a file that fails is skipped. Without the libraries the kernel logs
#     LAUREL CAMERA: rear stream: off: no /usr/share/firmware/laurel-camera/libmmcamera_laurus_imx586_*.so (...)
#  2. NegroniCamera.driver (out/laurel/camera/ios, userland/laurel/camera/build.sh; built here if missing) to the audio HAL folder:
#     mediaserverd loads it; its constructor replaces the capture stack's device vendor (20H392 hooks) and starts the capture
#     servers without the Metal shader preload. Ad hoc signed, no entitlements: mediaserverd has its own, and the kernel's AMFI
#     stand-in treats a signed file on the root as platform code. StartRecorderServer stays false in SubServerConfiguration.plist
#     (audio without the plug-in keeps the old safe state). iOS 16 has no cameracaptured: the servers run in mediaserverd.
#  3. /var/db/negronicam (empty; files there: "off" no hooks, "noservers" no capture servers, "turned" picture half round)
#  4. the MobileGestalt cache out: it may hold still-camera = false from a boot without the ADT node /arm-io/isp (it is made again
#     at the next boot). The ADT nodes come from scripts/laurel/mkadt.py (boot image).
# Undo: CAMERA=0 root, or remove System/Library/Audio/Plug-Ins/HAL/NegroniCamera.driver.
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
else
  echo "$(ts) root-camera: $n sensor libraries in /usr/share/firmware/laurel-camera"
fi

# 2. the plug-in
SRC=$REPO/out/laurel/camera/ios/NegroniCamera.driver
if [ ! -f "$SRC/NegroniCamera" ]; then
  if [ -n "${SUDO_USER:-}" ]; then b() { sudo -u "$SUDO_USER" "$REPO/userland/laurel/camera/build.sh"; }; else b() { "$REPO/userland/laurel/camera/build.sh"; }; fi
  if ! b || [ ! -f "$SRC/NegroniCamera" ]; then
    echo "$(ts) root-camera: WARNING: NegroniCamera.driver could not be built (theos toolchain/SDK: run scripts/laurel/kernel-linux.sh once); no iOS camera in this root" >&2
    exit 0
  fi
fi
own() { [ "$(id -u)" != 0 ] || chown -R 0:0 "$@"; }
HAL=$R/System/Library/Audio/Plug-Ins/HAL
mkdir -p "$HAL"
rm -rf "${HAL:?}/NegroniCamera.driver"
cp -R "$SRC" "$HAL/NegroniCamera.driver"
own "$HAL/NegroniCamera.driver"
find "$HAL/NegroniCamera.driver" -type d -exec chmod 755 {} +
find "$HAL/NegroniCamera.driver" -type f -exec chmod 644 {} +
chmod 755 "$HAL/NegroniCamera.driver/NegroniCamera"
sha=$( { sha256sum "$HAL/NegroniCamera.driver/NegroniCamera" 2>/dev/null || shasum -a 256 "$HAL/NegroniCamera.driver/NegroniCamera"; } | cut -c1-16)
echo "$(ts) root-camera: /System/Library/Audio/Plug-Ins/HAL/NegroniCamera.driver installed ($sha...)"
# the capture servers are in mediaserverd's launchd job: the plug-in cannot start them without these names
P=$R/System/Library/LaunchDaemons/com.apple.mediaserverd.plist
if [ -f "$P" ]; then
  python3 -I - "$P" <<'PY' || echo "$(ts) root-camera: WARNING: mediaserverd's job has no capture services: Camera.app will wait at launch" >&2
import plistlib, sys
d = plistlib.load(open(sys.argv[1], 'rb')).get('MachServices', {})
sys.exit(0 if 'com.apple.coremedia.capturesource' in d and 'com.apple.coremedia.capturesession' in d else 1)
PY
fi

# 3. the knob folder
mkdir -p "$R/private/var/db/negronicam"
own "$R/private/var/db/negronicam"
chmod 755 "$R/private/var/db/negronicam"

# 4. the MobileGestalt cache (both places libMobileGestalt 20H392 names)
for c in private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist \
         private/var/mobile/Library/Caches/com.apple.MobileGestalt.plist; do
  if [ -f "$R/$c" ]; then rm -f "$R/$c"; echo "$(ts) root-camera: removed /$c (made again at the next boot)"; fi
done
echo "$(ts) root-camera: done"
