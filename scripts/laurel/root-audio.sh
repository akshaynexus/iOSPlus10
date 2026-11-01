#!/bin/bash
# Speaker audio in the Mi A3 iOS 16 root (kernel side: patches/laurel/xnu/2500, /dev/redwood-audio).
#   sudo scripts/laurel/root-audio.sh MOUNTED_ROOT          (root.sh step 2 calls this; AUDIO=0 skips)
#   sudo scripts/laurel/root-audio.sh --image ROOT.img      (an existing image: mount, install, fsck,
#                                                            new ROOT.simg; run in tmux: scripts/bg.sh)
# --image is Linux only (modprobe, mount -t hfsplus, fsck.hfsplus), as root.sh is. MOUNTED_ROOT mode works on
# macOS and Linux. A plug-in that cannot be built (no theos toolchain / SDK) is a warning: audio is skipped,
# the caller (root.sh) goes on.
# Needs out/laurel/audio/RedwoodAudio.driver (userland/laurel/audio/build.sh; built here if missing).
# Steps (idempotent):
#  1. /System/Library/Audio/Plug-Ins/HAL/RedwoodAudio.driver (root:wheel, 755/644)
#  2. VirtualAudio.plugin back from /Library/Audio/Plug-Ins/HAL.disabled (topaz's sweet-root-tweaks.py
#     moves it there because without our "Speaker" + "Hawking" devices it crashed mediaserverd; with
#     them it is what routes system sounds and ringtones to the speaker port)
#  3. BTAudioHALPlugin.driver to /System/Library/Audio/Plug-Ins/HAL.disabled: its factory's XPC to
#     com.apple.BTAudioHALPlugin.xpc trapped mediaserverd on negroni, where bluetoothd was absent (scripts/audio/root-add-audio.sh).
#     The Mi A3 root has bluetoothd now, which holds that service [V its plist], but no port has run the plug-in with it, and a
#     trap stops all audio and the camera. BTAUDIO=1 keeps the plug-in in HAL: the test in docs/laurel_sprout/system-features.md.
# Undo: delete the driver, move the two plug-ins back.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
SRC=$REPO/out/laurel/audio/RedwoodAudio.driver
ts() { date +%H:%M:%S; }

if [ "${1:-}" = --image ]; then
  IMG=${2:?usage: $0 --image ROOT.img}
  [ "$(uname -s)" = Linux ] || { echo "root-audio: --image needs Linux (hfsplus mount); on macOS mount the image and pass the root" >&2; exit 1; }
  [ "$(id -u)" = 0 ] || { echo "root-audio: run with sudo" >&2; exit 1; }
  [ -s "$IMG" ] || { echo "root-audio: no $IMG" >&2; exit 1; }
  U=${SUDO_USER:-$USER}
  modprobe hfsplus
  mnt=$(mktemp -d)
  trap 'umount "$mnt" 2>/dev/null || true; rmdir "$mnt" 2>/dev/null || true' EXIT
  mount -t hfsplus -o loop,force,rw "$IMG" "$mnt"
  AUDIO=1 "$0" "$mnt"
  sync
  umount "$mnt"
  echo "$(ts) root-audio: fsck"
  fsck.hfsplus -fy "$IMG" | grep -v 'Illegal name' | tail -3 || true
  # verify: no sparse image of a volume that is not clean. The one finding Linux fsck_hfs 540.1 repeats
  # after a repair ("Volume header needs minor repair") is accepted, as in root.sh.
  if ! v=$(fsck.hfsplus -f -n "$IMG" 2>&1); then
    others=$(printf '%s\n' "$v" | grep -E 'needs|invalid|Invalid|incorrect|Incorrect|error|Error|missing|Missing|overlap' |
      grep -v 'Volume header needs minor repair' | grep -v 'needs to be repaired' || true)
    if printf '%s\n' "$v" | grep -q 'Volume header needs minor repair' && [ -z "$others" ]; then
      echo "$(ts) root-audio: note: only 'Volume header needs minor repair' remains (Linux fsck_hfs); accepted"
    else
      echo "root-audio: fsck: the volume is not clean; no sparse image made" >&2
      printf '%s\n' "$v" | tail -8 >&2
      exit 1
    fi
  fi
  OP=$REPO/out/bin/op10tool
  [ -x "$OP" ] || sudo -u "$U" "$REPO/scripts/setup/build-op10tool.sh"
  echo "$(ts) root-audio: sparse image (op10tool img2simg)"
  "$OP" img2simg "$IMG" "$IMG.simg.partial" && mv "$IMG.simg.partial" "${IMG%.img}.simg"
  chown "$U": "$IMG" "${IMG%.img}.simg"
  ls -l "$IMG" "${IMG%.img}.simg"
  exit 0
fi

R=${1:?usage: $0 MOUNTED_ROOT | --image ROOT.img}
if [ "${AUDIO:-1}" = 0 ]; then echo "root-audio: skipped (AUDIO=0)"; exit 0; fi
[ -d "$R/System/Library/xpc" ] || { echo "root-audio: $R is not an iOS root" >&2; exit 1; }
if [ ! -f "$SRC/RedwoodAudio" ]; then
  if [ -n "${SUDO_USER:-}" ]; then b() { sudo -u "$SUDO_USER" "$REPO/userland/laurel/audio/build.sh"; }; else b() { "$REPO/userland/laurel/audio/build.sh"; }; fi
  if ! b || [ ! -f "$SRC/RedwoodAudio" ]; then
    echo "root-audio: WARNING: RedwoodAudio.driver could not be built (theos toolchain/SDK: run scripts/laurel/kernel-linux.sh once); audio skipped, root unchanged" >&2
    exit 0
  fi
fi
own() { [ "$(id -u)" != 0 ] || chown -R 0:0 "$@"; }

# 1. the plug-in
HAL=$R/System/Library/Audio/Plug-Ins/HAL
mkdir -p "$HAL"
rm -rf "${HAL:?}/RedwoodAudio.driver"
cp -R "$SRC" "$HAL/RedwoodAudio.driver"
own "$HAL/RedwoodAudio.driver"
find "$HAL/RedwoodAudio.driver" -type d -exec chmod 755 {} +
find "$HAL/RedwoodAudio.driver" -type f -exec chmod 644 {} +
chmod 755 "$HAL/RedwoodAudio.driver/RedwoodAudio"
echo "root-audio: /System/Library/Audio/Plug-Ins/HAL/RedwoodAudio.driver installed ($(sha256sum "$HAL/RedwoodAudio.driver/RedwoodAudio" | cut -c1-16)...)"

# 2. VirtualAudio back
VA=$R/Library/Audio/Plug-Ins/HAL/VirtualAudio.plugin
OFF=$R/Library/Audio/Plug-Ins/HAL.disabled/VirtualAudio.plugin
if [ -d "$OFF" ] && [ ! -e "$VA" ]; then
  mkdir -p "$(dirname "$VA")"
  mv "$OFF" "$VA"
  rmdir "$R/Library/Audio/Plug-Ins/HAL.disabled" 2>/dev/null || true
  echo "root-audio: VirtualAudio.plugin restored to /Library/Audio/Plug-Ins/HAL"
elif [ -d "$VA" ]; then
  echo "root-audio: VirtualAudio.plugin is in place"
else
  echo "root-audio: WARNING: no VirtualAudio.plugin in the root (no speaker route without it)" >&2
fi

# 3. BTAudioHALPlugin off
BT=$HAL/BTAudioHALPlugin.driver
BTOFF=$R/System/Library/Audio/Plug-Ins/HAL.disabled/BTAudioHALPlugin.driver
if [ "${BTAUDIO:-0}" = 1 ]; then
  if [ -d "$BTOFF" ] && [ ! -e "$BT" ]; then mv "$BTOFF" "$BT"; fi
  echo "root-audio: BTAudioHALPlugin.driver stays in HAL (BTAUDIO=1)"
elif [ -d "$BT" ]; then
  mkdir -p "$(dirname "$BTOFF")"
  rm -rf "$BTOFF"
  mv "$BT" "$BTOFF"
  echo "root-audio: BTAudioHALPlugin.driver moved to /System/Library/Audio/Plug-Ins/HAL.disabled"
else
  echo "root-audio: BTAudioHALPlugin.driver is not in HAL (already disabled or missing)"
fi

# checks: the D22 speaker tunings and the UI sounds (ringtones, system sounds) are in the root
for d in Library/Audio/Tunings/D22 System/Library/Audio/UISounds Library/Ringtones; do
  [ -d "$R/$d" ] && echo "root-audio: /$d present" || echo "root-audio: WARNING: /$d missing" >&2
done
