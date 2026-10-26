#!/bin/sh
# Build negroni-fpd for iOS 16 arm64 (the fingerprint lock-screen glyph daemon; patch 0354,
# patches/xnu/README-fingerprint.md "0354"). macOS + Xcode only (iPhoneOS SDK, codesign);
# scripts/fp/root-add-fpd.sh installs the result.
#   userland/fp/build.sh      (seconds)
# Output (out/fp/userland/): negroni-fpd, arm64, minos 16.0, ad hoc signed with entitlements.plist; SHA256SUMS.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
W=$REPO/out/fp/userland
MINOS=16.0
[ "$(uname -s)" = Darwin ] || { echo "build.sh needs macOS with Xcode (iPhoneOS SDK)" >&2; exit 1; }
SDK=$(xcrun -sdk iphoneos --show-sdk-path)
ICC=$(xcrun -sdk iphoneos --find clang)
T="-target arm64-apple-ios$MINOS -isysroot $SDK"
rm -rf "$W"; mkdir -p "$W"
# relative -o: ld writes the output path into LC_UUID (same bytes in every checkout)
(cd "$W" && "$ICC" $T -O2 -Wall -fblocks "$HERE/negroni-fpd.c" -o negroni-fpd)
codesign --force -s - --entitlements "$HERE/entitlements.plist" "$W/negroni-fpd"
codesign -v "$W/negroni-fpd"
(cd "$W" && shasum -a 256 negroni-fpd > SHA256SUMS && cat SHA256SUMS)
