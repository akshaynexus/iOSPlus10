# Shared settings of the Mi A3 (laurel_sprout, Adreno 610) Metal build, sourced by scripts/laurel/metal-*.sh.
# Linux: everything below. macOS: only the paths and the Turnip patch list; the negroni scripts then run as they are
# (Xcode SDK through xcrun, Apple clang/ld64, codesign).
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
[ "$(uname -s)" = Darwin ] || export SDK=${SDK:-$LM/sdk/$SDK_NAME}   # macOS: scripts/metal/env.sh asks xcrun

# Mesa freedreno Vulkan (Turnip) for the A610: Mesa 25.0.7, as the negroni Metal path (scripts/gpu/env.sh). The A610
# entry of Mesa's device table (GPUId(610) = 0x060100ff, a6xx gen1 low) is in this release: docs/laurel_sprout/metal.md.
# AREA B (laurel 2150) answers CHIP_ID 0x06010000 (kgsl, Mi A3) and HIGHEST_BANK_BIT 14; Turnip uses the kernel's HBB
# (tu_knl_drm_msm.cc), the table's 13 is only its fallback. Base topaz answered 0x06010001; both match the table.
LAUREL_CHIP_ID=0x06010000
# Turnip patches of this port, after userland/turnip/mesa-patches (scripts/gpu/turnip-build.sh TU_EXTRA_PATCHES):
# 0101 caps maxMemoryAllocationSize/maxBufferSize at the kernel's RedwoodMaxBuffer (pass-through SMMU: < 64 MiB)
# 0102 reports Vulkan 1.3 for the A610 (no HW multiview: upstream says 1.0, and metal2vulkan needs 1.2)
# 0103 host pointers aligned to the page size of the process (4 KiB on the laurel kernel, not 16 KiB)
export TU_EXTRA_PATCHES="$LMSRC/turnip-patches"
# Compiled target (Kryo 260, ARMv8.0; measured choice: docs/laurel_sprout/metal.md "Compiled target"):
#   C/C++/ObjC (Turnip, plug-in, probes): -mcpu=cortex-a53 (ISA floor and tuning) + the A53 erratum 835769 fix
#   Turnip: -O3 (meson release) + ThinLTO through ld64.lld, debug info kept as a dSYM (out/gpu/turnip/*.dSYM)
#   Rust (metal2vulkan + bridge): target-cpu cortex-a53, the same erratum fix, thin LTO, 4 codegen units
# Only this port sets them: negroni builds (scripts/gpu, scripts/metal without metal-env.sh) are unchanged.
LAUREL_CPU_FLAGS="-mcpu=cortex-a53 -mfix-cortex-a53-835769"
export TU_CPU_FLAGS="$LAUREL_CPU_FLAGS"
export TU_MESON_ARGS="-Db_lto=true -Db_lto_mode=thin -Ddebug=true"
# Turnip's ~3300 absent weak imports: no flat lookup at load (device open 3-10 s, docs/laurel_sprout/metal.md section 11)
export TU_WEAK_SELF=1
export NMTL_CPU_FLAGS="$LAUREL_CPU_FLAGS"
export CARGO_TARGET_AARCH64_APPLE_IOS_RUSTFLAGS="-C target-cpu=cortex-a53 -C target-feature=+fix-cortex-a53-835769"
export CARGO_PROFILE_RELEASE_LTO=thin
export CARGO_PROFILE_RELEASE_CODEGEN_UNITS=4
# metal2vulkan shader cache (translated functions, pipelines, Turnip's VkPipelineCache data = ir3 binaries) caps, read at
# cargo time by flame/0018: 32 MiB memo per process (default 256 MiB: every Metal process has its own device), 1 GiB on
# disk per cache directory (default 25 GiB).
export NMB_SHADER_MEMO_MB=32
export NMB_SHADER_DISK_MB=1024
# Host tool floor (Linux): ld64.lld emits chained fixups by default from LLVM 18 on [I: older ones fail the Turnip check
# late]; checked in laurel_metal_tools.
LLVM_MIN=18

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
  [ "$(uname -s)" = Linux ] || return 0          # macOS: Xcode's own tools
  mkdir -p "$TOOLBIN"
  local t v
  for t in clang ld64.lld; do
    command -v $t > /dev/null || { echo "metal: missing $t (pacman -S clang lld / apt install clang lld)" >&2; return 1; }
    v=$($t --version 2>/dev/null | sed -n 's/.*\(clang version\|LLD\) \([0-9][0-9]*\)\..*/\2/p' | head -1)
    [ -n "$v" ] && [ "$v" -ge "$LLVM_MIN" ] ||
      { echo "metal: $t major version ${v:-?} < $LLVM_MIN" >&2; return 1; }
  done
  # lipo: llvm-lipo prints "arm64 " (a blank at the end); the negroni scripts compare the whole line
  command -v llvm-lipo > /dev/null || { echo "metal: missing llvm-lipo (pacman -S llvm / apt install llvm)" >&2; return 1; }
  # parallel metal-build steps source this file: write a new file, then move it, so no step sees a missing or half-written lipo
  printf '#!/bin/sh\nllvm-lipo "$@" | sed "s/ *$//"\n' > "$TOOLBIN/lipo.$$"
  chmod 755 "$TOOLBIN/lipo.$$"
  mv -f "$TOOLBIN/lipo.$$" "$TOOLBIN/lipo"
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
