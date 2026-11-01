#!/bin/bash
# Build NegroniCamera.driver for the Mi A3 (laurel_sprout) iOS 16 root: the sources of userland/camera (HakiOS camera_device.c
# + camera_isp.c + media_hooks.c, README there) with -DLAUREL_CAMERA (rear IMX586, 1280x720 frames of kernel patch 2772,
# "LAUREL CAMERA: ios:" lines). A bundle in the audio HAL folder: mediaserverd loads it, the constructor installs the capture hooks.
#   userland/laurel/camera/build.sh          (a few seconds; no tmux needed)
# Linux: the theos iPhone toolchain (clang 11, ld64-609, ldid) and MacOSX13.3.sdk headers that scripts/laurel/kernel-linux.sh
#        fetches into out/laurel-kernel/{theos,deps}; the link uses text stubs (.tbd) made from the objects' undefined symbols,
#        as userland/laurel/audio/build.sh does. macOS: Xcode's iPhoneOS SDK + codesign.
# Output: out/laurel/camera/ios/NegroniCamera.driver/{NegroniCamera,Info.plist} (arm64, minos 16.0, ad hoc signed, no entitlements,
#         one export: the factory), out/laurel/camera/ios/SHA256SUMS,
#         out/laurel/camera/host/isp-render (host tool + self test of the same ISP code).
# PREVIEW_BIN=2 (default): the scalers offer 2016x1512 as on negroni (the graph accepted that [V negroni logs]); the pictures
# are 8-bit bilinear from the 640x360 cells (camera_isp.c isp_scale_nv12).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
SRC=$REPO/userland/camera
W=$REPO/out/laurel/camera
B=$W/ios/NegroniCamera.driver
T=$W/ios/build
MINOS=16.0
BIN=${PREVIEW_BIN:-2}
DEFS="-DLAUREL_CAMERA=1 -DPREVIEW_BIN=$BIN"
CFLAGS="-O2 -Wall -Wextra -Wno-unused-parameter -Wno-four-char-constants -Wno-multichar -Wno-deprecated-declarations -fvisibility=hidden -fblocks $DEFS"
FILES="media_hooks camera_device camera_isp camera_still"
rm -rf "$W/ios" "$W/host"
mkdir -p "$B" "$T" "$W/host"

if [ "$(uname -s)" = Darwin ] && xcrun -sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
  SDK=$(xcrun -sdk iphoneos --show-sdk-path)
  CC=$(xcrun -sdk iphoneos --find clang)
  "$CC" -arch arm64 -isysroot "$SDK" -mios-version-min=$MINOS $CFLAGS -bundle -framework CoreFoundation -framework CoreMedia \
    -framework CoreVideo -lobjc "$SRC/media_hooks.c" "$SRC/camera_device.c" "$SRC/camera_isp.c" "$SRC/camera_still.c" -o "$B/NegroniCamera"
  NM="xcrun nm"; OTOOL="xcrun otool"
  sign() { codesign --force -s - "$1"; }
else
  TC=$REPO/out/laurel-kernel/theos/toolchain/linux/iphone/bin
  SDK=$REPO/out/laurel-kernel/deps/MacOSX13.3.sdk
  for f in "$TC/clang" "$TC/ld" "$TC/ldid" "$TC/llvm-nm" "$SDK/System/Library/Frameworks/CoreMedia.framework/Headers/CoreMedia.h"; do
    [ -e "$f" ] || { echo "camera: missing $f (run scripts/laurel/kernel-linux.sh once: it fetches theos + the SDK)" >&2; exit 1; }
  done
  # headers: the macOS SDK's; the target is iOS 16 arm64 (only C, plain types; layouts equal on both)
  for s in $FILES; do
    "$TC/clang" -target arm64-apple-ios$MINOS -isysroot "$SDK" -Wno-incompatible-sysroot -Wno-availability $CFLAGS \
      -I"$HERE/sdk-stub" -I"$SRC" -c "$SRC/$s.c" -o "$T/$s.o" &
  done
  wait
  for s in $FILES; do [ -s "$T/$s.o" ] || { echo "camera: $s.c did not compile" >&2; exit 1; }; done
  # link: .tbd stubs with exactly the symbols the objects need (two-level namespace, real install names);
  # -sdk_version: ld64 reads an SDK version from digits in the -syslibroot path otherwise (a worktree path has some)
  R=$T/sysroot
  FW=System/Library/Frameworks
  mkdir -p "$R/usr/lib" "$R/$FW/CoreFoundation.framework" "$R/$FW/CoreMedia.framework" "$R/$FW/CoreVideo.framework"
  syms=$("$TC/llvm-nm" -u -j "$T"/*.o | grep '^_' | sort -u)
  pick() { printf '%s\n' "$syms" | { grep -E "$1" || true; } | paste -sd, - | sed 's/,/, /g'; }
  P_CF='^_(CF|kCF)|^___CFConstantStringClassReference$'
  P_CM='^_(CM|kCM)'
  P_CV='^_(CV|kCV)'
  P_OBJC='^_(objc_|sel_|class_|method_|object_|ivar_|protocol_)|^__objc_|^_OBJC_'
  sys=$(printf '%s\n' "$syms" | grep -v -E "$P_CF|$P_CM|$P_CV|$P_OBJC" | paste -sd, - | sed 's/,/, /g')
  tbd() {   # FILE INSTALL_NAME CURRENT COMPAT SYMBOLS
    printf -- '--- !tapi-tbd-v3\narchs: [ arm64 ]\nplatform: ios\ninstall-name: %s\ncurrent-version: %s\ncompatibility-version: %s\nexports:\n  - archs: [ arm64 ]\n    symbols: [ %s ]\n...\n' \
      "$2" "$3" "$4" "$5" > "$1"
  }
  tbd "$R/usr/lib/libSystem.tbd" /usr/lib/libSystem.B.dylib 1311 1 "dyld_stub_binder, $sys"
  tbd "$R/usr/lib/libobjc.tbd" /usr/lib/libobjc.A.dylib 228 1 "$(pick "$P_OBJC")"
  tbd "$R/$FW/CoreFoundation.framework/CoreFoundation.tbd" /$FW/CoreFoundation.framework/CoreFoundation 1953.255 150 "$(pick "$P_CF")"
  tbd "$R/$FW/CoreMedia.framework/CoreMedia.tbd" /$FW/CoreMedia.framework/CoreMedia 1 1 "$(pick "$P_CM")"
  tbd "$R/$FW/CoreVideo.framework/CoreVideo.tbd" /$FW/CoreVideo.framework/CoreVideo 1 1 "$(pick "$P_CV")"
  "$TC/clang" -target arm64-apple-ios$MINOS -fuse-ld="$TC/ld" -B"$TC" -isysroot "$R" -nostdlib -bundle -lSystem -lobjc \
    -framework CoreFoundation -framework CoreMedia -framework CoreVideo -Wl,-exported_symbol,_NegroniCamera_Create -Wl,-sdk_version,16.0 \
    "$T"/*.o -o "$B/NegroniCamera"
  NM="$TC/llvm-nm"; OTOOL="$TC/otool"
  sign() { "$TC/ldid" -S "$1"; }
fi
cp "$SRC/Info.plist" "$B/Info.plist"
python3 -I -c 'import plistlib,sys; d=plistlib.load(open(sys.argv[1],"rb")); assert "NegroniCamera_Create" in d["CFPlugInFactories"].values()' "$B/Info.plist"

# checks: arm64 bundle, minos 16.0, the factory is the only export, no weak imports, the hook functions and the device path present
fail=0
X=$B/NegroniCamera
file "$X" | grep -q 'Mach-O 64-bit arm64 bundle' || { echo "camera: not an arm64 bundle" >&2; fail=1; }
minos=$($OTOOL -l "$X" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit} /LC_VERSION_MIN_IPHONEOS/{v=1} v&&/version/{print $2; exit}')
[ "$minos" = "$MINOS" ] || { echo "camera: minos $minos, expected $MINOS" >&2; fail=1; }
exports=$($NM -gU "$X" | awk '{print $NF}' | grep -v -x -e _NegroniCamera_Create -e __mh_bundle_header || true)
[ -z "$exports" ] || { echo "camera: unexpected exports: $exports" >&2; fail=1; }
grep -q ' _NegroniCamera_Create$' <<<"$($NM -gU "$X")" || { echo "camera: factory not exported" >&2; fail=1; }
weak=$($NM -m "$X" 2>/dev/null | grep 'weak external' || true)
[ -z "$weak" ] || { echo "camera: weak imports: $weak" >&2; fail=1; }
libs=$($OTOOL -L "$X" | tail -n +2 | awk '{print $1}' | LC_ALL=C sort | tr '\n' ' ')
want="/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation /System/Library/Frameworks/CoreMedia.framework/CoreMedia /System/Library/Frameworks/CoreVideo.framework/CoreVideo /usr/lib/libSystem.B.dylib /usr/lib/libobjc.A.dylib "
[ "$libs" = "$want" ] || { echo "camera: unexpected libraries: $libs" >&2; fail=1; }
# (nm's output in a variable: with pipefail, an early exit of grep -q SIGPIPEs nm and a symbol that is there counts as missing)
all_syms=$($NM "$X")
for s in _shared_vendor _audio_source_start _video_stabilization_method _video_stabilization_type _quality_prioritization \
         _gnr_render _emit_sample_buffer _prewarm_portrait_filter _image_added _negroni_camera_init _negroni_camera_device_create \
         _worker _isp_render_nv12 _isp_render_still_nv12 _isp_scale_nv12 _isp_render_cells _isp_mhc_row _isp_finish_rows; do
  grep -q " $s\$" <<<"$all_syms" || { echo "camera: symbol $s missing" >&2; fail=1; }
done
grep -q -a '/dev/negronicam' "$X" || { echo "camera: no /dev/negronicam string" >&2; fail=1; }
grep -q -a 'LAUREL CAMERA: ios' "$X" || { echo "camera: no LAUREL CAMERA line" >&2; fail=1; }
[ $fail = 0 ] || exit 1
sign "$X"
rm -rf "$T"
(cd "$W/ios" && { sha256sum NegroniCamera.driver/NegroniCamera NegroniCamera.driver/Info.plist 2>/dev/null ||
  shasum -a 256 NegroniCamera.driver/NegroniCamera NegroniCamera.driver/Info.plist; } > SHA256SUMS)

# host: the same ISP code: self test (RAW10 colour bars in each Bayer order) and the NCFRAME1 dump renderer
${CC_HOST:-cc} -O2 -Wall -Wextra -Wno-unused-parameter -I"$SRC" "$SRC/isp-host.c" "$SRC/camera_isp.c" "$SRC/camera_still.c" -lm -o "$W/host/isp-render"
"$W/host/isp-render" --selftest > "$W/host/isp-selftest.txt"
tail -3 "$W/host/isp-selftest.txt"
echo "camera: $B ($(wc -c < "$X") bytes, minos $minos, PREVIEW_BIN $BIN)"
cat "$W/ios/SHA256SUMS"
