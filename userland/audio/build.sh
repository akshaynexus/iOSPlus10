#!/bin/sh
# Build NegroniAudio.driver, the CoreAudio HAL plug-in for iOS 16 (docs/audio-plan.md stage 0/d).
# macOS + Xcode only (needs the iPhoneOS SDK and codesign); scripts/audio/root-add-audio.sh then
# installs the result on macOS or Linux.
#   userland/audio/build.sh            (a few seconds; no tmux needed)
# Output:
#   out/audio/ios/NegroniAudio.driver/{NegroniAudio,Info.plist}   arm64, minos 16.0, ad hoc signed
#   out/audio/ios/SHA256SUMS
#   out/audio/host/                    macOS build + test-host (property table and I/O checks)
# Same toolchain rules as userland/ssh/build.sh: no weak imports (symbols newer than iOS 16).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
W=$REPO/out/audio
MINOS=16.0
[ "$(uname -s)" = Darwin ] || { echo "build.sh needs macOS with Xcode (iPhoneOS SDK)" >&2; exit 1; }

SDK=$(xcrun -sdk iphoneos --show-sdk-path)
ICC=$(xcrun -sdk iphoneos --find clang)
CFLAGS="-O2 -Wall -Wextra -Wno-unused-parameter -Wno-four-char-constants -Wno-multichar -fvisibility=hidden"
rm -rf "$W/ios" "$W/host"
B=$W/ios/NegroniAudio.driver
mkdir -p "$B" "$W/host"

"$ICC" -arch arm64 -isysroot "$SDK" -mios-version-min=$MINOS $CFLAGS -bundle -framework CoreFoundation \
  "$HERE/NegroniAudio.c" -o "$B/NegroniAudio"
cp "$HERE/Info.plist" "$B/Info.plist"
plutil -lint "$B/Info.plist" >/dev/null

# checks: arm64 only, minos 16.0, no weak imports, the factory is exported
fail=0
lipo -archs "$B/NegroniAudio" | grep -qx arm64 || { echo "not arm64-only" >&2; fail=1; }
minos=$(otool -l "$B/NegroniAudio" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')
[ "$minos" = "$MINOS" ] || { echo "minos $minos, expected $MINOS" >&2; fail=1; }
weak=$(nm -m "$B/NegroniAudio" | grep 'weak external' || true)
[ -z "$weak" ] || { echo "weak imports:" >&2; echo "$weak" >&2; fail=1; }
nm -gU "$B/NegroniAudio" | grep -q ' _NegroniAudio_Create$' || { echo "factory NegroniAudio_Create not exported" >&2; fail=1; }
exported=$(nm -gU "$B/NegroniAudio" | awk '{print $3}' | grep -v -x -e _NegroniAudio_Create -e __mh_bundle_header || true)
[ -z "$exported" ] || { echo "unexpected exports: $exported" >&2; fail=1; }
[ $fail = 0 ] || exit 1
# A bundle loaded by mediaserverd: ad hoc signature, no entitlements (the process has its own).
# The negroni AMFI stand-in treats signed files on the root as platform code (patch 0221).
codesign --force -s - "$B"
codesign -v "$B"
(cd "$W/ios" && shasum -a 256 NegroniAudio.driver/NegroniAudio NegroniAudio.driver/Info.plist > SHA256SUMS)

# interface check: our AudioServerPlugIn.h against the macOS SDK header (same sizes and offsets)
clang -Wall -DREAL_SDK "$HERE/layout-check.c" -o "$W/host/layout-real"
clang -Wall -Wno-four-char-constants -Wno-multichar -I"$HERE" "$HERE/layout-check.c" -o "$W/host/layout-ours"
"$W/host/layout-real" > "$W/host/layout-real.txt"
"$W/host/layout-ours" > "$W/host/layout-ours.txt"
if ! diff "$W/host/layout-real.txt" "$W/host/layout-ours.txt" >&2; then
  echo "AudioServerPlugIn.h differs from the macOS SDK header (above)" >&2; exit 1
fi
echo "AudioServerPlugIn.h: $(wc -l < "$W/host/layout-ours.txt" | tr -d ' ') sizes/offsets/values match the macOS SDK"

# host test: the same source for macOS, loaded by a small HAL stand-in
# NEGRONI_AUDIO_HOST_TEST: the device path from $NEGRONI_AUDIO_TEST_PATH (a FIFO) + a stats hook; never in the iOS build
clang $CFLAGS -DNEGRONI_AUDIO_HOST_TEST -bundle -framework CoreFoundation "$HERE/NegroniAudio.c" -o "$W/host/NegroniAudio"
clang -O1 -Wall -framework CoreFoundation "$HERE/test-host.c" -o "$W/host/test-host"
"$W/host/test-host" "$W/host/NegroniAudio" "$W/host/sink.fifo"

echo "built $B (arm64, minos $MINOS, ad hoc signed):"
cat "$W/ios/SHA256SUMS"
