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
# IOS26=1: the iOS 26.5.2 23F84 copy: -DLF_IOS26, a dylib (dyld inserts only dylibs) that laurel-cameracaptured (cc_wrap.c, also built here) inserts into cameracaptured.
#          Output: out/ios26/flashlight/LaurelFlashlight.driver/{LaurelFlashlight,Info.plist}, out/ios26/flashlight/laurel-cameracaptured. Its Info.plist names no plug-in type: audiomxd's HAL does not load it.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
OUT=$REPO/out/laurel/flashlight
KIND=-bundle
DEFS=
if [ "${IOS26:-0}" = 1 ]; then
  OUT=$REPO/out/ios26/flashlight
  KIND="-dynamiclib -install_name /System/Library/Audio/Plug-Ins/HAL/LaurelFlashlight.driver/LaurelFlashlight"
  DEFS=-DLF_IOS26=1
fi
B=$OUT/LaurelFlashlight.driver
W=$OUT/build
MINOS=16.0
CFLAGS="-O2 -Wall -Wno-unused-parameter $DEFS"
rm -rf "$B" "$W"
mkdir -p "$B" "$W"

if [ "$(uname -s)" = Darwin ] && xcrun -sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
  SDK=$(xcrun -sdk iphoneos --show-sdk-path)
  CC=$(xcrun -sdk iphoneos --find clang)
  "$CC" -arch arm64 -isysroot "$SDK" -mios-version-min=$MINOS $CFLAGS $KIND -framework CoreFoundation -lobjc \
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
  "$TC/clang" -target arm64-apple-ios$MINOS -fuse-ld="$TC/ld" -B"$TC" -isysroot "$R" -nostdlib $KIND \
    -lSystem -lobjc -framework CoreFoundation -Wl,-exported_symbol,_LaurelFlashlight_Create "$W/laurel_flashlight.o" \
    -o "$B/LaurelFlashlight"
  NM="$TC/llvm-nm"; OTOOL="$TC/otool"
  sign() { "$TC/ldid" -S "$1"; }
fi
if [ "${IOS26:-0}" = 1 ]; then
  sed -e '/<key>CFPlugInTypes<\/key>/,/<\/dict>/d' -e '/<key>CFPlugInFactories<\/key>/,/<\/dict>/d' "$HERE/Info.plist" > "$B/Info.plist"
  python3 -I -c 'import plistlib,sys; d=plistlib.load(open(sys.argv[1],"rb")); sys.exit("Info.plist still names a plug-in type" if "CFPlugInTypes" in d or "CFPlugInFactories" in d else 0)' "$B/Info.plist"
else
  cp "$HERE/Info.plist" "$B/Info.plist"
fi

# checks: arm64 Mach-O bundle (dylib: IOS26=1), minos 16.0, the factory is the only export, only libSystem + libobjc + CoreFoundation
fail=0
want='Mach-O 64-bit arm64 bundle'; [ "${IOS26:-0}" != 1 ] || want='dynamically linked shared library'
file "$B/LaurelFlashlight" | grep -q "$want" || { echo "flashlight: not: $want" >&2; fail=1; }
minos=$($OTOOL -l "$B/LaurelFlashlight" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')
[ "$minos" = "$MINOS" ] || { echo "flashlight: minos $minos, expected $MINOS" >&2; fail=1; }
exports=$($NM -gU "$B/LaurelFlashlight" | awk '{print $NF}' | grep -v -x -e _LaurelFlashlight_Create -e __mh_bundle_header -e __mh_dylib_header || true)
$NM -gU "$B/LaurelFlashlight" | grep -q ' _LaurelFlashlight_Create$' || { echo "flashlight: _LaurelFlashlight_Create not exported" >&2; fail=1; }
[ -z "$exports" ] || { echo "flashlight: unexpected exports: $exports" >&2; fail=1; }
libs=$($OTOOL -L "$B/LaurelFlashlight" | tail -n +2 | awk '{print $1}' | grep -v LaurelFlashlight.driver | LC_ALL=C sort | tr '\n' ' ')
[ "$libs" = "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation /usr/lib/libSystem.B.dylib /usr/lib/libobjc.A.dylib " ] ||
  { echo "flashlight: unexpected libraries: $libs" >&2; fail=1; }
[ $fail = 0 ] || exit 1
# loaded by mediaserverd: ad hoc signature, no entitlements
sign "$B/LaurelFlashlight"
rm -rf "$W"
# the start program of the job com.apple.cameracaptured: libSystem only
if [ "${IOS26:-0}" = 1 ]; then
  mkdir -p "$W/sysroot/usr/lib"
  if [ "$(uname -s)" = Darwin ] && xcrun -sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
    "$CC" -arch arm64 -isysroot "$SDK" -mios-version-min=$MINOS -O2 -Wall -Wextra "$HERE/cc_wrap.c" -o "$OUT/laurel-cameracaptured"
  else
    "$TC/clang" -target arm64-apple-ios$MINOS -isysroot "$SDK" -Wno-incompatible-sysroot -O2 -Wall -Wextra -c "$HERE/cc_wrap.c" -o "$W/cc_wrap.o"
    syms=$("$TC/llvm-nm" -u "$W/cc_wrap.o" | awk '{print $NF}' | paste -sd, - | sed 's/,/, /g')
    tbd "$W/sysroot/usr/lib/libSystem.tbd" /usr/lib/libSystem.B.dylib 1311 1 "dyld_stub_binder, $syms"
    (cd "$OUT" && "$TC/clang" -target arm64-apple-ios$MINOS -fuse-ld="$TC/ld" -B"$TC" -isysroot "$W/sysroot" -nostdlib -lSystem "$W/cc_wrap.o" -o laurel-cameracaptured)
  fi
  file "$OUT/laurel-cameracaptured" | grep -q 'Mach-O 64-bit arm64 executable' || { echo "flashlight: laurel-cameracaptured is not an arm64 executable" >&2; exit 1; }
  sign "$OUT/laurel-cameracaptured"
  rm -rf "$W"
fi
(cd "$OUT" && { sha256sum LaurelFlashlight.driver/LaurelFlashlight LaurelFlashlight.driver/Info.plist 2>/dev/null ||
  shasum -a 256 LaurelFlashlight.driver/LaurelFlashlight LaurelFlashlight.driver/Info.plist; } > SHA256SUMS)
echo "flashlight: $B ($(wc -c < "$B/LaurelFlashlight") bytes, minos $minos)"
cat "$OUT/SHA256SUMS"
