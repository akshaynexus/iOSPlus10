#!/bin/bash
# Build the Mi A3 (laurel_sprout) XNU kernel natively on Linux (no macOS, no Xcode).
#   scripts/bg.sh laurel-kernel scripts/laurel/kernel-linux.sh     (always in tmux)
#   AUDIT=1 ...   apply every patch and list the ones that fail (no build)
#   CLEAN=1 ...   also drop the cached toolchain, SDK and host tools
#
# Recipe: external/ios-sweet-linux (myh120405) builds the ios-sweet SWEET kernel on Ubuntu with
# stock clang + the theos cctools ld64 + MacOSX13.3.sdk + generated DriverKit (iig) stubs. topaz
# (external/ios-topaz) is the same xnu tag (xnu-8796.141.3, MACOS_VERSION=13.5) and the same
# MACHINE_CONFIG=SWEET, so its scripts run unchanged with another patch directory:
#   patches = external/ios-topaz/xnu/patches/*  +  patches/laurel/xnu/*.patch (our Mi A3 deltas, 2000-*)
# Linux-only compiler fixes: the generic ones of ios-sweet-linux (0001 kalloc, 0003 sha256 asm)
# + patches/laurel/xnu-linux-fixes/*.patch. Patches that dxb also skips: patches/laurel/known-skips.txt.
# Work tree: out/laurel-kernel/ (git-ignored). Output: out/laurel-kernel/out/kernel.development.sweet.
# Host needs: clang lld llvm flex bison m4 perl python3 autoconf automake libtool curl xz git
#             libxml2 uuid headers (util-linux), pkg-config, jq, file.
set -euo pipefail
. "$(dirname "$0")/../lib/env.sh"
W=$OUT/laurel-kernel
SRC=$EXT/ios-sweet-linux
TOPAZ=$EXT/ios-topaz
THEOS_SHA=6e7b8c40e0f5f9f5b2377800dc1e42cd2560d24a
# theos' own installer (bin/install-theos) takes this toolchain from L1ghtmann/llvm-project; the release has
# no checksum, so ours is pinned (first download 2026-10-31; tar list checked: only linux/iphone/..., no
# absolute or ../ paths, no device files). A changed file stops the build.
TOOLCHAIN_URL=https://github.com/L1ghtmann/llvm-project/releases/download/test-210562a/iOSToolchain-x86_64.tar.xz
TOOLCHAIN_SHA256=a72a7a577e2fbe2838b6b5e9c72034fa7d114af96f0e1d4b016f18730ce4056e

for d in "$SRC/linux" "$TOPAZ/xnu/patches"; do
  [ -d "$d" ] || { echo "kernel-linux: missing $d: scripts/setup/get-references.sh ios-sweet-linux ios-topaz" >&2; exit 1; }
done
[ "$(uname -s)" = Linux ] || { echo "kernel-linux: Linux only (macOS: scripts/kernel/build-local.sh recipe)" >&2; exit 1; }
[ "$(uname -m)" = x86_64 ] || { echo "kernel-linux: the pinned theos toolchain is x86_64" >&2; exit 1; }
for t in clang flex bison m4 perl python3 autoreconf automake curl xz git jq file make; do
  command -v $t >/dev/null || { echo "kernel-linux: missing host tool $t" >&2; exit 1; }
done

[ "${CLEAN:-0}" = 1 ] && rm -rf "${W:?}"
mkdir -p "$W"
# the scripts find everything relative to TOP=$W: a fresh copy of linux/ every run,
# deps/ theos/ (toolchain, SDK, host tools) are kept between runs
rm -rf "$W/linux" "$W/patches"
cp -R "$SRC/linux" "$W/linux"
rm -f "$W/linux/fixes/"*.patch
cp "$SRC/linux/fixes/0001-kalloc-stock-clang-void-ptr.patch" "$SRC/linux/fixes/0003-corecrypto-sha256-asm-operands.patch" "$W/linux/fixes/"
cp "$REPO"/patches/laurel/xnu-linux-fixes/*.patch "$W/linux/fixes/" 2>/dev/null || true
cp "$REPO/patches/laurel/known-skips.txt" "$W/linux/known-skips.txt"

mkdir -p "$W/patches"
cp "$TOPAZ"/xnu/patches/*.patch "$TOPAZ"/xnu/patches/*.sh "$W/patches/"
cp "$REPO"/patches/laurel/xnu/*.patch "$W/patches/" 2>/dev/null || true
echo "kernel-linux: topaz $(git -C "$TOPAZ" rev-parse --short HEAD), $(ls "$W"/patches/*.patch | wc -l) patches, $(ls "$REPO"/patches/laurel/xnu/*.patch 2>/dev/null | wc -l) of them laurel"

export TOP=$W PATCHES_DIR=$W/patches THEOS=$W/theos MACHINE_CONFIG=SWEET KERNEL_CONFIG=DEVELOPMENT JOBS=$NPROC
if [ ! -x "$THEOS/toolchain/linux/iphone/bin/ld" ]; then
  rm -rf "$THEOS"
  git init -q "$THEOS"
  git -C "$THEOS" fetch -q --depth 1 https://github.com/theos/theos.git "$THEOS_SHA"
  git -C "$THEOS" checkout -q FETCH_HEAD
  mkdir -p "$THEOS/toolchain" "$W/dl"
  tc=$W/dl/iOSToolchain-x86_64.tar.xz
  [ -f "$tc" ] || curl -fsSL --retry 5 -o "$tc" "$TOOLCHAIN_URL"
  echo "$TOOLCHAIN_SHA256  $tc" | sha256sum -c - || { echo "kernel-linux: toolchain checksum changed" >&2; exit 1; }
  tar -xJf "$tc" -C "$THEOS/toolchain/"
fi
cd "$W"
bash linux/setup-sdk.sh
if [ "${AUDIT:-0}" = 1 ]; then
  STRICT_PATCHES=1 bash linux/apply-xnu.sh 2>&1 | tee "$W/apply-audit.log"
  exit "${PIPESTATUS[0]}"
fi
bash linux/apply-xnu.sh 2>&1 | tee "$W/apply-xnu.log"
bash linux/setup-deps.sh --stage1
bash linux/build.sh exporthdrs > "$W/exporthdrs.log" 2>&1 || { tail -40 "$W/exporthdrs.log"; exit 1; }
bash linux/setup-deps.sh --stage2
rm -f "$W/build.log"
bash linux/build-with-iig.sh || true

K=$W/xnu-src/xnu-8796.141.3/BUILD/obj/DEVELOPMENT_ARM64_SWEET/kernel.development.sweet
if [ ! -s "$K" ]; then
  echo "kernel-linux: no kernel; first errors:" >&2
  grep -n -m 40 -E "error:|Undefined symbols|symbol\(s\) not found" "$W/build.log" >&2 || true
  exit 1
fi
mkdir -p "$W/out"
cp "$K" "$W/out/"
[ -s "$K.unstripped" ] && cp "$K.unstripped" "$W/out/"
(cd "$W/out" && sha256sum kernel.* > SHA256SUMS)
file "$W/out/kernel.development.sweet"
# ARMv8.0 check (topaz README): no LSE / RCpc left except the K256 SHA table
if command -v llvm-objdump >/dev/null; then
  n=$(llvm-objdump -d --mattr=+v8.5a "$W/out/kernel.development.sweet" | grep -cP '\t(cas|casa|casal|ldadd\w*|ldset\w*|ldclr\w*|swp\w*|ldapr\w*)\s' || true)
  echo "kernel-linux: LSE/RCpc instructions in the kernel: $n (topaz: only the K256 table hits)"
fi
echo "kernel-linux: $W/out/kernel.development.sweet"
