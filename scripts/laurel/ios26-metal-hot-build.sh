#!/bin/bash
# Second Metal option for the iOS 26 path: IOS-26-Hot's frontend + bridge + its metal2vulkan series (720ef1ce + 19 patches), on our Turnip (Mesa 25.0.7, msm KMD, RedwoodGPU) and our plug-in. Own tree: out/ios26/metal-hot.
# Why it is a real second option: another metal2vulkan generation (817 commits before our 219f013) with runtime speed patches, and the only stack with a report on 23F84 at speed (A640, 52.9 fps, self-reported).
# Not an A610 port by its authors: its Turnip and kernel ABI (NativeAdreno, tu_knl_darwin) are not used here. Comparison: docs/laurel_sprout/ios26-metal.md section 10.
#   scripts/bg.sh ios26-hot scripts/laurel/ios26-metal-hot-build.sh [fetch|bridge|plugin|check|all]     needs external/IOS-26-Hot (scripts/setup/get-references.sh) and scripts/laurel/ios26-metal-build.sh for Turnip
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
OUTDIR=${OUTDIR:-$REPO/out}
HOT=${HOT:-$REPO/external/IOS-26-Hot}
[ -d "$HOT/phone/metal2" ] || HOT=$(git -C "$REPO" worktree list --porcelain | sed -n '1s/^worktree //p')/external/IOS-26-Hot
[ -d "$HOT/phone/metal2" ] || { echo "ios26-hot: no IOS-26-Hot: scripts/setup/get-references.sh IOS-26-Hot" >&2; exit 1; }
HOT_PIN=d249939b9c36380afaee1a76cf167aeee8347475
M2V_PIN=720ef1ce9ae2a2068999a8675717418b9416283e
export METAL_OUT=$OUTDIR/ios26/metal-hot GPU_OUT=$OUTDIR/ios26/gpu
export METAL_EXPORTS_CACHE=$OUTDIR/ios26/metal-spi/exports
export IOS_DSC=${IOS_DSC:-$HOME/op10-apple/ios26/23F84-n104ap/tree/cache/dyld_shared_cache_arm64e}
export NMTL_EXTRA_FLAGS="-DNMTL_IOS26=1 -DNMTL_HOT=1"
export PLUGIN_CLASS=NegroniMTLDeviceImpl   # the bundle's own class is the selector's: scripts/laurel/ios26-metal-options.sh
mkdir -p "$METAL_OUT"
step_fetch() {
  [ "$(git -C "$HOT" rev-parse HEAD)" = "$HOT_PIN" ] || { echo "ios26-hot: IOS-26-Hot is not at $HOT_PIN" >&2; exit 1; }
  local S=$METAL_OUT/src M=$METAL_OUT/src/metal2vulkan F=$METAL_OUT/src/flame p
  rm -rf "$S"; mkdir -p "$M" "$F/phone"
  git -C "$REPO/external/metal2vulkan" archive "$M2V_PIN" | tar -x -C "$M"
  git -C "$M" init -q; git -C "$M" add -A; git -C "$M" -c user.name=x -c user.email=x@local commit -q -m "metal2vulkan $M2V_PIN"
  for p in "$HOT"/phone/metal2/bridge/patches/*.patch; do
    git -C "$M" apply --whitespace=nowarn "$p" || { echo "$(basename "$p") does not apply" >&2; exit 1; }
  done
  cp -a "$HOT/phone/metal2" "$F/phone/metal2"
  git -C "$F" init -q; git -C "$F" add -A; git -C "$F" -c user.name=x -c user.email=x@local commit -q -m "IOS-26-Hot $HOT_PIN phone/metal2"
  for p in "$REPO"/userland/metal/patches/hot-ios26/*.patch; do
    [ -f "$p" ] || continue
    git -C "$F" apply --whitespace=nowarn "$p" || { echo "$(basename "$p") does not apply" >&2; exit 1; }
    echo "applied $(basename "$p")"
  done
  echo "ios26-hot: metal2vulkan $M2V_PIN + $(ls "$HOT"/phone/metal2/bridge/patches/*.patch | wc -l) patches; frontend IOS-26-Hot $HOT_PIN"
}
case "${1:-all}" in
fetch) step_fetch ;;
bridge|plugin|check) "$HERE/metal-build.sh" "$1" ;;
all)
  step_fetch
  "$HERE/metal-build.sh" bridge
  "$HERE/metal-build.sh" plugin
  "$HERE/metal-build.sh" check
  python3 -I "$REPO/scripts/ios26/abi-check.py" "$METAL_OUT/stage"
  ;;
*) sed -n 2,5p "$0"; exit 1 ;;
esac
