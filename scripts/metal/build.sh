#!/bin/bash
# Build the Metal path for iOS 16 arm64 and stage it in out/metal/stage (the layout root-add-metal.sh installs):
#   stage/System/Library/Extensions/NegroniMetal.bundle/{NegroniMetal,Info.plist,libvulkan_freedreno.dylib}
#   stage/System/Library/Extensions/NegroniMetal.bundle/clients   (the test tools; every process can read the bundle)
#   stage/usr/local/bin/{vkprobe,metalprobe,m2vtest,carenderprobe,layerprobe,metallib-sweep.sh}
#   stage/usr/local/share/negronimetal/{layerprobe.metallib,metallibs.txt}   (stage 4a / 3b inputs)
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
mkdir -p "$STAGE/usr/local/bin" "$STAGE/usr/local/share/negronimetal" "$STAGE/var/db/negronimetal"
for t in vkprobe metalprobe m2vtest carenderprobe layerprobe; do
  [ -f "$BUILD/$t" ] || continue
  cp "$BUILD/$t" "$STAGE/usr/local/bin/$t"
  "$STRIP" -x "$STAGE/usr/local/bin/$t"
  sign "$STAGE/usr/local/bin/$t"
done
# stage 3b: the all-metallib sweep (Chlorophyll ca-sweep.sh, MIT) and its list: every .metallib of the 20H392 root
# (out/metal/spi/metallibs.txt, scripts/metal/spi-dump.sh), as phone paths
cp "$METAL/probes/metallib-sweep.sh" "$STAGE/usr/local/bin/metallib-sweep.sh"
chmod 755 "$STAGE/usr/local/bin/metallib-sweep.sh"
if [ -f "$MOUT/spi/metallibs.txt" ]; then
  sed -e 's#^rootmnt/#/#' "$MOUT/spi/metallibs.txt" > "$STAGE/usr/local/share/negronimetal/metallibs.txt"
else
  echo "NOTE: no $MOUT/spi/metallibs.txt: stage 3b needs a list argument" >&2
fi
# stage 4a: layerprobe's two shaders as AIR for iOS 16 (Xcode's metal compiler; skipped without it)
if xcrun --sdk iphoneos -f metal > /dev/null 2>&1; then
  xcrun --sdk iphoneos metal -mios-version-min="$IOS_MIN" -o "$STAGE/usr/local/share/negronimetal/layerprobe.metallib" \
    "$METAL/probes/layerprobe.metal"
else
  echo "NOTE: no metal compiler: layerprobe.metallib not built (layerprobe takes a metallib argument)" >&2
fi

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
  sign "$B/$PLUGIN_NAME"
  sed -e "s/@NAME@/$PLUGIN_NAME/g" -e "s/@CLASS@/$PLUGIN_CLASS/g" "$METAL/plugin/Info.plist.in" > "$B/Info.plist"
  # Control file in the bundle, readable by every process that loads the plugin (sandboxed apps too; NegroniMetal.mm).
  # Every push replaces it. The owner's own lists: /var/db/negronimetal/clients, and BUNDLE/clients.local (not staged).
  cat > "$B/clients" <<'EOF2'
# The test tools, which always get the NegroniMetal device (userland/metal/plugin/NegroniMetal.mm). Staged by
# scripts/metal/build.sh: a push replaces this file. Put other names in /var/db/negronimetal/clients (unsandboxed
# processes) or in clients.local next to this file (read by sandboxed apps too; a push keeps it).
metalprobe m2vtest carenderprobe layerprobe
EOF2
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

# Every import of the staged binaries must exist in the 20H392 dyld cache (check-imports.py; exit 1 = missing symbols):
# a missing one fails the build. IOS_DSC = the cache of an attached root; the exports already read are cached in
# out/metal/spi/exports, so the root needs to be attached only for images not read before. NO_IMPORT_CHECK=1 skips it.
if [ "${NO_IMPORT_CHECK:-0}" != 1 ]; then
  # The 20H392 cache: a copy in out/dsc/cache (kept after the raw root image was deleted, 2026-10-26), else an
  # attached root at /private/tmp/iosroot-ro.
  if [ -z "${IOS_DSC:-}" ]; then
    IOS_DSC=$OUT/dsc/cache/dyld_shared_cache_arm64
    [ -f "$IOS_DSC" ] || IOS_DSC=/private/tmp/iosroot-ro/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64
  fi
  bins=$(cd "$STAGE" && find . -type f -perm -u+x ! -name '*.sh' | sort)
  (cd "$STAGE" && python3 "$REPO/scripts/metal/check-imports.py" "$IOS_DSC" $bins) ||
    { echo "check-imports: FAILED (missing imports or no cache: attach the root or set IOS_DSC)" >&2; exit 1; }
fi
