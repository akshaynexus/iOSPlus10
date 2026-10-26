#!/bin/sh
# The camera plug-in on the running phone over SSH (userland/camera/README.md). It does on the live root what
# scripts/camera/root-add-camera.sh does on a mounted root image.
#   scripts/camera/phone-camera.sh push     install out/camera/ios/NegroniCamera.driver into
#                                           /System/Library/Audio/Plug-Ins/HAL, remove the MobileGestalt cache,
#                                           restart mediaserverd (kill; launchd restarts it). The Camera icon needs
#                                           the ADT nodes (an ADT_CAM=1 image) and a reboot for MobileGestalt.
#   scripts/camera/phone-camera.sh status   /dev/negronicam, the plug-in, the cache, mediaserverd
#   scripts/camera/phone-camera.sh frame    one frame from /dev/negronicam -> out/camera/frame-<date>.raw + .ppm
#                                           (out/camera/host/isp-render); starts a kernel camera session
#   scripts/camera/phone-camera.sh revert   remove the plug-in and the cache, restart mediaserverd
# The root is mounted writable (rootrw=1). The phone has no killall/launchctl: kill by pid.
# Logs: scripts/net/phone-log.sh mediaserverd (lines "negroni: camera")
# Needs: userland/camera/build.sh output, scripts/net/ssh-phone.sh. Never writes a partition.
set -eu
REPO=$(cd "$(dirname "$0")/../.." && pwd)
SSH=$REPO/scripts/net/ssh-phone.sh
SRC=$REPO/out/camera/ios/NegroniCamera.driver
HAL=/System/Library/Audio/Plug-Ins/HAL
MG1=/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist
MG2=/private/var/mobile/Library/Caches/com.apple.MobileGestalt.plist
ph() { "$SSH" "$*"; }

restart_ms() {
  pid=$(ph 'ps ax | grep "[m]ediaserverd" | head -1 | sed -E "s/^ *([0-9]+).*/\\1/"' || true)   # the phone has no awk
  echo "mediaserverd pid before: ${pid:-none}"
  [ -z "$pid" ] || ph "kill -9 $pid" || true
  sleep 4
  ph 'ps ax | grep "[m]ediaserverd" || echo "mediaserverd NOT running"'
}

case "${1:-}" in
push)
  [ -f "$SRC/NegroniCamera" ] || { echo "missing $SRC: run userland/camera/build.sh" >&2; exit 1; }
  "$SSH" true || exit 1
  # COPYFILE_DISABLE=1: no AppleDouble ._ files from macOS tar
  (cd "$(dirname "$SRC")" && COPYFILE_DISABLE=1 tar cf - --exclude '._*' NegroniCamera.driver) | "$SSH" "rm -rf $HAL/NegroniCamera.driver && cd $HAL && tar xf - && chown -R 0:0 NegroniCamera.driver && chmod -R u=rwX,go=rX NegroniCamera.driver"
  ph "mkdir -p /var/db/negronicam; ls -la $HAL/NegroniCamera.driver; rm -f $MG1 $MG2 && echo 'MobileGestalt cache removed (re-read at the next boot)'"
  restart_ms ;;
status)
  ph "ls -l /dev/negronicam 2>&1; ls -la $HAL 2>&1; ls -l $MG1 $MG2 2>&1; ls /var/db/negronicam 2>&1; ps ax -o pid,start,time,command | grep '[m]ediaserverd'" ;;
frame)
  [ -x "$REPO/out/camera/host/isp-render" ] || { echo "missing out/camera/host/isp-render: run userland/camera/build.sh" >&2; exit 1; }
  f=$REPO/out/camera/frame-$(date +%Y%m%d-%H%M%S).raw
  # header 120 + 4000*3008*10/8 bytes (IMX789); the TPG frame is smaller and dd stops at its end
  ph "dd if=/dev/negronicam of=/tmp/negronicam.raw bs=15040120 count=1 2>&1; ls -l /tmp/negronicam.raw"
  "$SSH" pull /tmp/negronicam.raw "$f"
  ph "rm -f /tmp/negronicam.raw"
  for b in 0 1 2 3; do "$REPO/out/camera/host/isp-render" "$f" "${f%.raw}-bayer$b.ppm" "$b"; done ;;
revert)
  ph "rm -rf $HAL/NegroniCamera.driver; rm -f $MG1 $MG2; echo 'NegroniCamera.driver removed, MobileGestalt cache removed'"
  restart_ms ;;
*) echo "usage: $0 push|status|frame|revert" >&2; exit 2 ;;
esac
