#!/bin/bash
# The iOS 26 bundle with its switchable Metal stacks: selector + options/default (ours: metal2vulkan 219f013 + flame-ios26) + options/hot (IOS-26-Hot's frontend, metal2vulkan 720ef1ce + series), Turnip shared; + options/native when scripts/laurel/ios26-metal-native-build.sh has run (no Turnip, no Vulkan: docs/laurel_sprout/ios26-native-metal.md). Out/ios26/metal-all/stage.
#   scripts/bg.sh ios26-metal-all scripts/laurel/ios26-metal-options.sh [selector]    all: both builds first; selector: only assemble from existing stages. Docs: docs/laurel_sprout/ios26-metal.md section 10.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
O=$REPO/out/ios26
if [ "${1:-all}" = all ]; then
  METAL_OUT=$O/metal-impl PLUGIN_CLASS=NegroniMTLDeviceImpl "$HERE/ios26-metal-build.sh" all
  "$HERE/ios26-metal-hot-build.sh" all
fi
export METAL_OUT=$O/metal-impl GPU_OUT=$O/gpu METAL_EXPORTS_CACHE=$O/metal-spi/exports
. "$HERE/metal-env.sh"
laurel_metal_tools
A=$O/metal-all
S=$A/stage
B=$S/System/Library/Extensions/NegroniMetal.bundle
rm -rf "$A"; mkdir -p "$A"
cp -a "$O/metal-impl/stage" "$S"
rm -rf "$B/_CodeSignature"
mkdir -p "$B/options/default" "$B/options/hot"
mv "$B/NegroniMetal" "$B/options/default/NegroniMetal"
cp "$O/metal-hot/stage/System/Library/Extensions/NegroniMetal.bundle/NegroniMetal" "$B/options/hot/NegroniMetal"
# the third option: an option, never the default until the owner's bench says so
if [ -f "$O/metal-native/NegroniMetal" ]; then
  mkdir -p "$B/options/native"
  cp "$O/metal-native/NegroniMetal" "$B/options/native/NegroniMetal"
fi
clang -target arm64-apple-ios16.0 -isysroot "$SDK" $LAUREL_CPU_FLAGS -fuse-ld=lld -O2 -fobjc-arc -bundle -Wall -Wextra -I"$REPO/userland/laurel/metal/option" \
  -framework Foundation -framework Metal -o "$B/NegroniMetal" "$REPO/userland/laurel/metal/option/option_select.m"
llvm-strip -x "$B/NegroniMetal"
ldid -S "$B/NegroniMetal"
sed -e "s/NegroniMTLDeviceImpl/NegroniMTLDevice/g" "$O/metal-impl/stage/System/Library/Extensions/NegroniMetal.bundle/Info.plist" > "$B/Info.plist"
ldid -S "$B" 2>/dev/null || true
python3 -I "$REPO/scripts/ios26/abi-check.py" "$S"
(cd "$S" && IOS_DSC=${IOS_DSC:-$HOME/op10-apple/ios26/23F84-n104ap/tree/cache/dyld_shared_cache_arm64e}; python3 "$REPO/scripts/metal/check-imports.py" "$IOS_DSC" ./System/Library/Extensions/NegroniMetal.bundle/NegroniMetal ./System/Library/Extensions/NegroniMetal.bundle/options/hot/NegroniMetal $( [ -f ./System/Library/Extensions/NegroniMetal.bundle/options/native/NegroniMetal ] && echo ./System/Library/Extensions/NegroniMetal.bundle/options/native/NegroniMetal )) | tail -2
grep -a -c 'NegroniMTLDeviceImpl' "$B"/options/*/NegroniMetal
llvm-nm -gU "$B/NegroniMetal" | grep -E 'OBJC_CLASS' | cut -c1-70
XNUTILS_IOS26=1 SDK=$SDK "$HERE/xnutils-build.sh" | tail -1
python3 -I "$REPO/scripts/ios26/abi-check.py" "$O/xnutils/root"
du -sh "$S"
ls -la "$B" "$B/options"/* | cut -c24-
