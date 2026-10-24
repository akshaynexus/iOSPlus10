#!/bin/bash
# Build the Metal path for iOS 16 arm64 and stage it in out/metal/stage (the layout root-add-metal.sh installs):
#   stage/System/Library/Extensions/NegroniMetal.bundle/{NegroniMetal,Info.plist,libvulkan_freedreno.dylib}
#   stage/usr/local/bin/{vkprobe,metalprobe,m2vtest}
#   stage/var/db/negronimetal/clients           (default: the probes only)
#
#   scripts/metal/build.sh            probes always; the plugin when the bridge is built (build-bridge.sh)
#   scripts/metal/build.sh --probes   probes only
# Needs: Xcode + iPhoneOS SDK (macOS) or clang/lld + SDK (Linux), cmake, ninja, vulkan headers.
# The Turnip dylib comes from the GPU user-space build (TURNIP_DYLIB, scripts/metal/env.sh); without it the bundle is
# staged without Turnip and the plugin refuses to open a device (it logs why).
# Long: run in tmux: scripts/bg.sh metal-build scripts/metal/build.sh
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/env.sh"

probes_only=0
[ "${1:-}" = --probes ] && probes_only=1
BUILD=$MOUT/build
STAGE=$MOUT/stage
BRIDGE_LIB=$MOUT/bridge/ios/libnative_metal_bridge.a
FRONT=$FLAME_SRC/phone/metal2
if [ $probes_only = 1 ]; then BRIDGE_LIB=""; fi

export IOS_MIN SDK
cmake -S "$METAL" -B "$BUILD" -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_TOOLCHAIN_FILE="$METAL/cmake/ios-arm64.cmake" \
  -DNMTL_BRIDGE_LIB="$BRIDGE_LIB" -DNMTL_FLAME_SRC="$FRONT" -DNMTL_CLASS="$PLUGIN_CLASS" > "$MOUT/cmake.log" 2>&1 ||
  { tail -30 "$MOUT/cmake.log"; exit 1; }
ninja -C "$BUILD" -j "$NPROC"

STRIP=$(xcrun --sdk iphoneos -f strip 2>/dev/null || command -v llvm-strip || echo strip)
sign() { codesign -f -s - "$@" 2>/dev/null || ldid -S "$@"; }

rm -rf "$STAGE"
mkdir -p "$STAGE/usr/local/bin" "$STAGE/var/db/negronimetal"
for t in vkprobe metalprobe m2vtest; do
  [ -f "$BUILD/$t" ] || continue
  cp "$BUILD/$t" "$STAGE/usr/local/bin/$t"
  "$STRIP" -x "$STAGE/usr/local/bin/$t"
  sign "$STAGE/usr/local/bin/$t"
done

cat > "$STAGE/var/db/negronimetal/clients" <<'EOF'
# Processes that get the NegroniMetal Metal device (userland/metal/plugin/NegroniMetal.mm).
# Names separated by blanks, "*" = all, "-NAME" = never NAME. Default: only the test tools.
# The Metal stages (docs/metal-plan.md) add backboardd and SpringBoard here (stage 4).
metalprobe m2vtest
EOF

if [ -f "$BUILD/NegroniMetal" ]; then
  B=$STAGE/System/Library/Extensions/$PLUGIN_NAME.bundle
  mkdir -p "$B"
  cp "$BUILD/NegroniMetal" "$B/$PLUGIN_NAME"
  dsymutil "$B/$PLUGIN_NAME" -o "$MOUT/$PLUGIN_NAME.dSYM" 2>/dev/null || true
  "$STRIP" -x "$B/$PLUGIN_NAME"
  sed -e "s/@NAME@/$PLUGIN_NAME/g" -e "s/@CLASS@/$PLUGIN_CLASS/g" "$METAL/plugin/Info.plist.in" > "$B/Info.plist"
  if [ -f "$TURNIP_DYLIB" ]; then
    cp "$TURNIP_DYLIB" "$B/libvulkan_freedreno.dylib"
    "$STRIP" -x "$B/libvulkan_freedreno.dylib"
    nm -gU "$B/libvulkan_freedreno.dylib" | grep -q -E " T _(vk_icdGetInstanceProcAddr|vkGetInstanceProcAddr)$" ||
      echo "WARNING: $TURNIP_DYLIB exports no vk(_icd)GetInstanceProcAddr" >&2
    sign "$B/libvulkan_freedreno.dylib"
  else
    echo "NOTE: no Turnip at $TURNIP_DYLIB (GPU user-space build): bundle staged without it" >&2
  fi
  sign "$B"
  # iOS 16 lacks symbols that newer SDKs declare: weak imports resolve to NULL there (ios-flame "strchrnul lesson")
  nm -m "$B/$PLUGIN_NAME" | grep "weak external" | grep -v "dynamically looked up" || true
  echo "plugin: $B"
else
  echo "NOTE: plugin not built (bridge missing: scripts/metal/build-bridge.sh)" >&2
fi
(cd "$STAGE" && find . -type f | sort | xargs ls -la)
