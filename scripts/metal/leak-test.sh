#!/bin/bash
# What the Metal layers keep over the frames of CMCapture's filter strip, on this host: userland/metal/tests/mediaserverd-leak.c over the real
# metal2vulkan runtime + bridge (flame + m2v patches) on a real Vulkan driver of this host. Not Turnip, not ir3, not the phone, not CMCapture.
#   scripts/bg.sh mdmetal-leak scripts/metal/leak-test.sh [FRAMES]        (a first bridge build takes minutes)
# Env: ICD=FILE (default: the Intel driver), METALLIB=FILE (default: MetalFilter's from the 20H392 OS image, mounted read-only for the run).
# Output: logs of the job; exit 1 when the frame stage keeps growing or the prewarm's heap refuses. Linux only. Docs: docs/laurel_sprout/metal.md section 12.
set -euo pipefail
. "$(cd "$(dirname "$0")/../laurel" && pwd)/metal-env.sh"
frames=${1:-3000}
export PATH=$HOME/.cargo/bin:$PATH
T=$OUT/metal/leak-test
B=$OUT/metal/bridge/linux/libnative_metal_bridge.a
FLAME_DIR=$OUT/metal/src/flame/phone/metal2/bridge
mkdir -p "$T"
if [ ! -f "$B" ] || [ -n "$(find "$FLAME_DIR" -newer "$B" -name 'NativeMetal*' -print -quit)" ]; then
  BRIDGE_TARGET_DIR=$OUT/metal/bridge-linux-target "$REPO/scripts/metal/build-bridge.sh" linux
fi
clang -O1 -g -Wall -I "$FLAME_DIR" "$REPO/userland/metal/tests/mediaserverd-leak.c" "$B" -lm -ldl -lpthread -o "$T/mediaserverd-leak"
ICD=${ICD:-/usr/share/vulkan/icd.d/intel_icd.json}
[ -f "$ICD" ] || { echo "leak-test: no $ICD: set ICD=" >&2; exit 2; }
M=$T/mnt; lib=${METALLIB:-}
umnt() { mountpoint -q "$M" 2>/dev/null && fusermount3 -u "$M" || true; }
if [ -z "$lib" ] && [ -f "${OS_DMG:-$APPLE/20H392/087-86698-044.dmg}" ] && command -v apfs-fuse > /dev/null; then
  mkdir -p "$M"; umnt
  apfs-fuse -o ro "${OS_DMG:-$APPLE/20H392/087-86698-044.dmg}" "$M" && trap umnt EXIT
  lib=$M/root/System/Library/VideoProcessors/MetalFilter.bundle/default.metallib
fi
rm -rf "$T/cache"
export VK_ICD_FILENAMES=$ICD VK_DRIVER_FILES=$ICD
"$T/mediaserverd-leak" libvulkan.so.1 "$T/cache" "${lib:-}" "$frames"
