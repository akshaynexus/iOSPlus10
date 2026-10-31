# Shared settings of the Mi A3 (laurel_sprout, Adreno 610) Metal build on Linux, sourced by scripts/laurel/metal-*.sh.
# The Metal stack is negroni's (docs/metal-design.md: NegroniMetal plug-in -> ios-flame frontend + bridge ->
# metal2vulkan -> Turnip). This file only makes the negroni scripts (scripts/gpu/turnip-build.sh, scripts/metal/*.sh)
# run on a Linux host with no Xcode. Decision and interfaces: docs/laurel_sprout/metal.md.
# Pins: change them only together with docs/laurel_sprout/metal.md "Versions".
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../lib" && pwd)/env.sh"

LM=$OUT/laurel-metal                       # our build products (git-ignored): SDK, tool links, logs, stage
LMSRC=$REPO/userland/laurel/metal          # our sources (CMake toolchain for Linux, patches)

# iPhoneOS16.5.sdk from theos/sdks (the SDK hackios-scion mk-mesa.sh / mk-gfx.sh use on Linux). Only .tbd stubs and
# headers (no Apple binaries); git-ignored, never committed.
SDK_REPO=https://github.com/theos/sdks.git
SDK_COMMIT=0222fd5413cf4b9af096f37b4621afa2688572f7   # theos/sdks master, 2026-11-01
SDK_NAME=iPhoneOS16.5.sdk
export SDK=${SDK:-$LM/sdk/$SDK_NAME}

# Mesa freedreno Vulkan (Turnip) for the A610: Mesa 25.0.7, as the negroni Metal path (scripts/gpu/env.sh). The A610
# entry of Mesa's device table (chip id 0x06010000, a6xx gen1) is in this release: docs/laurel_sprout/metal.md.
LAUREL_CHIP_ID=0x06010001                  # what topaz TopazAdreno.cpp answers for CHIP_ID (MSM_PARAM 0x03)

# Linux stand-ins for the Apple tools the negroni scripts call (each one is an LLVM tool that reads Mach-O):
#   lipo -> llvm-lipo, otool -> llvm-otool, install_name_tool -> llvm-install-name-tool, nm -> llvm-nm (nm -m),
#   ldid -> theos ldid, ipsw -> blacktop/ipsw (pinned release, SHA-256 checked; scripts/metal/check-imports.py)
TOOLBIN=$LM/bin
IPSW_VERSION=3.1.741
IPSW_SHA256=992a93c708861c14118ebd69c3493d2f5d0af08f57fb345839630ece3e227b20   # ipsw_3.1.741_linux_x86_64.tar.gz
IPSW_URL=https://github.com/blacktop/ipsw/releases/download/v$IPSW_VERSION/ipsw_${IPSW_VERSION}_linux_x86_64.tar.gz
# The 20H392 dyld cache for the import check: the SystemOS cryptex image of the iOS 16.7.16 IPSW (scripts/laurel/root.sh
# input), mounted read-only in user space with apfs-fuse while the check runs. Apple content: never copied into git.
APPLE=${APPLE:-$HOME/op10-apple}
DSC_DMG=${DSC_DMG:-$APPLE/20H392/087-86593-047.dmg}
THEOS_BIN=${THEOS_BIN:-$OUT/laurel-kernel/theos/toolchain/linux/iphone/bin}
laurel_metal_tools() {
  mkdir -p "$TOOLBIN"
  local t
  # lipo: llvm-lipo prints "arm64 " (a blank at the end); the negroni scripts compare the whole line
  command -v llvm-lipo > /dev/null || { echo "metal: missing llvm-lipo (pacman -S llvm / apt install llvm)" >&2; return 1; }
  rm -f "$TOOLBIN/lipo"
  printf '#!/bin/sh\nllvm-lipo "$@" | sed "s/ *$//"\n' > "$TOOLBIN/lipo"
  chmod 755 "$TOOLBIN/lipo"
  for t in otool:llvm-otool install_name_tool:llvm-install-name-tool nm:llvm-nm; do
    command -v "${t#*:}" > /dev/null || { echo "metal: missing ${t#*:} (pacman -S llvm / apt install llvm)" >&2; return 1; }
    ln -sf "$(command -v "${t#*:}")" "$TOOLBIN/${t%%:*}"
  done
  if command -v ldid > /dev/null && [ "$(command -v ldid)" != "$TOOLBIN/ldid" ]; then
    ln -sf "$(command -v ldid)" "$TOOLBIN/ldid"
  elif [ -x "$THEOS_BIN/ldid" ]; then
    ln -sf "$THEOS_BIN/ldid" "$TOOLBIN/ldid"
  else
    echo "metal: no ldid (theos toolchain: scripts/laurel/kernel-linux.sh fetches it into $THEOS_BIN)" >&2
    return 1
  fi
}

case "$(uname -s)" in
Linux)
  # rustup's cargo/rustc proxies first: `cargo +1.98.0` needs them (the distribution's cargo has no iOS std)
  export PATH="$TOOLBIN:$HOME/.cargo/bin:$PATH"
  # cc-rs (sha2 asm, metal2vulkan build scripts) for the iOS target: no xcrun on Linux
  export CC_aarch64_apple_ios=${CC_aarch64_apple_ios:-clang}
  export CXX_aarch64_apple_ios=${CXX_aarch64_apple_ios:-clang++}
  export AR_aarch64_apple_ios=${AR_aarch64_apple_ios:-llvm-ar}
  export CFLAGS_aarch64_apple_ios="-isysroot $SDK"
  export CXXFLAGS_aarch64_apple_ios="-isysroot $SDK"
  export SDKROOT_aarch64_apple_ios=$SDK
  ;;
esac
