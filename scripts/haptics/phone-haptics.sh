#!/bin/sh
# UI haptics on the running phone over SSH (docs/haptics-plan.md section 8). It does on the live
# root what scripts/haptics/root-add-haptics.sh does on a mounted root image.
#   scripts/haptics/phone-haptics.sh push     scripts/audio/phone-audio.sh push (NegroniAudio.driver
#                                             with the Actuator -> /dev/negroni-haptic path,
#                                             VirtualAudio back, BTAudioHALPlugin off, mediaserverd
#                                             restarted), then remove the MobileGestalt cache.
#                                             Reboot after it with the hap2 image (boot-args
#                                             negronihap=1 negronihap_ui=1): MobileGestalt reads
#                                             /product/haptics closed-loop again at that boot.
#   scripts/haptics/phone-haptics.sh status   /dev/negroni-haptic, the MobileGestalt cache, mediaserverd
#   scripts/haptics/phone-haptics.sh revert   remove the MobileGestalt cache only (boot an image
#                                             without negronihap_ui=1 next: the legacy "vibrator" path);
#                                             scripts/audio/phone-audio.sh revert removes the plug-in
# Needs: userland/audio/build.sh output, scripts/net/ssh-phone.sh (rootrw=1 root).
set -eu
REPO=$(cd "$(dirname "$0")/../.." && pwd)
SSH=$REPO/scripts/net/ssh-phone.sh
SRC=$REPO/out/audio/ios/NegroniAudio.driver/NegroniAudio
MG1=/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist
MG2=/private/var/mobile/Library/Caches/com.apple.MobileGestalt.plist
ph() { "$SSH" "$*"; }

case "${1:-}" in
push)
  [ -f "$SRC" ] || { echo "missing $SRC: run userland/audio/build.sh" >&2; exit 1; }
  grep -q 'negroni-haptic' "$SRC" || { echo "$SRC has no haptic path: rebuild it (userland/audio/build.sh)" >&2; exit 1; }
  sh "$REPO/scripts/audio/phone-audio.sh" push
  ph "rm -f $MG1 $MG2 && echo 'MobileGestalt cache removed: reboot with negronihap=1 negronihap_ui=1'" ;;
status)
  ph "ls -l /dev/negroni-haptic 2>&1; ls -l $MG1 $MG2 2>&1; ps ax | grep '[m]ediaserverd'" ;;
revert)
  ph "rm -f $MG1 $MG2 && echo 'MobileGestalt cache removed: reboot with an image without negronihap_ui=1'" ;;
*) echo "usage: $0 push|status|revert" >&2; exit 2 ;;
esac
