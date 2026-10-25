#!/bin/sh
# Add the NegroniAudio HAL plug-in (docs/audio-plan.md stage 0) to a mounted, writable iOS 16
# root. Off unless AUDIO=1. Run as root (macOS or Linux), after the slop root tweaks
# (scripts/ios16/root-finish.sh calls it last):
#   AUDIO=1 scripts/audio/root-add-audio.sh MOUNTED_ROOT
# Needs out/audio/ios/NegroniAudio.driver from userland/audio/build.sh (macOS).
# Steps (all idempotent):
#  1. /System/Library/Audio/Plug-Ins/HAL/NegroniAudio.driver (root:wheel, 755/644)
#  2. VirtualAudio.plugin back to /Library/Audio/Plug-Ins/HAL/ if the slop tweaks moved it to
#     HAL.disabled/ (VirtualAudio needs our "Speaker" + "Hawking" devices; without them it
#     crashed in ApplyBeamFormerPreference, slop NOTES)
#  3. StartRecorderServer = false in every MediaToolbox SubServerConfiguration.plist (the
#     portrait prewarm calls a NULL GL function without a GPU)
#  4. checks: the D22 tunings and the UI sounds are in the root
# Undo: AUDIO=0 does nothing; to remove, delete the driver and run the slop tweaks again.
set -eu
R=${1:?usage: AUDIO=1 $0 MOUNTED_ROOT}
if [ "${AUDIO:-0}" != 1 ]; then echo "audio: skipped (AUDIO=1 adds NegroniAudio.driver + VirtualAudio)"; exit 0; fi
REPO=$(cd "$(dirname "$0")/../.." && pwd)
SRC=$REPO/out/audio/ios/NegroniAudio.driver
[ -d "$R/System/Library/xpc" ] || { echo "$R is not an iOS root" >&2; exit 1; }
[ -f "$SRC/NegroniAudio" ] || { echo "missing $SRC: run userland/audio/build.sh (macOS)" >&2; exit 1; }
[ "$(id -u)" = 0 ] || echo "warning: not root; owners stay as they are (test runs only)" >&2
own() { [ "$(id -u)" != 0 ] || chown -R 0:0 "$@"; }

# 1. the plug-in
HAL=$R/System/Library/Audio/Plug-Ins/HAL
mkdir -p "$HAL"
rm -rf "${HAL:?}/NegroniAudio.driver"
cp -R "$SRC" "$HAL/NegroniAudio.driver"
own "$HAL/NegroniAudio.driver"
find "$HAL/NegroniAudio.driver" -type d -exec chmod 755 {} +
find "$HAL/NegroniAudio.driver" -type f -exec chmod 644 {} +
chmod 755 "$HAL/NegroniAudio.driver/NegroniAudio"
echo "audio: $HAL/NegroniAudio.driver installed"

# 2. VirtualAudio back
VA=$R/Library/Audio/Plug-Ins/HAL/VirtualAudio.plugin
OFF=$R/Library/Audio/Plug-Ins/HAL.disabled/VirtualAudio.plugin
if [ -d "$OFF" ] && [ ! -e "$VA" ]; then
  mkdir -p "$(dirname "$VA")"
  mv "$OFF" "$VA"
  rmdir "$R/Library/Audio/Plug-Ins/HAL.disabled" 2>/dev/null || true
  echo "audio: VirtualAudio.plugin restored to /Library/Audio/Plug-Ins/HAL"
elif [ -d "$VA" ]; then
  echo "audio: VirtualAudio.plugin is in place"
else
  echo "audio: WARNING: no VirtualAudio.plugin in the root (no speaker route without it)" >&2
fi

# 3. StartRecorderServer off (slop does this too; check it)
python3 -I - "$R" <<'EOF'
import glob, os, plistlib, sys
root = sys.argv[1]
n = 0
for conf in glob.glob(os.path.join(root, 'System/Library/Frameworks/MediaToolbox.framework/*/SubServerConfiguration.plist')):
    st = os.stat(conf)
    with open(conf, 'rb') as f:
        raw = f.read()
    data = plistlib.loads(raw)
    if data.get('StartRecorderServer') is False:
        continue
    data['StartRecorderServer'] = False
    fmt = plistlib.FMT_BINARY if raw.startswith(b'bplist') else plistlib.FMT_XML
    tmp = conf + '.new'
    with open(tmp, 'wb') as f:
        plistlib.dump(data, f, fmt=fmt)
    os.chmod(tmp, st.st_mode & 0o7777)
    if os.geteuid() == 0:
        os.chown(tmp, st.st_uid, st.st_gid)
    os.replace(tmp, conf)
    n += 1
    print('audio: StartRecorderServer off in', os.path.relpath(conf, root))
print('audio: StartRecorderServer: %d file(s) changed' % n)
EOF

# 4. checks
for d in Library/Audio/Tunings/D22 System/Library/Audio/UISounds; do
  [ -d "$R/$d" ] && echo "audio: /$d present" || echo "audio: WARNING: /$d missing" >&2
done
