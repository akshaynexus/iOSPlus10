#!/bin/sh
# Add the Metal path to the mounted Mi A3 iOS 16 root (scripts/laurel/root.sh calls it; on by default, METAL=0 skips):
#   /System/Library/Extensions/NegroniMetal.bundle/{NegroniMetal,Info.plist,libvulkan_freedreno.dylib,clients}
#   /usr/local/bin/{vkprobe,metalprobe,mslprobe,m2vtest,carenderprobe,layerprobe,metallib-sweep.sh}
#   /private/var/db/negronimetal/{clients,env,cache/,strikes/,metal.log}
# Input: out/metal/stage from scripts/laurel/metal-build.sh (Turnip for the A610 + metal2vulkan bridge + plug-in).
# The kernel (patch 2850) names the bundle on IOAcceleratorES only when these files are in the root and the A610 runs;
# without them it logs "LAUREL METAL: off: ... missing" and CoreAnimation keeps its current renderer.
#   sudo METAL=1 scripts/laurel/root-add-metal.sh MOUNTED_ROOT
#   METAL_CLIENTS="backboardd SpringBoard"   processes added to /var/db/negronimetal/clients (default "*" = every one)
#   METAL_ENV="TU_DEBUG=sysmem"              lines added to /var/db/negronimetal/env (Turnip/metal2vulkan settings)
# Design and the A610 facts: docs/laurel_sprout/metal.md.
set -eu
R=${1:?usage: $0 MOUNTED_ROOT}
REPO=$(cd "$(dirname "$0")/../.." && pwd)
S=$REPO/out/metal/stage
B=$S/System/Library/Extensions/NegroniMetal.bundle
if [ "${METAL:-1}" = 0 ]; then
  echo "laurel-root: metal: off: METAL=0"; exit 0
fi
for f in "$B/NegroniMetal" "$B/libvulkan_freedreno.dylib" "$B/Info.plist"; do
  if [ ! -f "$f" ]; then
    echo "laurel-root: metal: off: no ${f#$REPO/} (scripts/laurel/metal-build.sh)"; exit 0
  fi
done
METAL=1 PLUGIN_NAME=NegroniMetal "$REPO/scripts/metal/root-add-metal.sh" "$R"
D=$R/private/var/db/negronimetal
if [ -n "${METAL_ENV:-}" ]; then
  printf '%s\n' "$METAL_ENV" >> "$D/env"
fi
# what was built, for the log on the phone side (metal.log names no build)
{
  echo "# laurel_sprout Metal stage, $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  (cd "$S" && find . -type f -perm -u+x ! -name '*.sh' | sort | while read -r f; do
     printf '%s %s\n' "$(sha256sum "$f" | cut -c1-16)" "${f#.}"; done)
} > "$D/build.txt"
chmod 644 "$D/build.txt"
echo "laurel-root: metal: on: NegroniMetal.bundle (Turnip a610 + metal2vulkan), $(grep -c / "$D/build.txt") binaries"
