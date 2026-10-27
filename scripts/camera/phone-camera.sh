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
#   scripts/camera/phone-camera.sh restart  kill Camera.app and mediaserverd (launchd restarts mediaserverd; it
#                                           loads the HAL plug-ins again, so a pushed plug-in takes effect)
#   scripts/camera/phone-camera.sh off|on   hot switch: /var/db/negronicam/off makes the plug-in do nothing at the
#                                           next mediaserverd start (built 2026-10-27 05:55 and later); then restart
#   scripts/camera/phone-camera.sh log      live unified log of mediaserverd + Camera, filtered to the camera lines
#   scripts/camera/phone-camera.sh servers on|off
#                                           the capture servers the plug-in starts (StartRecorderServer is false on
#                                           our root): off = /var/db/negronicam/noservers (Camera.app then waits at
#                                           launch, as before 2026-10-27 18:00); then restart. docs/camera-ios-2026-10-27.md 8
# push keeps the plug-in it replaces in /var/db/negronicam/NegroniCamera.driver.prev; "revert prev" puts it back.
# push also writes the stamp out/camera/root-has-camera (the phone's root now has this build), so the next
# scripts/ios16/build.sh adds the camera ADT nodes by default.
# The root is mounted writable (rootrw=1). The phone has no killall/launchctl: kill by pid.
# Logs: scripts/net/phone-log.sh mediaserverd (lines "negroni: camera"); kernel: the USB log, "NEGRONI CAM:"
# cameracaptured does not exist in iOS 16 (the capture servers run in mediaserverd; our root has StartRecorderServer
# false, so the plug-in starts them itself: docs/camera-ios-2026-10-27.md section 8; applecamerad is unused here).
# Needs: userland/camera/build.sh output, scripts/net/ssh-phone.sh. Never writes a partition.
set -eu
REPO=$(cd "$(dirname "$0")/../.." && pwd)
SSH=$REPO/scripts/net/ssh-phone.sh
SRC=$REPO/out/camera/ios/NegroniCamera.driver
HAL=/System/Library/Audio/Plug-Ins/HAL
MG1=/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist
MG2=/private/var/mobile/Library/Caches/com.apple.MobileGestalt.plist
ph() { "$SSH" "$*"; }

kill_camera_app() {
  pid=$(ph 'ps ax | grep "[/]Camera.app/Camera" | head -1 | sed -E "s/^ *([0-9]+).*/\\1/"' || true)
  [ -z "$pid" ] || { echo "Camera.app pid $pid: killed"; ph "kill -9 $pid" || true; }
}

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
  ph "mkdir -p /var/db/negronicam; if [ -d $HAL/NegroniCamera.driver ]; then rm -rf /var/db/negronicam/NegroniCamera.driver.prev && cp -R $HAL/NegroniCamera.driver /var/db/negronicam/NegroniCamera.driver.prev && echo 'old plug-in kept in /var/db/negronicam/NegroniCamera.driver.prev'; fi"
  (cd "$(dirname "$SRC")" && COPYFILE_DISABLE=1 tar cf - --exclude '._*' NegroniCamera.driver) | "$SSH" "rm -rf $HAL/NegroniCamera.driver && cd $HAL && tar xf - && chown -R 0:0 NegroniCamera.driver && chmod -R u=rwX,go=rX NegroniCamera.driver"
  ph "ls -la $HAL/NegroniCamera.driver; rm -f $MG1 $MG2 && echo 'MobileGestalt cache removed (re-read at the next boot)'"
  sha=$(shasum -a 256 "$SRC/NegroniCamera" | cut -d' ' -f1)
  printf '%s %s %s\n' "$sha" "$(date '+%Y-%m-%dT%H:%M:%S')" "phone:live (phone-camera.sh push)" > "$REPO/out/camera/root-has-camera"
  echo "stamp out/camera/root-has-camera ($sha)"
  kill_camera_app
  restart_ms ;;
restart)
  kill_camera_app
  restart_ms ;;
off)
  ph "mkdir -p /var/db/negronicam && touch /var/db/negronicam/off && echo 'camera plug-in off at the next mediaserverd start'"
  kill_camera_app
  restart_ms ;;
on)
  ph "rm -f /var/db/negronicam/off && echo 'camera plug-in on at the next mediaserverd start'"
  kill_camera_app
  restart_ms ;;
servers)
  case "${2:-}" in
  on) ph "rm -f /var/db/negronicam/noservers && echo 'capture servers on at the next mediaserverd start'" ;;
  off) ph "mkdir -p /var/db/negronicam && touch /var/db/negronicam/noservers && echo 'capture servers off at the next mediaserverd start'" ;;
  *) echo "usage: $0 servers on|off" >&2; exit 2 ;;
  esac
  kill_camera_app
  restart_ms ;;
log)
  exec "$REPO/scripts/net/phone-log.sh" -g "negroni: camera" mediaserverd Camera ;;
status)
  ph "ls -l /dev/negronicam 2>&1; ls -la $HAL 2>&1; ls -l /var/db/negronicam 2>&1; ls -l $MG1 $MG2 2>&1; ls /var/db/negronicam 2>&1; grep -A1 StartRecorderServer /System/Library/Frameworks/MediaToolbox.framework/D22/SubServerConfiguration.plist 2>&1; ps ax -o pid,start,time,command | grep -E '[m]ediaserverd|[/]Camera.app/Camera'" ;;
frame)
  [ -x "$REPO/out/camera/host/isp-render" ] || { echo "missing out/camera/host/isp-render: run userland/camera/build.sh" >&2; exit 1; }
  f=$REPO/out/camera/frame-$(date +%Y%m%d-%H%M%S).raw
  # header 120 + 4000*3008*10/8 bytes (IMX789); the TPG frame is smaller and dd stops at its end
  ph "dd if=/dev/negronicam of=/tmp/negronicam.raw bs=15040120 count=1 2>&1; ls -l /tmp/negronicam.raw"
  "$SSH" pull /tmp/negronicam.raw "$f"
  ph "rm -f /tmp/negronicam.raw"
  for b in 0 1 2 3; do "$REPO/out/camera/host/isp-render" "$f" "${f%.raw}-bayer$b.ppm" "$b"; done ;;
revert)
  if [ "${2:-}" = prev ]; then
    ph "[ -d /var/db/negronicam/NegroniCamera.driver.prev ] || { echo 'no /var/db/negronicam/NegroniCamera.driver.prev'; exit 1; }; rm -rf $HAL/NegroniCamera.driver && cp -R /var/db/negronicam/NegroniCamera.driver.prev $HAL/NegroniCamera.driver && echo 'the previous plug-in is back'"
  else
    ph "rm -rf $HAL/NegroniCamera.driver; rm -f $MG1 $MG2; echo 'NegroniCamera.driver removed, MobileGestalt cache removed'"
    rm -f "$REPO/out/camera/root-has-camera"   # no plug-in now: the next build.sh adds no camera ADT nodes
    echo "stamp out/camera/root-has-camera removed"
  fi
  kill_camera_app
  restart_ms ;;
*) echo "usage: $0 push|status|frame|restart|off|on|servers on|off|log|revert [prev]" >&2; exit 2 ;;
esac
