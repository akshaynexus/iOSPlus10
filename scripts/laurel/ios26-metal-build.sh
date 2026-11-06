#!/bin/bash
# The Metal stack for the Mi A3 on iOS 26.5.2 23F84 (donor iPhone12,1 N104AP, A13, APPLE6), built on Linux, in its own output tree. iOS 16 builds do not read this script's tree or patches.
# The same steps as scripts/laurel/metal-build.sh (Turnip for FD610, metal2vulkan bridge, NegroniMetal.bundle) with:
#   out/ios26/metal, out/ios26/gpu                     output (METAL_OUT, GPU_OUT)
#   userland/metal/patches/flame-ios26                 frontend + bridge: the 23F84 SPI, last in the series (METAL_EXTRA_FLAME)
#   userland/metal/patches/m2v-ios26                   metal2vulkan: specializedName links a function (METAL_EXTRA_M2V)
#   -DNMTL_IOS26=1                                     plug-in: compositor rules of iOS 26 (userland/metal/plugin/NegroniMetal.mm)
#   IOS_DSC = the 23F84 cache                          the import check reads iOS 26's exports (out/ios26/metal-spi/exports)
# Target stays arm64 (no PAC) -mcpu=cortex-a53, minos 16.0: the same plain ABI as a third-party app on an A13 [I], so no signed pointer is ever made here. See docs/laurel_sprout/ios26-metal.md section 2.
#   scripts/bg.sh ios26-metal scripts/laurel/ios26-metal-build.sh [fetch|turnip|bridge|plugin|check|all]
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
OUTDIR=${OUTDIR:-$REPO/out}
export METAL_OUT=${METAL_OUT:-$OUTDIR/ios26/metal} GPU_OUT=$OUTDIR/ios26/gpu
export METAL_EXTRA_FLAME="$REPO/userland/metal/patches/flame-ios26 $REPO/userland/metal/patches/flame-bbd"
export METAL_EXTRA_M2V="$REPO/userland/metal/patches/m2v-ios26"   # the iOS 16 translator stays as it is
export METAL_EXPORTS_CACHE=$OUTDIR/ios26/metal-spi/exports
export IOS_DSC=${IOS_DSC:-$HOME/op10-apple/ios26/23F84-n104ap/tree/cache/dyld_shared_cache_arm64e}
# a CMake compile flag only (scripts/laurel/metal-env.sh sets NMTL_CPU_FLAGS; ours goes in after it through this variable)
export NMTL_EXTRA_FLAGS="-DNMTL_IOS26=1"
# the bridge: fat LTO, one codegen unit: CoreAnimation's thread 91 -> 47 ms of CPU a frame, in one comparison of 3 runs [V phone, docs/laurel_sprout/ios26-default-speed.md]. Build time: 12 min against 5.
export CARGO_PROFILE_RELEASE_LTO=${CARGO_PROFILE_RELEASE_LTO:-fat} CARGO_PROFILE_RELEASE_CODEGEN_UNITS=${CARGO_PROFILE_RELEASE_CODEGEN_UNITS:-1}
export PLUGIN_CLASS=${PLUGIN_CLASS:-NegroniMTLDevice}   # the class that the kernel names (kernel need K1). ios26-metal-options.sh builds its own copy with another class
mkdir -p "$METAL_OUT" "$GPU_OUT"
# the Mesa archive and the build venv of the iOS 16 tree are inputs that do not change: shared (read only), when they exist
for d in dl venv; do
  [ -e "$GPU_OUT/$d" ] || { [ -e "$OUTDIR/gpu/$d" ] && ln -s "$(readlink -f "$OUTDIR/gpu/$d")" "$GPU_OUT/$d"; } || true
done
what=${1:-all}
case "$what" in
all|fetch|turnip|bridge|plugin|check) "$HERE/metal-build.sh" "$what" ;;
*) sed -n 2,10p "$0"; exit 1 ;;
esac
case "$what" in all|check)
  python3 -I "$REPO/scripts/ios26/abi-check.py" "$METAL_OUT/stage" ;;
esac
case "$what" in all|plugin)
  STAGE=$METAL_OUT/stage
  [ -f "$STAGE/System/Library/Extensions/NegroniMetal.bundle/NegroniMetal" ] && {
    # the frontend against what the 23F84 images send: a missing required selector on an object of ours is a crash in that image
    python3 -I "$REPO/scripts/ios26/selector-gap.py" --front "$METAL_OUT/src/flame/phone/metal2/NativeBridgeMetalFrontend.mm" \
      "$OUTDIR/ios26/metal-spi/QuartzCore.lst" "$OUTDIR/ios26/metal-spi/RenderBox.sel" "$OUTDIR/ios26/metal-spi/IconRendering.sel" \
      > "$METAL_OUT/selector-gap.txt" 2>&1 || true
    grep -E '^(object|selector-gap)' "$METAL_OUT/selector-gap.txt" || true
  } ;;
esac
