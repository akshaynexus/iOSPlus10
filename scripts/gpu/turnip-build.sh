#!/bin/sh
# Turnip (Mesa freedreno Vulkan, MIT) for iOS 16 arm64 = the Vulkan driver of the Metal path.
# Its own Mesa tree and build directory, so the GL build (scripts/gpu/build.sh) is not touched:
#   out/gpu/turnip/mesa-VERSION   Mesa archive (SHA-256 checked) + HackiOS patches + userland/turnip/mesa-patches
#   out/gpu/turnip/build-ios      meson build (release, -Db_ndebug=true, Vulkan only, msm KMD over negroni_drm.c)
#   out/gpu/turnip/libvulkan_freedreno.dylib   signed result: the ONE staged Turnip (scripts/metal/env.sh TURNIP_DYLIB;
#                                 scripts/metal/build.sh copies it into NegroniMetal.bundle). No other script stages Turnip.
#
#   scripts/bg.sh turnip-build scripts/gpu/turnip-build.sh          tree (if the patches changed) + setup + build
#   scripts/gpu/turnip-build.sh tree                                 only make the patched tree
#   scripts/gpu/turnip-build.sh base DIR                             the tree before our patches (to write new patches)
# docs/gpu-userland.md "Turnip" describes the patches and the checks at the end.
set -eu
. "$(cd "$(dirname "$0")" && pwd)/env.sh"

TU=$G/turnip
TU_SRC=$TU/mesa-$MESA_VERSION
TU_BUILD=$TU/build-ios
TU_PATCHES=$REPO/userland/turnip/mesa-patches
A=$DL/mesa-$MESA_VERSION.tar.xz

stamp() {
  echo "mesa $MESA_VERSION $MESA_SHA256"
  echo "hackios $HACKIOS_COMMIT: $HACKIOS_PATCHES"
  for p in "$TU_PATCHES"/*.patch; do echo "turnip $(basename "$p") $(shasum -a 256 "$p" | cut -c1-16)"; done
  for f in negroni_drm.c negroni_drm.h ngl_abi.h xf86drm.h; do echo "drm $f $(shasum -a 256 "$NGL/drm/$f" | cut -c1-16)"; done
  echo "log.c $(shasum -a 256 "$NGL/log.c" | cut -c1-16)"
}

# $1 = directory: Mesa + HackiOS patches + the redwood-drm files (no Turnip patches)
make_base() {
  [ -f "$A" ] && echo "$MESA_SHA256  $A" | shasum -a 256 -c - >/dev/null ||
    "$REPO/scripts/gpu/mesa-fetch.sh"       # downloads and checks the archive (and makes the GL tree)
  rm -rf "$1" "$1.extract"
  mkdir -p "$1.extract"
  tar -xJf "$A" -C "$1.extract"
  mv "$1.extract/mesa-$MESA_VERSION" "$1"
  rmdir "$1.extract"
  git -C "$HACKIOS" cat-file -e "$HACKIOS_COMMIT^{commit}" ||
    { echo "external/hackios-xnu-userland lacks $HACKIOS_COMMIT (git submodule update --init)" >&2; exit 1; }
  for p in $HACKIOS_PATCHES; do
    git -C "$HACKIOS" show "$HACKIOS_COMMIT:tools/mesa/$p.patch" | patch -s --no-backup-if-mismatch -d "$1" -p1
  done
  # the libdrm stand-in: header + functions (userland/negronigl/drm, shared with the GL build)
  mkdir -p "$1/src/redwood-drm"
  for f in xf86drm.h negroni_drm.c negroni_drm.h ngl_abi.h; do cp "$NGL/drm/$f" "$1/src/redwood-drm/$f"; done
  cp "$NGL/log.c" "$1/src/redwood-drm/log.c"
  echo 'typedef int negroni_turnip_redwood_drm_placeholder;' > "$1/src/redwood-drm/redwood_drm.c"
  find "$1" -name '*.orig' -delete
}

make_tree() {
  mkdir -p "$TU"
  make_base "$TU_SRC"
  for p in "$TU_PATCHES"/*.patch; do
    echo "patch turnip $(basename "$p")"
    patch -s --no-backup-if-mismatch -d "$TU_SRC" -p1 < "$p"
  done
  find "$TU_SRC" -name '*.orig' -delete
  stamp > "$TU_SRC/TURNIP-SOURCE"
  rm -rf "$TU_BUILD"                        # a new tree: configure again
  echo "ready: $TU_SRC"
}

setup() {
  CROSS=$TU/ios-cross.ini
  cat > "$CROSS" <<EOF
[binaries]
c = ['$CLANG', '-arch', 'arm64', '-target', 'arm64-apple-ios$IOS_MIN', '-isysroot', '$SDK']
cpp = ['$CLANGXX', '-arch', 'arm64', '-target', 'arm64-apple-ios$IOS_MIN', '-isysroot', '$SDK', '-fuse-cxa-atexit']
objc = ['$CLANG', '-arch', 'arm64', '-target', 'arm64-apple-ios$IOS_MIN', '-isysroot', '$SDK']
ar = '$AR'
ranlib = '$RANLIB'
strip = '$STRIP'
nm = '$NM'
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
  Linux) sed -i "s|^c = \['$CLANG'|c = ['$CLANG', '-fuse-ld=lld'|; s|^cpp = \['$CLANGXX'|cpp = ['$CLANGXX', '-fuse-ld=lld'|" "$CROSS" ;;
  esac
  rm -rf "$TU_BUILD"
  meson setup "$TU_BUILD" "$TU_SRC" --cross-file "$CROSS" --wrap-mode=nofallback \
    --buildtype=release -Db_ndebug=true -Ddefault_library=static \
    -Dplatforms= -Degl=disabled -Dglx=disabled -Dgbm=disabled -Dglvnd=disabled -Dosmesa=false \
    -Dgallium-drivers= -Dvulkan-drivers=freedreno -Dfreedreno-kmds=msm -Dllvm=disabled \
    -Dopengl=false -Dgles1=disabled -Dgles2=disabled -Dshared-glapi=disabled \
    -Dzstd=disabled -Dexpat=disabled -Dxmlconfig=disabled -Dshader-cache=disabled \
    -Dvalgrind=disabled -Dlibunwind=disabled -Dlmsensors=disabled -Dbuild-tests=false \
    -Dperfetto=false -Dgallium-va=disabled -Dgallium-vdpau=disabled -Dgallium-xa=disabled \
    -Dgallium-rusticl=false -Dteflon=false -Dvideo-codecs= -Dtools= -Dhtml-docs=disabled \
    -Dvulkan-layers= "$@"
}

case "$(uname -s)" in
Darwin) NM=${NM:-$(xcrun --sdk iphoneos -f nm)} ;;
*)      NM=${NM:-llvm-nm} ;;
esac
export NM

case "${1:-build}" in
tree) make_tree; exit 0 ;;
base) make_base "${2:?base DIR}"; exit 0 ;;
build) ;;
*) sed -n 2,10p "$0"; exit 1 ;;
esac

if [ ! -f "$TU_SRC/TURNIP-SOURCE" ] || [ "$(stamp)" != "$(cat "$TU_SRC/TURNIP-SOURCE")" ]; then
  make_tree
fi
[ -f "$TU_BUILD/build.ninja" ] || setup
ninja -C "$TU_BUILD" -j"$NPROC" src/freedreno/vulkan/libvulkan_freedreno.dylib

VK=$TU_BUILD/src/freedreno/vulkan/libvulkan_freedreno.dylib
OUTVK=$TU/libvulkan_freedreno.dylib
rm -f "$G/libvulkan_freedreno.dylib"        # old second copy (GL build before 8dddd7d, this script before 2026-10-25)

# checks (they fail the build): arm64, minos, chained fixups (no dyld_stub_binder: local in the 20H392 libdyld),
# only weak symbols looked up at load time (the entrypoint tables' optional ones), the exports the Metal path needs
case "$(uname -s)" in Darwin) OTOOL=otool ;; *) OTOOL=llvm-otool ;; esac
fail=0
lipo -archs "$VK" 2>/dev/null | grep -qx arm64 || { echo "turnip: not arm64" >&2; fail=1; }
minos=$($OTOOL -l "$VK" | awk '/LC_BUILD_VERSION/{p=1;next} p&&/minos/{print $2;exit}')
[ "$minos" = "$IOS_MIN" ] || { echo "turnip: minos $minos, expected $IOS_MIN" >&2; fail=1; }
$OTOOL -l "$VK" | grep -q 'cmd LC_DYLD_CHAINED_FIXUPS' || { echo "turnip: no LC_DYLD_CHAINED_FIXUPS" >&2; fail=1; }
! $OTOOL -l "$VK" | grep -q 'cmd LC_DYLD_INFO' || { echo "turnip: has LC_DYLD_INFO(_ONLY)" >&2; fail=1; }
"$NM" -m "$VK" > "$TU/nm-m.txt"
! grep -q 'dyld_stub_binder' "$TU/nm-m.txt" || { echo "turnip: imports dyld_stub_binder" >&2; fail=1; }
strong=$(grep '(undefined)' "$TU/nm-m.txt" | grep 'dynamically looked up' | grep -v 'weak external' || true)
[ -z "$strong" ] || { echo "turnip: strong symbols without a library:" >&2; echo "$strong" | head -20 >&2; fail=1; }
weak=$(grep '(undefined)' "$TU/nm-m.txt" | grep -c 'dynamically looked up' || true)
exports=$("$NM" -gU "$VK" | awk '{print $3}')
for s in _vk_icdGetInstanceProcAddr _vkGetInstanceProcAddr _redwood_drm_note_surface; do
  echo "$exports" | grep -qx "$s" || { echo "turnip: $s not exported" >&2; fail=1; }
done
[ $fail = 0 ] || exit 1

cp "$VK" "$OUTVK"
codesign -s - -f "$OUTVK" 2>/dev/null || ldid -S "$OUTVK"
echo "turnip: arm64, minos $minos, chained fixups, $weak weak symbols looked up at load time (resolve to NULL when absent)"
echo "turnip: exports: $(echo "$exports" | tr '\n' ' ')"
stat -f '%N %z bytes' "$OUTVK" 2>/dev/null || stat -c '%n %s bytes' "$OUTVK"
shasum -a 256 "$OUTVK"
