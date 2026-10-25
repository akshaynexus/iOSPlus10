#!/bin/bash
# Last steps of the iOS 16 root, shared by root-macos.sh and root-linux.sh. Run as root on the
# mounted, writable HFS+ root:
#   scripts/ios16/root-finish.sh MOUNTED_ROOT
# 1. bring-up changes: external/slop/tools/sweet-root-tweaks.py (launchd, Setup skipped,
#    activation, containers, migration marker, MediaToolbox, SpringBoard watchdogs)
# 2. removable Apple apps from /private/var/staged_system_apps into /Applications
#    (as external/slop/negroni-ios/tools/install-staged-apps.sh)
# 1b. our changes: scripts/ios16/root-tweaks-extra.py (MIGRATION=skip|once)
# 1c. Bold Text off: scripts/ios16/root-tweaks-boldtext.py (Bold Text on = SpringBoard crash loop
#     in CoreImage's GL backend, docs/boldtext-crash.md)
# 1d. SSH over USB + ue0 network service: scripts/net/root-add-ssh.sh (SSH=1; default on when
#     out/ssh/ios is built, SSH=0 to leave it out)
# 1e. audio HAL plug-in + VirtualAudio back: scripts/audio/root-add-audio.sh (AUDIO=1; default off)
# 1f. OpenGL ES driver plugin NegroniGL.bundle: scripts/gpu/root-add-negronigl.sh (NEGRONIGL=1; default off)
# 3. remove host metadata folders (macOS creates .fseventsd/.Spotlight-V100 on mount)
set -euo pipefail
R=$1
REPO=$(cd "$(dirname "$0")/../.." && pwd)
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
[ -d "$R/System/Library/xpc" ] || { echo "$R is not an iOS root" >&2; exit 1; }

python3 "$REPO/external/slop/tools/sweet-root-tweaks.py" "$R"
python3 "$REPO/scripts/ios16/root-tweaks-extra.py" "$R" --migration "${MIGRATION:-skip}"   # our changes (jobs, feature flag)
python3 "$REPO/scripts/ios16/root-tweaks-boldtext.py" "$R"                    # Bold Text off (docs/boldtext-crash.md)
if [ -z "${SSH:-}" ] && [ -x "$REPO/out/ssh/ios/dropbearmulti" ]; then SSH=1; fi
SSH=${SSH:-0} sh "$REPO/scripts/net/root-add-ssh.sh" "$R"
AUDIO=${AUDIO:-0} sh "$REPO/scripts/audio/root-add-audio.sh" "$R"   # docs/audio-plan.md stage 0
NEGRONIGL=${NEGRONIGL:-0} sh "$REPO/scripts/gpu/root-add-negronigl.sh" "$R"   # GL driver plugin (docs/gpu-userland.md)

n=0
for app in "$R"/private/var/staged_system_apps/*.app; do
  [ -d "$app" ] || continue
  name=$(basename "$app")
  rm -rf "$R/Applications/$name" "$R/System/Library/AppPlaceholders/$name"
  mv "$app" "$R/Applications/$name"; n=$((n + 1))
done
echo "moved $n staged apps; /Applications has $(ls "$R/Applications" | grep -c '\.app$') apps"

rm -rf "$R/.fseventsd" "$R/.Spotlight-V100" "$R/.Trashes" "$R/.metadata_never_index" "$R/.TemporaryItems"
df -h "$R" | tail -1
