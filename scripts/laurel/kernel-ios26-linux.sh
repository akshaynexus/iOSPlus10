#!/bin/bash
# Build the Mi A3 (laurel_sprout, SWEET machine config) iOS 26 kernel natively on Linux: xnu-12377.121.6, plain arm64,
# Kryo 260 (ARMv8.0: no PAC, no LSE). The iOS 16 build (scripts/laurel/kernel-linux.sh, out/laurel-kernel/) is not touched.
#   scripts/bg.sh ios26-kernel scripts/laurel/kernel-ios26-linux.sh     (always in tmux)
#   PAGES=4k (default)  4 KiB pages, all 8 cores (topaz 0140/0141/0142, TOPAZ_4K=1)
#   STAGE=tree          stop after the series (series-report.txt)
#   INCR=1              keep the tree and the objects (compile fixes in src/xnu; then scripts/laurel/ios26-base-refresh.py)
# Same recipe as kernel-linux.sh (external/ios-sweet-linux + the pinned theos cctools + stock clang), macOS 26.5 versions and the
# MacOSX 26.1 SDK. Series: docs/laurel_sprout/ios26-kernel.md, patches/laurel/xnu-12377/README.md. Work tree out/laurel-kernel-ios26/.
# Compile and link only: nothing here writes to the phone.
set -euo pipefail
. "$(dirname "$0")/../lib/env.sh"
. "$REPO/scripts/laurel/ios26-env.sh"
[ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ] || { echo "kernel-ios26: x86_64 Linux only (the pinned theos toolchain)" >&2; exit 1; }
for t in clang flex bison m4 perl python3 autoreconf automake curl xz git jq file make 7z llvm-objdump llvm-nm; do
  command -v $t >/dev/null || { echo "kernel-ios26: missing host tool $t" >&2; exit 1; }
done
THEOS_SHA=6e7b8c40e0f5f9f5b2377800dc1e42cd2560d24a
TOOLCHAIN_URL=https://github.com/L1ghtmann/llvm-project/releases/download/test-210562a/iOSToolchain-x86_64.tar.xz
TOOLCHAIN_SHA256=a72a7a577e2fbe2838b6b5e9c72034fa7d114af96f0e1d4b016f18730ce4056e
LOGD=$W/logs
PAGES=${PAGES:-4k}
case "$PAGES" in 4k) export TOPAZ_4K=1 ;; 16k) unset TOPAZ_4K ;; *) echo "PAGES must be 4k or 16k" >&2; exit 1 ;; esac
T0=$(date +%s)
echo "kernel-ios26: $XNU_TAG SWEET $KERNEL_CONFIG PAGES=$PAGES jobs=$JOBS"; df -h "$W" | tail -1

get_sdk() {
  local t=$W/dl/MacOSX$SDK_VER.sdk.tar.xz
  [ -f "$t" ] || { curl -fsSL --retry 5 -o "$t.part" "https://github.com/joseluisq/macosx-sdks/releases/download/$SDK_VER/MacOSX$SDK_VER.sdk.tar.xz" && mv "$t.part" "$t"; }
  echo "$SDK_SHA256  $t" | sha256sum -c - >/dev/null || { echo "kernel-ios26: SDK checksum changed" >&2; return 1; }
  [ -d "$MACOS_SDK/usr/include" ] || tar -xJf "$t" -C "$DEPS"
}
get_theos() {
  [ -x "$THEOS/toolchain/linux/iphone/bin/ld" ] && return 0
  local have=$MAIN/out/laurel-kernel/theos
  if [ -x "$have/toolchain/linux/iphone/bin/ld" ]; then ln -sfn "$have" "$THEOS"; return 0; fi
  rm -rf "$THEOS"; git init -q "$THEOS"
  git -C "$THEOS" fetch -q --depth 1 https://github.com/theos/theos.git "$THEOS_SHA"; git -C "$THEOS" checkout -q FETCH_HEAD
  mkdir -p "$THEOS/toolchain"; local tc=$W/dl/iOSToolchain-x86_64.tar.xz
  [ -f "$tc" ] || { curl -fsSL --retry 5 -o "$tc.part" "$TOOLCHAIN_URL" && mv "$tc.part" "$tc"; }
  echo "$TOOLCHAIN_SHA256  $tc" | sha256sum -c - || return 1
  tar -xJf "$tc" -C "$THEOS/toolchain/"
}
get_kdk() {
  [ -f "$KDKROOT/.kdk-headers" ] && return 0
  local d=$W/dl/Kernel_Debug_Kit_26.5.2_build_25F84.dmg
  [ -f "$d" ] || { curl -fsSL --retry 5 -o "$d.part" "$KDK_URL" && mv "$d.part" "$d"; }
  echo "$KDK_SHA256  $d" | sha256sum -c - >/dev/null || { echo "kernel-ios26: KDK checksum changed" >&2; return 1; }
  python3 -I "$REPO/scripts/ios26/kdk-headers.py" --dmg "$d" "$KDKROOT"
}
get_sdk; get_theos; get_kdk
mkdir -p "$LOGD"

if [ "${INCR:-0}" != 1 ]; then
  "$REPO/scripts/laurel/ios26-series-tree.sh" --dev || { grep ERROR "$W/series-report.txt" | cut -c1-200 >&2; exit 1; }
  tail -1 "$W/series-report.txt"
  [ "${STAGE:-}" = tree ] && exit 0
fi
# Linux build adjustments, as ios-sweet-linux apply-xnu.sh (idempotent)
sed -i -e 's|XCRUN = /usr/bin/xcrun|XCRUN = xcrun|' -e 's|HOST_CODESIGN\([[:space:]]*\):=[[:space:]]*/usr/bin/codesign|HOST_CODESIGN\1:= codesign|' \
  -e 's|PLUTIL = /usr/bin/plutil|PLUTIL = plutil|' "$XNU_SRC/makedefs/MakeInc.cmd"
sed -i 's|^#!/bin/csh -f$|#!/usr/bin/env -S csh -f|' "$XNU_SRC/SETUP/config/doconf"
# stage 1 of setup-deps: mig, unifdef, tcsh, the SDK overlay; libplatform and firehose headers for 12377
export PATCHES_DIR=$W/patches; mkdir -p "$PATCHES_DIR"
# laurel 2912: what this run built (docs/laurel_sprout/build-honest.md). A copy of the sources: a later edit shows at the check.
export LAUREL_STAMP_IOS26=1
BS=$REPO/scripts/laurel/build-stamp.py
rm -f "$PATCHES_DIR"/*
python3 -I - "$BS" "$PATCHES_DIR" <<'PY'
import importlib.util, shutil, sys
s = importlib.util.spec_from_file_location('bs', sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
for n, p in m.ios26_files().items():
    shutil.copy2(p, sys.argv[2] + '/' + n)
PY
STAMP=$(python3 -I "$BS" kernel-stamp "$W" "ios26_$PAGES")
echo "kernel-ios26: this build: LAUREL BUILD: $STAMP"
python3 -I "$BS" kernel-header "$STAMP" > "$XNU_SRC/bsd/dev/laurel_build_stamp.h"
bash "$W/linux/setup-deps.sh" --stage1 > "$LOGD/stage1.log" 2>&1 || { tail -20 "$LOGD/stage1.log"; exit 1; }
. "$REPO/scripts/laurel/ios26-sdk-overlay.sh"
echo "kernel-ios26: setup done $(( $(date +%s) - T0 )) s"
# stage 2: libfirehose_kernel.a for cortex-a53; it needs the exported headers
bash "$W/linux/setup-deps.sh" --stage2 > "$LOGD/stage2.log" 2>&1 || { tail -20 "$LOGD/stage2.log"; exit 1; }
rm -f "$W/build.log"
build_rc=0
bash "$W/linux/build-with-iig.sh" > "$LOGD/kernel-make.log" 2>&1 || build_rc=$?
K=$XNU_SRC/BUILD/obj/${KERNEL_CONFIG}_ARM64_SWEET/kernel.development.sweet
if [ "$build_rc" != 0 ] || [ ! -s "$K" ]; then
  echo "kernel-ios26: FAILED: build-with-iig.sh exit $build_rc" >&2
  grep -n -m 60 -E "error:|Undefined symbols|symbol\(s\) not found|No rule to make" "$W/build.log" >&2 || true
  exit 1
fi
. "$REPO/scripts/laurel/ios26-kernel-check.sh"
