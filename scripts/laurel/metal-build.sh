#!/bin/bash
# Build the Metal path for the Mi A3 (Adreno 610) natively on Linux (no Mac, no Xcode); on macOS the same steps run the
# negroni scripts as they are (Xcode SDK, Apple clang/ld64, codesign), with this port's Turnip patches:
#   iPhoneOS16.5.sdk + Rust 1.98.0 (aarch64-apple-ios) -> Turnip (Mesa 25.0.7, msm KMD over the RedwoodGPU user client)
#   -> metal2vulkan bridge (Rust staticlib) -> NegroniMetal.bundle + probes, signed with ldid, staged in out/metal/stage
#   (the layout scripts/laurel/root-add-metal.sh installs into the root). Design: docs/laurel_sprout/metal.md.
#
#   scripts/bg.sh laurel-metal scripts/laurel/metal-build.sh            all steps (always in tmux: minutes)
#   scripts/laurel/metal-build.sh fetch|turnip|bridge|plugin|check      one step
#     fetch   SDK (theos/sdks, pinned), Rust toolchain, metal2vulkan + ios-flame sources (scripts/metal/fetch-sources.sh)
#     turnip  scripts/gpu/turnip-build.sh (Linux: clang + ld64.lld) -> out/gpu/turnip/libvulkan_freedreno.dylib
#     bridge  scripts/metal/build-bridge.sh ios -> out/metal/bridge/ios/libnative_metal_bridge.a
#     plugin  scripts/metal/build.sh with the Linux CMake toolchain -> out/metal/stage
#     check   A610 facts of the Turnip tree and the staged binaries (arm64, minos 16.0, no LSE: ARMv8.0 cores)
# Env: SDK=DIR (an iPhoneOS.sdk), IOS_DSC=FILE (20H392 dyld cache for the import check; else the check is skipped
# with a NOTE), NPROC (default: all host cores; cargo, ninja and meson use it).
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/metal-env.sh"
mkdir -p "$LM" "$REPO/logs"
ts() { date +%H:%M:%S; }
sha256() { if command -v sha256sum > /dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }
LINUX=0; [ "$(uname -s)" = Linux ] && LINUX=1

step_fetch() {
  laurel_metal_tools
  if [ $LINUX = 0 ]; then "$REPO/scripts/metal/fetch-sources.sh"; return; fi   # macOS: Xcode SDK, the negroni fetch
  # 1. SDK: sparse, blob-less clone of one SDK directory at the pinned commit
  if [ ! -f "$SDK/SDKSettings.json" ] && [ ! -f "$SDK/SDKSettings.plist" ]; then
    case "$SDK" in "$LM"/*) ;; *) echo "metal: SDK=$SDK is not an SDK directory" >&2; exit 1 ;; esac
    local t=$LM/sdk/.clone
    rm -rf "$t"
    git clone -q --filter=blob:none --no-checkout "$SDK_REPO" "$t"
    git -C "$t" sparse-checkout set --no-cone "/$SDK_NAME/"
    git -C "$t" -c advice.detachedHead=false checkout -q "$SDK_COMMIT"
    [ -f "$t/$SDK_NAME/usr/lib/libSystem.tbd" ] || { echo "metal: $SDK_NAME incomplete in theos/sdks $SDK_COMMIT" >&2; exit 1; }
    rm -rf "$SDK"
    mv "$t/$SDK_NAME" "$SDK"
    rm -rf "$t"
  fi
  for f in usr/lib/libSystem.tbd System/Library/Frameworks/Metal.framework System/Library/Frameworks/IOSurface.framework \
           System/Library/Frameworks/IOKit.framework usr/include/c++/v1/vector; do
    [ -e "$SDK/$f" ] || { echo "metal: $SDK lacks $f" >&2; exit 1; }
  done
  echo "$(ts) metal: SDK $SDK ($(sed -n 's/.*"Version":"\([^"]*\)".*/\1/p' "$SDK/SDKSettings.json" 2>/dev/null || echo ?))"
  # 2. ipsw (dyld cache exports for scripts/metal/check-imports.py): pinned Linux release, own directory
  if [ "$(uname -s)" = Linux ] && [ ! -x "$LM/ipsw/ipsw" ]; then
    local a=$LM/dl/ipsw_${IPSW_VERSION}_linux_x86_64.tar.gz
    mkdir -p "$LM/dl" "$LM/ipsw"
    if [ ! -f "$a" ]; then
      curl -sL --fail --retry 3 -o "$a.part" "$IPSW_URL"
      mv "$a.part" "$a"
    fi
    echo "$IPSW_SHA256  $a" | sha256 -c --quiet || { rm -f "$a"; echo "metal: ipsw archive hash mismatch" >&2; exit 1; }
    tar -xzf "$a" -C "$LM/ipsw" ipsw
  fi
  [ "$(uname -s)" != Linux ] || ln -sf "$LM/ipsw/ipsw" "$TOOLBIN/ipsw"
  # 3. Rust + metal2vulkan + flame frontend/bridge (negroni script; rustup comes from ~/.cargo/bin)
  # Extracted again only when a pin or a patch changed (FORCE=1: always): a new extraction makes cargo build the
  # whole bridge again (5-6 min).
  command -v rustup > /dev/null || { echo "metal: rustup missing (https://rustup.rs)" >&2; exit 1; }
  local stamp=$OUT/metal/src/.laurel-fetch want
  want=$( { git -C "$EXT/metal2vulkan" rev-parse HEAD; cat "$REPO/scripts/metal/env.sh" "$REPO/scripts/metal/fetch-sources.sh" \
    "$REPO"/userland/metal/patches/*/*.patch; } | sha256 | cut -c1-16)
  if [ "${FORCE:-0}" = 1 ] || [ "$(cat "$stamp" 2>/dev/null)" != "$want" ] || [ ! -d "$OUT/metal/src/flame/phone/metal2" ]; then
    "$REPO/scripts/metal/fetch-sources.sh"
    echo "$want" > "$stamp"
  else
    echo "$(ts) metal: metal2vulkan + flame sources up to date ($want)"
  fi
}

step_turnip() {
  laurel_metal_tools
  "$REPO/scripts/gpu/turnip-build.sh"
}

step_bridge() {
  laurel_metal_tools
  # cc-rs (sha2 asm) finds the iOS SDK through SDKROOT on a host without xcrun; host build scripts ignore it
  if [ $LINUX = 1 ]; then SDKROOT=$SDK "$REPO/scripts/metal/build-bridge.sh" ios; else "$REPO/scripts/metal/build-bridge.sh" ios; fi
}

# Mount the 20H392 SystemOS image read-only (user space) so IOS_DSC names its dyld cache; unmounted on exit.
DSC_MNT=$LM/dsc-mnt
dsc_umount() { mountpoint -q "$DSC_MNT" 2>/dev/null && fusermount3 -u "$DSC_MNT" || true; }
dsc_mount() {
  [ -z "${IOS_DSC:-}" ] || return 0
  [ -f "$OUT/dsc/cache/dyld_shared_cache_arm64" ] && return 0
  if [ -f "$DSC_DMG" ] && command -v apfs-fuse > /dev/null; then
    mkdir -p "$DSC_MNT"
    dsc_umount
    apfs-fuse -o ro "$DSC_DMG" "$DSC_MNT" &&
      [ -f "$DSC_MNT/root/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64" ] &&
      { export IOS_DSC=$DSC_MNT/root/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64; trap dsc_umount EXIT; return 0; }
    dsc_umount
  fi
  echo "NOTE: no 20H392 dyld cache ($DSC_DMG + apfs-fuse, or IOS_DSC): import check skipped" >&2
  export NO_IMPORT_CHECK=1
}

step_plugin() {
  laurel_metal_tools
  if [ $LINUX = 0 ]; then "$REPO/scripts/metal/build.sh"; return; fi   # macOS: negroni's build, unchanged
  dsc_mount
  # CMake reads the toolchain's CPU flags (NMTL_CPU_FLAGS) only when it configures: other flags = a new build directory
  local b=$OUT/metal/build
  [ "$(cat "$b/.laurel-flags" 2>/dev/null)" = "$NMTL_CPU_FLAGS" ] || rm -rf "$b"
  mkdir -p "$b"; echo "$NMTL_CPU_FLAGS" > "$b/.laurel-flags"
  # scripts/metal/build.sh with our Linux toolchain file (clang -target arm64-apple-ios16.0 + ld64.lld)
  NMTL_CMAKE_TOOLCHAIN=$LMSRC/cmake/ios-arm64-linux.cmake "$REPO/scripts/metal/build.sh"
}

# The A610 facts this path depends on, read from the patched Turnip tree and the staged binaries.
step_check() {
  local fail=0 tu=$OUT/gpu/turnip/mesa-25.0.7 st=$OUT/metal/stage
  command -v llvm-objdump > /dev/null && command -v llvm-otool > /dev/null || { echo "check: needs llvm-objdump, llvm-otool"; return 1; }
  if [ -d "$tu" ]; then
    python3 -I "$REPO/scripts/laurel/metal-a610.py" "$tu" "$LAUREL_CHIP_ID" || fail=1
    # Turnip 0102: without it the A610 (no HW multiview) reports Vulkan 1.0 and metal2vulkan (needs 1.2) finds no device
    if grep -q 'tu_darwin_full_api(pdevice))' "$tu/src/freedreno/vulkan/tu_device.cc"; then
      echo "check: Turnip reports Vulkan 1.3 for the A610 (0102 in the tree)"
    else
      echo "check: Turnip tree lacks 0102: the A610 would report Vulkan 1.0 (metal2vulkan refuses it)"; fail=1
    fi
  else
    echo "check: no Turnip tree $tu (step turnip)"; fail=1
  fi
  local b
  for b in "$st/System/Library/Extensions/NegroniMetal.bundle/NegroniMetal" \
           "$st/System/Library/Extensions/NegroniMetal.bundle/libvulkan_freedreno.dylib" "$st"/usr/local/bin/*; do
    [ -f "$b" ] || { echo "check: missing $b"; fail=1; continue; }
    file -b "$b" | grep -q 'Mach-O' || continue
    local minos v80
    minos=$(llvm-otool -l "$b" | awk '/LC_BUILD_VERSION/{p=1;next} p&&/minos/{print $2;exit}')
    # ARMv8.0 (Kryo 260): nothing newer than ARMv8.0 + CRC + AES/SHA (LSE and LDAPR trap into XNU's emulation, the
    # rest is SIGILL): scripts/laurel/armv80-check.py counts every later extension (LSE, RCpc, RDM, FP16, dot product,
    # PAC, JSCVT, FCMA, FlagM, SHA3, BF16, I8MM, MTE, SVE)
    v80=$(python3 -I "$REPO/scripts/laurel/armv80-check.py" "$b") || fail=1
    printf 'check: %-60s minos %s, %s\n' "${b#$st/}" "$minos" "${v80#*: }"
    [ "$minos" = 16.0 ] || fail=1
  done
  [ $fail = 0 ] && echo "check: PASS" || { echo "check: FAIL"; return 1; }
}

what=${1:-all}
T0=$(date +%s)
case "$what" in
fetch|turnip|bridge|plugin|check) "step_$what" ;;
all)
  step_fetch
  # Turnip (C/C++, meson/ninja -j NPROC) and the bridge (cargo -j NPROC) do not depend on each other: in parallel
  ( step_turnip > "$LM/turnip.log" 2>&1 ) & tp=$!
  ( step_bridge > "$LM/bridge.log" 2>&1 ) & bp=$!
  rc=0
  wait $tp || { echo "turnip FAILED:"; tail -40 "$LM/turnip.log"; rc=1; }
  wait $bp || { echo "bridge FAILED:"; tail -40 "$LM/bridge.log"; rc=1; }
  [ $rc = 0 ] || exit 1
  tail -4 "$LM/turnip.log"; tail -2 "$LM/bridge.log"
  step_plugin
  step_check
  ;;
*) sed -n 2,16p "$0"; exit 1 ;;
esac
echo "$(ts) metal-build $what: done in $(( $(date +%s) - T0 )) s"
