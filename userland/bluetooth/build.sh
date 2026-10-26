#!/bin/sh
# Build the Bluetooth userland for iOS 16 arm64 (docs/bluetooth-plan.md section 4). macOS + Xcode only
# (iPhoneOS SDK, codesign); scripts/bt/root-add-bt.sh and scripts/bt/phone-bt.sh install the result.
#   userland/bluetooth/build.sh      (a few seconds)
# Output (out/bt/userland/): negroni-bluetool (BlueTool stand-in for the com.apple.BlueTool job), hcitest
# (H4 test client for the kernel transport), both arm64, minos 16.0, ad hoc signed with entitlements.plist;
# SHA256SUMS.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
W=$REPO/out/bt/userland
MINOS=16.0
[ "$(uname -s)" = Darwin ] || { echo "build.sh needs macOS with Xcode (iPhoneOS SDK)" >&2; exit 1; }
SDK=$(xcrun -sdk iphoneos --show-sdk-path)
ICC=$(xcrun -sdk iphoneos --find clang)
T="-target arm64-apple-ios$MINOS -isysroot $SDK"
rm -rf "$W"; mkdir -p "$W"
# relative -o: ld writes the output path into LC_UUID (same bytes in every checkout)
(cd "$W" &&
 "$ICC" $T -O2 -Wall -fblocks "$HERE/negroni-bluetool.c" -o negroni-bluetool &&
 "$ICC" $T -O2 -Wall "$HERE/hcitest.c" -o hcitest)
for b in negroni-bluetool hcitest; do
  codesign --force -s - --entitlements "$HERE/entitlements.plist" "$W/$b" 2>/dev/null
done
(cd "$W" && shasum -a 256 negroni-bluetool hcitest > SHA256SUMS && cat SHA256SUMS)
