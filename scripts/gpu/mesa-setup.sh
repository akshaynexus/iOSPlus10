#!/bin/sh
# Configure the patched Mesa tree (scripts/gpu/mesa-fetch.sh) for iOS arm64 (minimum iOS 16.0):
# gallium freedreno + GLES 2/3, static libraries, no window system, no LLVM, our negronigl target
# (userland/negronigl, copied into the tree first). -> out/gpu/mesa-build-ios
#   scripts/gpu/mesa-setup.sh [extra meson -D options]
set -eu
. "$(cd "$(dirname "$0")" && pwd)/env.sh"
[ -f "$MESA_SRC/NEGRONIGL-SOURCE" ] || { echo "no Mesa tree: run scripts/gpu/mesa-fetch.sh" >&2; exit 1; }
# NEGRONIGL_TARGET=0: configure Mesa (GL + Turnip) without our target, e.g. to check Turnip alone
if [ "${NEGRONIGL_TARGET:-1}" = 1 ]; then
  "$(dirname "$0")/sync-target.sh"
else
  rm -rf "$MESA_SRC/src/gallium/targets/negronigl"
fi

CROSS=$G/ios-cross.ini
cat > "$CROSS" <<EOF
[binaries]
c = ['$CLANG', '-arch', 'arm64', '-target', 'arm64-apple-ios$IOS_MIN', '-isysroot', '$SDK']
cpp = ['$CLANGXX', '-arch', 'arm64', '-target', 'arm64-apple-ios$IOS_MIN', '-isysroot', '$SDK', '-fuse-cxa-atexit']
objc = ['$CLANG', '-arch', 'arm64', '-target', 'arm64-apple-ios$IOS_MIN', '-isysroot', '$SDK']
ar = '$AR'
ranlib = '$RANLIB'
strip = '$STRIP'
pkg-config = 'false'

[built-in options]
c_args = ['-Wno-error=incompatible-function-pointer-types']
c_link_args = ['-Wl,-ios_version_min,$IOS_MIN']
cpp_link_args = ['-Wl,-ios_version_min,$IOS_MIN']

[host_machine]
system = 'darwin'
subsystem = 'ios'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'

[properties]
needs_exe_wrapper = true
EOF
case "$(uname -s)" in
Linux) sed -i "s|^c = \['$CLANG'|c = ['$CLANG', '-fuse-ld=lld'|" "$CROSS" ;;
esac

rm -rf "$MESA_BUILD"
meson setup "$MESA_BUILD" "$MESA_SRC" --cross-file "$CROSS" --wrap-mode=nofallback \
  --buildtype=release -Db_ndebug=true -Ddefault_library=static \
  -Dplatforms= -Degl=disabled -Dglx=disabled -Dgbm=disabled -Dglvnd=disabled -Dosmesa=false \
  -Dgallium-drivers=freedreno -Dfreedreno-kmds=msm -Dvulkan-drivers="${VULKAN_DRIVERS-freedreno}" -Dllvm=disabled \
  -Dshared-glapi=enabled -Dgles1=disabled -Dgles2=enabled -Dopengl=true \
  -Dzstd=disabled -Dexpat=disabled -Dxmlconfig=disabled -Dshader-cache=disabled \
  -Dvalgrind=disabled -Dlibunwind=disabled -Dlmsensors=disabled -Dbuild-tests=false \
  -Dperfetto=false -Dgallium-va=disabled -Dgallium-vdpau=disabled -Dgallium-xa=disabled \
  -Dgallium-rusticl=false -Dteflon=false -Dvideo-codecs= -Dtools= -Dhtml-docs=disabled "$@"
echo "configured: $MESA_BUILD"
