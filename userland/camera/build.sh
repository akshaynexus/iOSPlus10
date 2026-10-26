#!/bin/sh
# Build NegroniCamera.driver: the camera for the stock Camera.app inside mediaserverd (userland/camera/README.md).
# macOS + Xcode only (iPhoneOS SDK, codesign); scripts/camera/root-add-camera.sh and scripts/camera/phone-camera.sh
# install the result on macOS or Linux.
#   userland/camera/build.sh             (a few seconds; no tmux needed)
#   PREVIEW_BIN=1 userland/camera/build.sh   scaler outputs at the full sensor size (default 2: 2x2 cells)
# Output:
#   out/camera/ios/NegroniCamera.driver/{NegroniCamera,Info.plist}   arm64, minos 16.0, ad hoc signed, no entitlements
#   out/camera/ios/SHA256SUMS
#   out/camera/host/isp-render           macOS tool: an NCFRAME1 dump from the phone -> PPM through the same ISP code
#   out/camera/host/isp-selftest.txt     synthetic RAW10 colour bars in each Bayer order through the ISP
# Same toolchain rules as userland/audio/build.sh: no weak imports (symbols newer than iOS 16).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
W=$REPO/out/camera
MINOS=16.0
BIN=${PREVIEW_BIN:-2}
[ "$(uname -s)" = Darwin ] || { echo "build.sh needs macOS with Xcode (iPhoneOS SDK)" >&2; exit 1; }

SDK=$(xcrun -sdk iphoneos --show-sdk-path)
ICC=$(xcrun -sdk iphoneos --find clang)
CFLAGS="-O2 -Wall -Wextra -Wno-unused-parameter -Wno-four-char-constants -Wno-multichar -Wno-deprecated-declarations -fvisibility=hidden -DPREVIEW_BIN=$BIN"
rm -rf "$W/ios" "$W/host"
B=$W/ios/NegroniCamera.driver
mkdir -p "$B" "$W/host"

"$ICC" -arch arm64 -isysroot "$SDK" -mios-version-min=$MINOS $CFLAGS -fblocks -bundle \
  -framework CoreFoundation -framework CoreMedia -framework CoreVideo -lobjc \
  "$HERE/media_hooks.c" "$HERE/camera_device.c" "$HERE/camera_isp.c" -o "$B/NegroniCamera"
cp "$HERE/Info.plist" "$B/Info.plist"
plutil -lint "$B/Info.plist" >/dev/null

# checks: arm64 only, minos 16.0, no weak imports, only the factory exported, the hooks and the vendor's
# create function present, the factory name = the Info.plist one
fail=0
X=$B/NegroniCamera
lipo -archs "$X" | grep -qx arm64 || { echo "not arm64-only" >&2; fail=1; }
minos=$(otool -l "$X" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')
[ "$minos" = "$MINOS" ] || { echo "minos $minos, expected $MINOS" >&2; fail=1; }
weak=$(nm -m "$X" | grep 'weak external' || true)
[ -z "$weak" ] || { echo "weak imports:" >&2; echo "$weak" >&2; fail=1; }
exported=$(nm -gU "$X" | awk '{print $3}' | grep -v -x -e _NegroniCamera_Create -e __mh_bundle_header || true)
[ -z "$exported" ] || { echo "unexpected exports: $exported" >&2; fail=1; }
nm -gU "$X" | grep -q ' _NegroniCamera_Create$' || { echo "factory NegroniCamera_Create not exported" >&2; fail=1; }
/usr/libexec/PlistBuddy -c 'Print :CFPlugInFactories' "$B/Info.plist" | grep -q '= NegroniCamera_Create$' ||
  { echo "Info.plist factory is not NegroniCamera_Create" >&2; fail=1; }
for s in _shared_vendor _audio_source_start _video_stabilization_method _video_stabilization_type _quality_prioritization \
         _gnr_render _emit_sample_buffer _prewarm_portrait_filter _image_added _negroni_camera_init _negroni_camera_device_create \
         _worker _isp_render_nv12 _isp_render_still_nv12; do
  nm "$X" | grep -q " $s\$" || { echo "symbol $s missing" >&2; fail=1; }
done
strings "$X" | grep -q '^/dev/negronicam$' || { echo "no /dev/negronicam string" >&2; fail=1; }
[ $fail = 0 ] || exit 1
# A bundle loaded by mediaserverd: ad hoc signature, no entitlements (the process has its own).
# The negroni AMFI stand-in treats signed files on the root as platform code (patch 0221).
codesign --force -s - "$B"
codesign -v "$B"
if codesign -d --entitlements - "$B" 2>/dev/null | grep -q '<key>'; then echo "the bundle has entitlements" >&2; exit 1; fi
(cd "$W/ios" && shasum -a 256 NegroniCamera.driver/NegroniCamera NegroniCamera.driver/Info.plist > SHA256SUMS)

# host: the ISP code on macOS (the same sources): a self test and the dump renderer
clang -O2 -Wall -Wextra -Wno-unused-parameter -I"$HERE" "$HERE/isp-host.c" "$HERE/camera_isp.c" -o "$W/host/isp-render"
"$W/host/isp-render" --selftest > "$W/host/isp-selftest.txt"
cat "$W/host/isp-selftest.txt"

echo "built $B (arm64, minos $MINOS, ad hoc signed, PREVIEW_BIN $BIN):"
ls -l "$X" "$B/Info.plist"
cat "$W/ios/SHA256SUMS"
