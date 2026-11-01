#!/bin/bash
# Build LaurelFlashlight.driver (the mediaserverd side of the Mi A3 torch: userland/laurel/flashlight/README.md;
# kernel side patches/laurel/xnu/2781, /dev/laureltorch).
#   userland/laurel/flashlight/build.sh          (a few seconds; no tmux needed)
# Linux: the theos iPhone toolchain (clang, ld64, ldid) and MacOSX13.3.sdk headers that scripts/laurel/kernel-linux.sh
#        downloads into out/laurel-kernel/{theos,deps}; the link uses text stubs (.tbd) of libSystem, libobjc and
#        CoreFoundation made from the object's undefined symbols (as userland/laurel/audio/build.sh).
# macOS: Xcode's iPhoneOS SDK + codesign.
# Output: out/laurel/flashlight/LaurelFlashlight.driver/{LaurelFlashlight,Info.plist} (arm64, minos 16.0, ad hoc signed,
#         one export: _LaurelFlashlight_Create) + out/laurel/flashlight/SHA256SUMS.
# Install into a root: scripts/laurel/root-flashlight.sh (root.sh calls it; TORCH=0 skips).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
OUT=$REPO/out/laurel/flashlight
B=$OUT/LaurelFlashlight.driver
W=$OUT/build
MINOS=16.0
CFLAGS="-O2 -Wall -Wno-unused-parameter"
rm -rf "$B" "$W"
mkdir -p "$B" "$W"

if [ "$(uname -s)" = Darwin ] && xcrun -sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
  SDK=$(xcrun -sdk iphoneos --show-sdk-path)
  CC=$(xcrun -sdk iphoneos --find clang)
  "$CC" -arch arm64 -isysroot "$SDK" -mios-version-min=$MINOS $CFLAGS -bundle -framework CoreFoundation -lobjc \
    -Wl,-exported_symbol,_LaurelFlashlight_Create "$HERE/laurel_flashlight.c" -o "$B/LaurelFlashlight"
  NM="xcrun nm"; OTOOL="xcrun otool"
  sign() { codesign --force -s - "$1"; }
else
  TC=$REPO/out/laurel-kernel/theos/toolchain/linux/iphone/bin
  SDK=$REPO/out/laurel-kernel/deps/MacOSX13.3.sdk
  for f in "$TC/clang" "$TC/ld" "$TC/ldid" "$TC/llvm-nm" "$SDK/System/Library/Frameworks/CoreFoundation.framework/Headers/CoreFoundation.h" \
           "$SDK/usr/include/objc/runtime.h"; do
    [ -e "$f" ] || { echo "flashlight: missing $f (run scripts/laurel/kernel-linux.sh once: it fetches theos + the SDK)" >&2; exit 1; }
  done
  # headers: the macOS SDK's (CoreFoundation, objc, dispatch, os_log, libc); the target is iOS 16 arm64
  "$TC/clang" -target arm64-apple-ios$MINOS -isysroot "$SDK" -Wno-incompatible-sysroot $CFLAGS \
    -c "$HERE/laurel_flashlight.c" -o "$W/laurel_flashlight.o"
  R=$W/sysroot
  mkdir -p "$R/usr/lib" "$R/System/Library/Frameworks/CoreFoundation.framework"
  syms=$("$TC/llvm-nm" -u "$W/laurel_flashlight.o" | awk '{print $NF}')
  pick() { printf '%s\n' "$syms" | grep -E "$1" | paste -sd, - | sed 's/,/, /g'; }
  cfre='^_(CF|kCF)|^___CFConstantStringClassReference$'
  objre='^_(objc_|class_|object_|sel_|method_)'
  cf=$(pick "$cfre")
  objc=$(pick "$objre")
  sys=$(printf '%s\n' "$syms" | grep -v -E "$cfre|$objre" | paste -sd, - | sed 's/,/, /g')
  tbd() {   # FILE INSTALL_NAME CURRENT COMPAT SYMBOLS
    printf -- '--- !tapi-tbd-v3\narchs: [ arm64 ]\nplatform: ios\ninstall-name: %s\ncurrent-version: %s\ncompatibility-version: %s\nexports:\n  - archs: [ arm64 ]\n    symbols: [ %s ]\n...\n' \
      "$2" "$3" "$4" "$5" > "$1"
  }
  tbd "$R/usr/lib/libSystem.tbd" /usr/lib/libSystem.B.dylib 1311 1 "dyld_stub_binder, $sys"
  tbd "$R/usr/lib/libobjc.tbd" /usr/lib/libobjc.A.dylib 228 1 "$objc"
  tbd "$R/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation.tbd" \
    /System/Library/Frameworks/CoreFoundation.framework/CoreFoundation 1953.255 150 "$cf"
  "$TC/clang" -target arm64-apple-ios$MINOS -fuse-ld="$TC/ld" -B"$TC" -isysroot "$R" -nostdlib -bundle \
    -lSystem -lobjc -framework CoreFoundation -Wl,-exported_symbol,_LaurelFlashlight_Create "$W/laurel_flashlight.o" \
    -o "$B/LaurelFlashlight"
  NM="$TC/llvm-nm"; OTOOL="$TC/otool"
  sign() { "$TC/ldid" -S "$1"; }
fi
cp "$HERE/Info.plist" "$B/Info.plist"

# checks: arm64 Mach-O bundle, minos 16.0, the factory is the only export, only libSystem + libobjc + CoreFoundation
fail=0
file "$B/LaurelFlashlight" | grep -q 'Mach-O 64-bit arm64 bundle' || { echo "flashlight: not an arm64 bundle" >&2; fail=1; }
minos=$($OTOOL -l "$B/LaurelFlashlight" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')
[ "$minos" = "$MINOS" ] || { echo "flashlight: minos $minos, expected $MINOS" >&2; fail=1; }
exports=$($NM -gU "$B/LaurelFlashlight" | awk '{print $NF}' | grep -v -x -e _LaurelFlashlight_Create -e __mh_bundle_header || true)
$NM -gU "$B/LaurelFlashlight" | grep -q ' _LaurelFlashlight_Create$' || { echo "flashlight: _LaurelFlashlight_Create not exported" >&2; fail=1; }
[ -z "$exports" ] || { echo "flashlight: unexpected exports: $exports" >&2; fail=1; }
libs=$($OTOOL -L "$B/LaurelFlashlight" | tail -n +2 | awk '{print $1}' | LC_ALL=C sort | tr '\n' ' ')
[ "$libs" = "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation /usr/lib/libSystem.B.dylib /usr/lib/libobjc.A.dylib " ] ||
  { echo "flashlight: unexpected libraries: $libs" >&2; fail=1; }
[ $fail = 0 ] || exit 1
# loaded by mediaserverd: ad hoc signature, no entitlements
sign "$B/LaurelFlashlight"
rm -rf "$W"
(cd "$OUT" && { sha256sum LaurelFlashlight.driver/LaurelFlashlight LaurelFlashlight.driver/Info.plist 2>/dev/null ||
  shasum -a 256 LaurelFlashlight.driver/LaurelFlashlight LaurelFlashlight.driver/Info.plist; } > SHA256SUMS)
echo "flashlight: $B ($(wc -c < "$B/LaurelFlashlight") bytes, minos $minos)"
cat "$OUT/SHA256SUMS"
