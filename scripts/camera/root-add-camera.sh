#!/bin/sh
# The camera for the stock Camera.app on a mounted, writable iOS 16 root (userland/camera/README.md). Off unless
# CAMERA=1 (scripts/ios16/root-finish.sh sets CAMERA=1 by default when out/camera/ios/NegroniCamera.driver is
# built: the same rule as ADT_CAM=1 in scripts/ios16/build.sh, so the Camera icon and the plug-in ship together).
# Run as root (macOS or Linux):
#   CAMERA=1 scripts/camera/root-add-camera.sh MOUNTED_ROOT
# Needs out/camera/ios/NegroniCamera.driver from userland/camera/build.sh (macOS).
# Steps (idempotent):
#  1. /System/Library/Audio/Plug-Ins/HAL/NegroniCamera.driver (root:wheel, 755/644): mediaserverd's HAL loads it,
#     its constructor installs the capture hooks (media_hooks.c)
#  2. /var/db/negronicam (empty; a file "turned" there turns the picture half round, read at each stream start)
#  3. remove the MobileGestalt cache: it may hold still-camera = false from a boot without the ADT node
#     /arm-io/isp; MobileGestalt makes it again at the next boot (from the device tree [I])
#  4. the stamp out/camera/root-has-camera (sha256 of the installed NegroniCamera + date + root path):
#     scripts/ios16/build.sh sets ADT_CAM=1 by default when this stamp exists (any sha; a newer local build gives a
#     note), so the Camera icon comes only with an image whose root got the plug-in
# The kernel side is the boot-arg negronicam=7 (patch 0318, /dev/negronicam). Without it the plug-in gives the
# capture stack a vendor whose device is refused at once (Camera.app: no camera), not a hang.
# Undo: CAMERA=0 does nothing; remove System/Library/Audio/Plug-Ins/HAL/NegroniCamera.driver and clear the cache.
set -eu
R=${1:?usage: CAMERA=1 $0 MOUNTED_ROOT}
if [ "${CAMERA:-0}" != 1 ]; then echo "camera: skipped (CAMERA=1 adds NegroniCamera.driver + clears the MobileGestalt cache)"; exit 0; fi
REPO=$(cd "$(dirname "$0")/../.." && pwd)
SRC=$REPO/out/camera/ios/NegroniCamera.driver
[ -d "$R/System/Library/xpc" ] || { echo "$R is not an iOS root" >&2; exit 1; }
[ -f "$SRC/NegroniCamera" ] || { echo "missing $SRC: run userland/camera/build.sh (macOS)" >&2; exit 1; }
grep -q '/dev/negronicam' "$SRC/NegroniCamera" || { echo "$SRC has no /dev/negronicam path: rebuild it" >&2; exit 1; }
[ "$(id -u)" = 0 ] || echo "warning: not root; owners stay as they are (test runs only)" >&2
own() { [ "$(id -u)" != 0 ] || chown -R 0:0 "$@"; }

# 1. the plug-in
HAL=$R/System/Library/Audio/Plug-Ins/HAL
mkdir -p "$HAL"
rm -rf "${HAL:?}/NegroniCamera.driver"
cp -R "$SRC" "$HAL/NegroniCamera.driver"
find "$HAL/NegroniCamera.driver" -name '._*' -delete
own "$HAL/NegroniCamera.driver"
find "$HAL/NegroniCamera.driver" -type d -exec chmod 755 {} +
find "$HAL/NegroniCamera.driver" -type f -exec chmod 644 {} +
chmod 755 "$HAL/NegroniCamera.driver/NegroniCamera"
echo "camera: $HAL/NegroniCamera.driver installed"
if [ -d "$HAL/BTAudioHALPlugin.driver" ]; then
  echo "camera: WARNING: BTAudioHALPlugin.driver is in HAL: it trapped mediaserverd before (docs/notes.md, audio);" >&2
  echo "        AUDIO=1 (scripts/audio/root-add-audio.sh) moves it to HAL.disabled" >&2
fi

# 2. the knob folder
mkdir -p "$R/private/var/db/negronicam"
own "$R/private/var/db/negronicam"
chmod 755 "$R/private/var/db/negronicam"

# 3. the MobileGestalt cache (both places libMobileGestalt 20H392 names)
for c in private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist \
         private/var/mobile/Library/Caches/com.apple.MobileGestalt.plist; do
  if [ -f "$R/$c" ]; then rm -f "$R/$c"; echo "camera: removed /$c (rebuilt at the next boot)"; fi
done
# 4. the stamp for scripts/ios16/build.sh (ADT_CAM default)
sha=$(shasum -a 256 "$HAL/NegroniCamera.driver/NegroniCamera" | cut -d' ' -f1)
printf '%s %s %s\n' "$sha" "$(date '+%Y-%m-%dT%H:%M:%S')" "$R" > "$REPO/out/camera/root-has-camera"
[ -z "${SUDO_UID:-}" ] || chown "$SUDO_UID:${SUDO_GID:-0}" "$REPO/out/camera/root-has-camera" 2>/dev/null || true
echo "camera: stamp out/camera/root-has-camera ($sha)"
echo "camera: done; boot an image with the ADT camera nodes (ADT_CAM=1) and negronicam=7"
