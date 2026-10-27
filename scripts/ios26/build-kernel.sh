#!/bin/bash
# Build the iOS 26 kernel (xnu-12377.121.6, NEGRONI) locally on macOS with darwin-xnu-build (dxb).
# The iOS 16 recipe (scripts/kernel/build-local.sh, xnu-8796, Xcode 15.4) is not touched: this one
# has its own tree out/kernel/local-ios26/ and uses Xcode 27.1 (/Applications/Xcode.app).
#
#   scripts/bg.sh ios26-kernel scripts/ios26/build-kernel.sh          (full build, in tmux)
#   STAGE=prepare scripts/ios26/build-kernel.sh                         (clone + patch only, no build)
#   CLEAN=1 ...                                                         (fresh dxb tree)
#
# Inputs:
#   - xnu tag xnu-12377.121.6 (macOS 26.5; donor userland iOS 26.5.2 23F84, kernel 12377.122.8)
#   - dxb pin DXB_SHA (same pin as iOS 16; knows MACOS_VERSION=26.5 and its patches/26.0 set)
#   - headers-only KDKROOT from scripts/ios26/kdk-headers.py (KDK 26.5.2 25F84, about 200 headers,
#     read over HTTP; no 1.2 GB download). NEGRONI links no KDK archive.
#   - patches/xnu-12377/*.patch (our iOS 26 series), copied into dxb/patches/26.0 as zz-<name>
#     so they apply after dxb's own 26.0 patches.
# Output: out/kernel/local-ios26-<UTC>/kernel.<config>.negroni + patch-report.txt + SHA256SUMS
#         (link out/kernel/kernel-ios26.macho). The iOS 16 link out/kernel/kernel.macho stays.
# Env: KERNEL_CONFIG (DEVELOPMENT), XCODE_APP (/Applications/Xcode.app), KDKROOT, STAGE (build|prepare),
#      ARCH_STRING (arm64 = stage 1, plain arm64; arm64e = stage 2, after the PAC patches exist).
set -euo pipefail
. "$(dirname "$0")/../lib/env.sh"
DXB_SHA=663906528d1cd5ea8fde7de6f16de73db9511549
XNU_TAG=xnu-12377.121.6
APP=${XCODE_APP:-/Applications/Xcode.app}
KDKROOT=${KDKROOT:-$OUT/kernel/kdk-25F84-headers}
STAGE=${STAGE:-build}
ARCH_STRING=${ARCH_STRING:-arm64}
W=$OUT/kernel/local-ios26
[ -d "$APP" ] || { echo "missing $APP (Xcode 26 or newer)" >&2; exit 1; }
for t in jq gum cmake ninja; do command -v $t >/dev/null || brew install $t; done
if [ ! -f "$KDKROOT/.kdk-headers" ]; then
  echo "== KDK headers -> $KDKROOT"
  python3 -I "$REPO/scripts/ios26/kdk-headers.py" "$KDKROOT"
fi

mkdir -p "$OUT/kernel"
L=$OUT/kernel/local-ios26.lock
until mkdir "$L" 2>/dev/null; do
  pid=$(cat "$L/pid" 2>/dev/null || true)
  if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then rm -rf "${L:?}"; continue; fi
  echo "waiting for the running iOS 26 kernel build (pid ${pid:-?}) ..."; sleep 10
done
echo $$ > "$L/pid"
trap 'rm -rf "${L:?}"' EXIT
[ "${CLEAN:-0}" = 1 ] && rm -rf "${W:?}/dxb"
mkdir -p "$W/bin"
printf '#!/bin/sh\nexit 0\n' > "$W/bin/xcodes"; chmod +x "$W/bin/xcodes"
if [ ! -d "$W/dxb/.git" ]; then
  git init -q "$W/dxb"
  git -C "$W/dxb" fetch -q --depth 1 https://github.com/blacktop/darwin-xnu-build "$DXB_SHA"
  git -C "$W/dxb" checkout -q FETCH_HEAD
  # libfirehose_kernel: dxb builds x86_64+arm64e; stage 1 (plain arm64 kernel) needs arm64 too
  sed -i '' 's/ARCHS="x86_64 arm64e" VALID_ARCHS="x86_64 arm64e"/ARCHS="x86_64 arm64e arm64" VALID_ARCHS="x86_64 arm64e arm64"/' "$W/dxb/build.sh"
fi
# our series, after dxb's own 26.0 patches (glob order: digits < letters < "zz-")
P=$W/dxb/patches/26.0
git -C "$W/dxb" checkout -q -- patches
rm -f "$P"/zz-*
for f in "$REPO"/patches/xnu-12377/*.patch "$REPO"/patches/xnu-12377/*.sh; do
  [ -e "$f" ] && cp "$f" "$P/zz-$(basename "$f")"
done
echo "patches/xnu-12377: $(ls "$REPO"/patches/xnu-12377/*.patch 2>/dev/null | wc -l | tr -d ' ') patches"

[ -d "$W/xnu-pristine/.git" ] || git clone -q --depth 1 --branch "$XNU_TAG" https://github.com/apple-oss-distributions/xnu.git "$W/xnu-pristine"
rm -rf "${W:?}/dxb/xnu" "${W:?}/dxb/build/xnu.obj" "${W:?}/dxb/build/xnu.sym"
cp -R "$W/xnu-pristine" "$W/dxb/xnu"

export PATH="$W/bin:$PATH" DEVELOPER_DIR="$APP/Contents/Developer"
export MACOS_VERSION=26.5 KERNEL_CONFIG=${KERNEL_CONFIG:-DEVELOPMENT} MACHINE_CONFIG=NEGRONI KDKROOT
xcodebuild -version
if [ "$STAGE" = prepare ]; then
  # only dxb's patch step: source the functions without main
  cd "$W/dxb"
  sed 's/^main "\$@"$//' build.sh > .build-functions.sh     # bash 3.2: no "source <(...)"
  bash -c 'set -euo pipefail; . ./.build-functions.sh; setup_xcode_toolchain; choose_xnu; get_xnu; patches' 2>&1 | tee "$W/prepare.log"
  grep -E "Applying patch|Skipping patch" "$W/prepare.log" | sed -E 's#.*(Applying|Skipping) patch:? .*/patches/26.0/#\1 #' > "$W/patch-report.txt" || true
  echo "prepared $W/dxb/xnu"; grep "^Skipping" "$W/patch-report.txt" || echo "skipped: none"
  exit 0
fi
cd "$W/dxb"
# MakeInc.def turns arm64 into arm64e; our NEGRONI patch keeps plain arm64 unless NEGRONI_ARM64E=1
# (stage 2, after the native PAC patches). make reads the variable from the environment.
[ "$ARCH_STRING" = arm64e ] && export NEGRONI_ARM64E=1
# Xcode 27.1 clang warns on every kernel header (-Wreserved-identifier ...): without this list the log grows to
# GBs (disk). make takes CFLAGS_EXTRA from the environment (MakeInc.def: ifeq ($(CFLAGS_EXTRA),)).
export CFLAGS_EXTRA="-Wno-reserved-identifier -Wno-pre-c11-compat -Wno-missing-designated-field-initializers -Wno-suggest-override -Wno-unnecessary-virtual-specifier -Wno-suggest-destructor-override -Wno-ms-bitfield-padding"
bash build.sh 2>&1 | tee "$W/build.log"
D=$OUT/kernel/local-ios26-$(date -u +%Y%m%d-%H%M%S)
mkdir -p "$D"
find fakeroot/System/Library/Kernels -maxdepth 1 -type f -name "kernel.*negroni*" -exec cp {} "$D/" \;
grep -E "Applying patch|Skipping patch" "$W/build.log" | sed -E 's#.*(Applying|Skipping) patch:? .*/patches/26.0/#\1 #' > "$D/patch-report.txt" || true
(cd "$D" && shasum -a 256 kernel.* > SHA256SUMS)
ln -sfn "$(basename "$D")/kernel.$(echo "$KERNEL_CONFIG" | tr '[:upper:]' '[:lower:]').negroni" "$OUT/kernel/kernel-ios26.macho"
echo "skipped patches:"; grep "^Skipping" "$D/patch-report.txt" || echo "  none"
if grep -qE "^Skipping zz-" "$D/patch-report.txt"; then echo "ERROR: a patches/xnu-12377 patch did not apply (above)" >&2; exit 1; fi
"$REPO/scripts/lib/notify.sh" "iOS 26 kernel build done: $D" || true
ls -l "$D"
file "$D"/kernel.*
