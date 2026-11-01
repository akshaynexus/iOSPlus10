#!/bin/bash
# Build RedwoodAudio.driver (the CoreAudio HAL plug-in of ios-topaz/HackiOS,
# external/ios-topaz/userland/audio/audio_plugin.c + userland/laurel/audio/mic-input.patch) for the Mi A3 iOS 16
# root. It presents the "Speaker" (+ "Hawking", "Actuator", "Codec") devices that VirtualAudio routes through, writes
# the speaker's frames to /dev/redwood-audio (kernel: patches/laurel/xnu/2500, 48 kHz S16 stereo) and reads the "Codec"
# input from /dev/redwood-mic (kernel: patches/laurel/xnu/2920, 48 kHz S16 mono). Host test: scripts/laurel/mic-host-test.sh.
#   userland/laurel/audio/build.sh          (a few seconds; no tmux needed)
# Linux: the theos iPhone toolchain (clang 11, ld64-609, ldid) and MacOSX13.3.sdk headers that
#        scripts/laurel/kernel-linux.sh downloads into out/laurel-kernel/{theos,deps}; the link uses
#        text stubs (.tbd) of libSystem and CoreFoundation made from the object's undefined symbols.
# macOS: Xcode's iPhoneOS SDK + codesign.
# Output: out/laurel/audio/RedwoodAudio.driver/{RedwoodAudio,Info.plist} (arm64, minos 16.0, ad hoc
#         signed, one export: _RedwoodAudio_Create) + out/laurel/audio/SHA256SUMS.
# Install into a root: scripts/laurel/root-audio.sh (root.sh calls it).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
SRC=$REPO/external/ios-topaz/userland/audio
OUT=$REPO/out/laurel/audio
B=$OUT/RedwoodAudio.driver
W=$OUT/build
MINOS=16.0
CFLAGS="-O2 -Wall -Wno-four-char-constants -Wno-multichar"
[ -f "$SRC/audio_plugin.c" ] || { echo "audio: missing $SRC (git submodule / scripts/setup/get-references.sh ios-topaz)" >&2; exit 1; }
rm -rf "$B" "$W"
mkdir -p "$B" "$W/src"
# our change to the external source goes in as a patch on a copy (CLAUDE.md: nothing is committed inside external/)
cp "$SRC/audio_plugin.c" "$SRC/redwood_audio.h" "$W/src/"
(cd "$W/src" && patch -s -p1 < "$HERE/mic-input.patch") || { echo "audio: mic-input.patch does not apply" >&2; exit 1; }

if [ "$(uname -s)" = Darwin ] && xcrun -sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
  SDK=$(xcrun -sdk iphoneos --show-sdk-path)
  CC=$(xcrun -sdk iphoneos --find clang)
  "$CC" -arch arm64 -isysroot "$SDK" -mios-version-min=$MINOS $CFLAGS -bundle -framework CoreFoundation \
    -Wl,-exported_symbol,_RedwoodAudio_Create "$W/src/audio_plugin.c" -o "$B/RedwoodAudio"
  NM="xcrun nm"; OTOOL="xcrun otool"
  sign() { codesign --force -s - "$1"; }
else
  TC=$REPO/out/laurel-kernel/theos/toolchain/linux/iphone/bin
  SDK=$REPO/out/laurel-kernel/deps/MacOSX13.3.sdk
  for f in "$TC/clang" "$TC/ld" "$TC/ldid" "$TC/llvm-nm" "$SDK/System/Library/Frameworks/CoreFoundation.framework/Headers/CoreFoundation.h"; do
    [ -e "$f" ] || { echo "audio: missing $f (run scripts/laurel/kernel-linux.sh once: it fetches theos + the SDK)" >&2; exit 1; }
  done
  # headers: the macOS SDK's (CoreFoundation, CoreAudioTypes, libc); the target is iOS 16 arm64
  "$TC/clang" -target arm64-apple-ios$MINOS -isysroot "$SDK" -Wno-incompatible-sysroot $CFLAGS \
    -c "$W/src/audio_plugin.c" -o "$W/audio_plugin.o"
  # link: .tbd stubs with exactly the symbols the object needs (two-level namespace, real install names)
  R=$W/sysroot
  mkdir -p "$R/usr/lib" "$R/System/Library/Frameworks/CoreFoundation.framework"
  syms=$("$TC/llvm-nm" -u "$W/audio_plugin.o" | awk '{print $NF}')
  cf=$(printf '%s\n' "$syms" | grep -E '^_(CF|kCF)|^___CFConstantStringClassReference$' | paste -sd, - | sed 's/,/, /g')
  sys=$(printf '%s\n' "$syms" | grep -v -E '^_(CF|kCF)|^___CFConstantStringClassReference$' | paste -sd, - | sed 's/,/, /g')
  tbd() {   # FILE INSTALL_NAME CURRENT COMPAT SYMBOLS
    printf -- '--- !tapi-tbd-v3\narchs: [ arm64 ]\nplatform: ios\ninstall-name: %s\ncurrent-version: %s\ncompatibility-version: %s\nexports:\n  - archs: [ arm64 ]\n    symbols: [ %s ]\n...\n' \
      "$2" "$3" "$4" "$5" > "$1"
  }
  tbd "$R/usr/lib/libSystem.tbd" /usr/lib/libSystem.B.dylib 1311 1 "dyld_stub_binder, $sys"
  tbd "$R/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation.tbd" \
    /System/Library/Frameworks/CoreFoundation.framework/CoreFoundation 1953.255 150 "$cf"
  "$TC/clang" -target arm64-apple-ios$MINOS -fuse-ld="$TC/ld" -B"$TC" -isysroot "$R" -nostdlib -bundle \
    -lSystem -framework CoreFoundation -Wl,-exported_symbol,_RedwoodAudio_Create "$W/audio_plugin.o" -o "$B/RedwoodAudio"
  NM="$TC/llvm-nm"; OTOOL="$TC/otool"
  sign() { "$TC/ldid" -S "$1"; }
fi
cp "$SRC/audio_plugin.plist" "$B/Info.plist"

# checks: arm64 Mach-O bundle, minos 16.0, the factory is the only export, only libSystem + CoreFoundation
fail=0
file "$B/RedwoodAudio" | grep -q 'Mach-O 64-bit arm64 bundle' || { echo "audio: not an arm64 bundle" >&2; fail=1; }
minos=$($OTOOL -l "$B/RedwoodAudio" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')
[ "$minos" = "$MINOS" ] || { echo "audio: minos $minos, expected $MINOS" >&2; fail=1; }
exports=$($NM -gU "$B/RedwoodAudio" | awk '{print $NF}' | grep -v -x -e _RedwoodAudio_Create -e __mh_bundle_header || true)
$NM -gU "$B/RedwoodAudio" | grep -q ' _RedwoodAudio_Create$' || { echo "audio: _RedwoodAudio_Create not exported" >&2; fail=1; }
[ -z "$exports" ] || { echo "audio: unexpected exports: $exports" >&2; fail=1; }
libs=$($OTOOL -L "$B/RedwoodAudio" | tail -n +2 | awk '{print $1}' | sort | tr '\n' ' ')
[ "$libs" = "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation /usr/lib/libSystem.B.dylib " ] ||
  { echo "audio: unexpected libraries: $libs" >&2; fail=1; }
[ $fail = 0 ] || exit 1
# loaded by mediaserverd: ad hoc signature, no entitlements
sign "$B/RedwoodAudio"
rm -rf "$W"
(cd "$OUT" && { sha256sum RedwoodAudio.driver/RedwoodAudio RedwoodAudio.driver/Info.plist 2>/dev/null ||
  shasum -a 256 RedwoodAudio.driver/RedwoodAudio RedwoodAudio.driver/Info.plist; } > SHA256SUMS)
echo "audio: $B ($(wc -c < "$B/RedwoodAudio") bytes, minos $minos)"
cat "$OUT/SHA256SUMS"
