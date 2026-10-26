#!/bin/sh
# UI haptics on a mounted, writable iOS 16 root (docs/haptics-plan.md section 8). Off unless
# HAPTICS=1. Run as root (macOS or Linux), after the slop root tweaks (scripts/ios16/root-finish.sh
# calls it after the audio hook):
#   HAPTICS=1 scripts/haptics/root-add-haptics.sh MOUNTED_ROOT
# Needs out/audio/ios/NegroniAudio.driver from userland/audio/build.sh (macOS), a build that has
# the Actuator -> /dev/negroni-haptic path (it has the string "negroni-haptic").
# Steps (idempotent):
#  1. AUDIO=1 scripts/audio/root-add-audio.sh: NegroniAudio.driver (its "Actuator" device feeds
#     the motor), VirtualAudio.plugin back (it makes VirtualAudioDevice_Actuator), BTAudioHALPlugin off
#  2. remove the MobileGestalt cache: it may hold DeviceSupportsClosedLoopHaptics = false from a boot
#     without negronihap_ui=1; MobileGestalt makes it again at the next boot (from the device tree).
# The kernel side is the boot-args negronihap=1 negronihap_ui=1 (patches 0300-0302): without them
# the Actuator samples are dropped and the closed-loop node is absent (the legacy "vibrator" path).
set -eu
R=${1:?usage: HAPTICS=1 $0 MOUNTED_ROOT}
if [ "${HAPTICS:-0}" != 1 ]; then echo "haptics: skipped (HAPTICS=1 adds NegroniAudio.driver + clears the MobileGestalt cache)"; exit 0; fi
REPO=$(cd "$(dirname "$0")/../.." && pwd)
SRC=$REPO/out/audio/ios/NegroniAudio.driver/NegroniAudio
[ -d "$R/System/Library/xpc" ] || { echo "$R is not an iOS root" >&2; exit 1; }
[ -f "$SRC" ] || { echo "missing $SRC: run userland/audio/build.sh (macOS)" >&2; exit 1; }
grep -q 'negroni-haptic' "$SRC" || { echo "$SRC has no Actuator -> /dev/negroni-haptic path: rebuild it (userland/audio/build.sh)" >&2; exit 1; }

# 1. the HAL plug-in + VirtualAudio
AUDIO=1 sh "$REPO/scripts/audio/root-add-audio.sh" "$R"

# 2. the MobileGestalt cache (both places libMobileGestalt 20H392 names)
for c in private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist \
         private/var/mobile/Library/Caches/com.apple.MobileGestalt.plist; do
  if [ -f "$R/$c" ]; then rm -f "$R/$c"; echo "haptics: removed /$c (rebuilt at the next boot)"; fi
done
echo "haptics: done; boot with negronihap=1 negronihap_ui=1 (out/ios16-hap2)"
