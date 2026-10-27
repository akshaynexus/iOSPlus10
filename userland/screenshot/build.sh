#!/bin/sh
# Build negroni-shot (iOS 16 arm64): a PNG of the main display from the render server, for checking
# drawing faults without a camera. macOS + Xcode only. Install and run: scripts/screenshot/phone-shot.sh (pushes it when the hash differs)
#   userland/screenshot/build.sh      (seconds; no tmux needed)
# Output: out/screenshot/userland/negroni-shot (ad hoc signed with entitlements.plist), SHA256SUMS
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
W=$REPO/out/screenshot/userland
MINOS=16.0
[ "$(uname -s)" = Darwin ] || { echo "build.sh needs macOS with Xcode (iPhoneOS SDK)" >&2; exit 1; }
SDK=$(xcrun -sdk iphoneos --show-sdk-path)
ICC=$(xcrun -sdk iphoneos --find clang)
rm -rf "$W"; mkdir -p "$W"
(cd "$W" && "$ICC" -target arm64-apple-ios$MINOS -isysroot "$SDK" -O2 -Wall -Wextra -fobjc-arc \
  -framework Foundation -framework CoreGraphics -framework ImageIO -framework IOSurface \
  "$HERE/negroni-shot.m" -o negroni-shot)
codesign --force -s - --entitlements "$HERE/entitlements.plist" "$W/negroni-shot"
codesign -v "$W/negroni-shot"
(cd "$W" && shasum -a 256 negroni-shot > SHA256SUMS && cat SHA256SUMS)
