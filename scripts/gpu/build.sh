#!/bin/sh
# Fetch, configure and build the iOS arm64 GL/EAGL and Turnip userland libraries.
# Long builds should run with: scripts/bg.sh gpu-build scripts/gpu/build.sh
set -eu
. "$(cd "$(dirname "$0")" && pwd)/env.sh"

PATCH_HASH=$(shasum -a 256 "$NGL/mesa-patches/0002-turnip-darwin.patch" | awk '{print substr($1,1,16)}')
if [ ! -f "$MESA_SRC/NEGRONIGL-SOURCE" ] || ! grep -q "0002-turnip-darwin.patch $PATCH_HASH" "$MESA_SRC/NEGRONIGL-SOURCE"; then
	"$REPO/scripts/gpu/mesa-fetch.sh"
fi
"$REPO/scripts/gpu/sync-target.sh"
if [ ! -f "$MESA_BUILD/build.ninja" ]; then
	"$REPO/scripts/gpu/mesa-setup.sh"
fi

JOBS=${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN)}
ninja -C "$MESA_BUILD" -j"$JOBS" \
	src/gallium/targets/negronigl/negronigl.dylib \
	src/gallium/targets/negronigl/ngl_test \
	src/freedreno/vulkan/libvulkan_freedreno.dylib

mkdir -p "$G"
find "$MESA_BUILD" -type f \( -name 'negronigl.dylib' -o -name 'libvulkan_freedreno.dylib' -o -name 'ngl_test' \) -print
GL=$(find "$MESA_BUILD" -type f -name negronigl.dylib -print -quit)
VK=$(find "$MESA_BUILD" -type f -name libvulkan_freedreno.dylib -print -quit)
TEST=$(find "$MESA_BUILD" -type f -name ngl_test -print -quit)
[ -n "$GL" ] && [ -n "$VK" ] && [ -n "$TEST" ] || { echo 'Mesa outputs are missing' >&2; exit 1; }
cp "$GL" "$G/negronigl.dylib"
cp "$VK" "$G/libvulkan_freedreno.dylib"
cp "$TEST" "$G/ngl_test"
codesign -s - -f "$G/negronigl.dylib"
codesign -s - -f "$G/libvulkan_freedreno.dylib"
codesign -s - -f "$G/ngl_test"
for f in "$G/negronigl.dylib" "$G/libvulkan_freedreno.dylib" "$G/ngl_test"; do
	file "$f"
	stat -f '%N %z bytes' "$f" 2>/dev/null || stat -c '%n %s bytes' "$f"
	otool -l "$f" | awk '/LC_BUILD_VERSION/{p=1;next} p&&/minos/{print FILENAME ": minos " $2;exit}' FILENAME="$f"
done
