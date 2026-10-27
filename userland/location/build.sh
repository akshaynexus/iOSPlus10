#!/bin/sh
# Build negroni-locd for iOS 16 arm64: positions into locationd through its simulation service
# (docs/location-plan.md, path L1). macOS + Xcode only (iPhoneOS SDK, codesign);
# scripts/location/phone-location.sh (live phone) and scripts/location/root-add-locd.sh (root image) install it.
#   userland/location/build.sh      (seconds; no tmux needed)
# Output (out/location/userland/):
#   negroni-locd                       arm64, minos 16.0, ad hoc signed with entitlements.plist
#   com.iosplus10.negroni-locd.plist   launchd job (listen on UDP 5155); not loaded unless a root hook adds it
#   SHA256SUMS
# Same toolchain as userland/camera and userland/fp. CoreLocation is opened with dlopen at run time, so the
# binary links only Foundation and libobjc (no CoreLocation class symbol).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
W=$REPO/out/location/userland
MINOS=16.0
[ "$(uname -s)" = Darwin ] || { echo "build.sh needs macOS with Xcode (iPhoneOS SDK)" >&2; exit 1; }
SDK=$(xcrun -sdk iphoneos --show-sdk-path)
ICC=$(xcrun -sdk iphoneos --find clang)
T="-target arm64-apple-ios$MINOS -isysroot $SDK"
rm -rf "$W"; mkdir -p "$W"
# relative -o: ld writes the output path into LC_UUID (same bytes in every checkout)
(cd "$W" && "$ICC" $T -O2 -Wall -Wextra -Wno-unused-parameter -fobjc-arc -framework Foundation \
  "$HERE/negroni-locd.m" -o negroni-locd)
cp "$HERE/com.iosplus10.negroni-locd.plist" "$W/"
plutil -lint "$W/com.iosplus10.negroni-locd.plist" "$HERE/entitlements.plist" >/dev/null

# checks: arm64 only, minos 16.0, no weak imports, no CoreLocation link (dlopen only)
X=$W/negroni-locd
fail=0
lipo -archs "$X" | grep -qx arm64 || { echo "not arm64-only" >&2; fail=1; }
minos=$(otool -l "$X" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')
[ "$minos" = "$MINOS" ] || { echo "minos $minos, expected $MINOS" >&2; fail=1; }
weak=$(nm -m "$X" | grep 'weak external' || true)
[ -z "$weak" ] || { echo "weak imports:" >&2; echo "$weak" >&2; fail=1; }
! otool -L "$X" | grep -q CoreLocation || { echo "links CoreLocation (expected dlopen)" >&2; fail=1; }
[ $fail = 0 ] || exit 1

codesign --force -s - --entitlements "$HERE/entitlements.plist" "$X"
codesign -v "$X"
# simulation: set/hold/listen; authorizeapplications: enable/disable (locationd's SPI check, docs/notes.md section 80)
for e in com.apple.locationd.simulation com.apple.locationd.authorizeapplications; do
  codesign -d --entitlements - "$X" 2>/dev/null | grep -q "$e" || { echo "entitlement $e missing" >&2; exit 1; }
done
(cd "$W" && shasum -a 256 negroni-locd com.iosplus10.negroni-locd.plist > SHA256SUMS && cat SHA256SUMS)
