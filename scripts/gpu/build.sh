#!/bin/sh
# Fetch, configure and build the iOS arm64 GL userland: negronigl.dylib, ngl_test and
# NegroniGL.bundle (the GLD plugin libGFXShared loads; Mesa freedreno, else softpipe on the CPU).
# Turnip is not built here: scripts/gpu/turnip-build.sh has its own tree and writes
# out/gpu/libvulkan_freedreno.dylib.
# Long builds: scripts/bg.sh gpu-build scripts/gpu/build.sh
set -eu
. "$(cd "$(dirname "$0")" && pwd)/env.sh"

PATCH_HASH=$(shasum -a 256 "$NGL/mesa-patches/0002-turnip-darwin.patch" | awk '{print substr($1,1,16)}')
if [ ! -f "$MESA_SRC/NEGRONIGL-SOURCE" ] || ! grep -q "0002-turnip-darwin.patch $PATCH_HASH" "$MESA_SRC/NEGRONIGL-SOURCE"; then
	"$REPO/scripts/gpu/mesa-fetch.sh"
fi
"$REPO/scripts/gpu/sync-target.sh"
# configure again when the meson options change (the stamp = hash of mesa-setup.sh)
SETUP_HASH=$(shasum -a 256 "$REPO/scripts/gpu/mesa-setup.sh" | cut -c1-16)
if [ ! -f "$MESA_BUILD/build.ninja" ] || [ "$(cat "$MESA_BUILD/.ngl-setup" 2>/dev/null)" != "$SETUP_HASH" ]; then
	VULKAN_DRIVERS= "$REPO/scripts/gpu/mesa-setup.sh"
	echo "$SETUP_HASH" > "$MESA_BUILD/.ngl-setup"
fi

JOBS=${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN)}
T=src/gallium/targets/negronigl
ninja -C "$MESA_BUILD" -j"$JOBS" $T/negronigl.dylib $T/ngl_test $T/NegroniGL.bin

mkdir -p "$G"
cp "$MESA_BUILD/$T/negronigl.dylib" "$G/negronigl.dylib"
cp "$MESA_BUILD/$T/ngl_test" "$G/ngl_test"
B=$G/NegroniGL.bundle
rm -rf "$B"
mkdir -p "$B"
cp "$MESA_BUILD/$T/NegroniGL.bin" "$B/NegroniGL"
cp "$NGL/plugin/Info.plist" "$B/Info.plist"
plutil -lint "$B/Info.plist" >/dev/null

# checks: arm64, minos, the GLD exports libGFXShared needs (129 table names + 2), nothing else
fail=0
for f in "$G/negronigl.dylib" "$G/ngl_test" "$B/NegroniGL"; do
	lipo -archs "$f" | grep -qx arm64 || { echo "$f: not arm64" >&2; fail=1; }
	minos=$(otool -l "$f" | awk '/LC_BUILD_VERSION/{p=1;next} p&&/minos/{print $2;exit}')
	[ "$minos" = "$IOS_MIN" ] || { echo "$f: minos $minos, expected $IOS_MIN" >&2; fail=1; }
done
NAMES=$(mktemp)
grep -v '^#' "$NGL/plugin/gld-names.txt" | grep . > "$NAMES"
want=$(wc -l < "$NAMES" | tr -d ' ')
syms=$(nm -gU "$B/NegroniGL" | awk '{print $3}' | sed 's/^_//')
have=$(echo "$syms" | grep -x -F -f "$NAMES" | wc -l | tr -d ' ')
extra=$(echo "$syms" | grep -v -x -F -f "$NAMES" |
	grep -v -x -e gldInitializeLibrary -e gldTerminateLibrary -e _mh_bundle_header || true)
rm -f "$NAMES"
echo "NegroniGL: $have of $want GLD table names exported"
[ "$have" = "$want" ] || { echo "NegroniGL: GLD exports missing" >&2; fail=1; }
for n in gldInitializeLibrary gldTerminateLibrary; do
	echo "$syms" | grep -qx "$n" || { echo "NegroniGL: $n not exported" >&2; fail=1; }
done
[ -z "$extra" ] || { echo "NegroniGL: unexpected exports: $extra" >&2; fail=1; }
[ $fail = 0 ] || exit 1

codesign -s - -f "$G/negronigl.dylib"
codesign -s - -f "$G/ngl_test"
codesign -s - -f "$B"
codesign -v "$B"
for f in "$G/negronigl.dylib" "$G/ngl_test" "$B/NegroniGL"; do
	file "$f"
	stat -f '%N %z bytes' "$f" 2>/dev/null || stat -c '%n %s bytes' "$f"
done
(cd "$G" && shasum -a 256 negronigl.dylib ngl_test NegroniGL.bundle/NegroniGL NegroniGL.bundle/Info.plist > SHA256SUMS)
cat "$G/SHA256SUMS"
