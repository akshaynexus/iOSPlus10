#!/bin/sh
# Stage 0 audio test on the running phone over SSH (docs/audio-plan.md, stage 0). It does on the live
# root what scripts/audio/root-add-audio.sh does on a mounted root image, then restarts mediaserverd.
#   scripts/audio/phone-audio.sh push      install out/audio/ios/NegroniAudio.driver into
#                                          /System/Library/Audio/Plug-Ins/HAL, move VirtualAudio.plugin
#                                          from /Library/Audio/Plug-Ins/HAL.disabled back to HAL,
#                                          then restart mediaserverd (kill; launchd restarts it)
#   scripts/audio/phone-audio.sh status    mediaserverd pid + start time, the plug-in dirs
#   scripts/audio/phone-audio.sh revert    remove the driver, VirtualAudio back to HAL.disabled,
#                                          restart mediaserverd (the state of the slop root tweaks)
# The root is mounted writable (rootrw=1). The phone has no killall/launchctl: kill by pid.
# Needs: userland/audio/build.sh output (out/audio/ios/NegroniAudio.driver), scripts/net/ssh-phone.sh.
set -eu
REPO=$(cd "$(dirname "$0")/../.." && pwd)
SSH=$REPO/scripts/net/ssh-phone.sh
SRC=$REPO/out/audio/ios/NegroniAudio.driver
HAL=/System/Library/Audio/Plug-Ins/HAL
VA=/Library/Audio/Plug-Ins/HAL/VirtualAudio.plugin
OFF=/Library/Audio/Plug-Ins/HAL.disabled/VirtualAudio.plugin
ph() { "$SSH" "$*"; }

restart_ms() {
  pid=$(ph 'ps ax | grep "[m]ediaserverd" | sed -E "s/^ *([0-9]+).*/\\1/"' || true)   # the phone has no awk
  echo "mediaserverd pid before: ${pid:-none}"
  [ -z "$pid" ] || ph "kill -9 $pid" || true
  sleep 4
  ph 'ps ax | grep "[m]ediaserverd" || echo "mediaserverd NOT running"'
}

case "${1:-}" in
push)
  [ -f "$SRC/NegroniAudio" ] || { echo "missing $SRC: run userland/audio/build.sh" >&2; exit 1; }
  # COPYFILE_DISABLE=1: no AppleDouble ._ files from macOS tar
  (cd "$(dirname "$SRC")" && COPYFILE_DISABLE=1 tar cf - --exclude '._*' NegroniAudio.driver) | "$SSH" "rm -rf $HAL/NegroniAudio.driver && cd $HAL && tar xf - && chown -R 0:0 NegroniAudio.driver && chmod -R u=rwX,go=rX NegroniAudio.driver"
  ph "ls -la $HAL/NegroniAudio.driver"
  ph "if [ -d $OFF ] && [ ! -e $VA ]; then mkdir -p $(dirname $VA) && mv $OFF $VA && echo 'VirtualAudio restored'; else echo 'VirtualAudio: already in place or missing'; fi; ls /Library/Audio/Plug-Ins/HAL"
  restart_ms ;;
status)
  ph "ps ax -o pid,start,time,command | grep '[m]ediaserverd'; ls $HAL /Library/Audio/Plug-Ins/HAL /Library/Audio/Plug-Ins/HAL.disabled 2>&1" ;;
revert)
  ph "rm -rf $HAL/NegroniAudio.driver; if [ -d $VA ]; then mkdir -p $(dirname $OFF) && mv $VA $OFF && echo 'VirtualAudio disabled'; fi; ls /Library/Audio/Plug-Ins/HAL.disabled"
  restart_ms ;;
*) echo "usage: $0 push|status|revert" >&2; exit 2 ;;
esac
