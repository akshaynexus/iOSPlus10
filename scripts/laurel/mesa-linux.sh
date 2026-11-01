#!/bin/bash
# Mesa 25.0.7 (freedreno + softpipe, OSMesa with an OpenGL ES profile) for the iOS 16 userland of the Mi A3,
# built on Linux (no Mac). Recipe: ios-topaz userland/mesa/mk-mesa-mac.sh (Xcode) with the Linux cross setup of
# hackios-scion tools/mk-mesa.sh: stock clang -target arm64-apple-ios + the theos cctools ld64 + iPhoneOS16.5.sdk.
#   scripts/bg.sh laurel-mesa scripts/laurel/mesa-linux.sh
#   DRIVERS=softpipe,freedreno (default)   CLEAN=1: unpack and configure again
# Patches: external/ios-topaz/userland/mesa/*.patch (freedreno-darwin: the redwood-drm libdrm stand-in that talks
# to the kernel's RedwoodGPU user client; osmesa-es-profile) + src/redwood-drm copied in. Nothing is changed in external/.
# Output: out/laurel/gpu/mesa/out/libOSMesa.8.dylib (install name /topaz/lib/libOSMesa.8.dylib), exported-gl.txt, gl.xml.
set -euo pipefail
. "$(dirname "$0")/gpu-env.sh"
gpu_need_toolchain
for t in meson ninja bison flex llvm-objdump; do command -v $t >/dev/null || gpu_die "missing host tool $t"; done
M=$G/mesa
mkdir -p "$M/out" "$DL" "$G/bin"
T0=$(date +%s)

# 1. downloads in parallel: SDK (git) | Mesa archive (hash checked)
fetch_mesa() {
  local a=$DL/mesa-$MESA_VERSION.tar.xz
  [ -f "$a" ] || curl -fsSL --retry 5 -o "$a.partial" "$MESA_URL" && { [ -f "$a" ] || mv "$a.partial" "$a"; }
  [ "$(gpu_sha256 < "$a")" = "$MESA_SHA256" ] || { rm -f "$a"; gpu_die "mesa archive: sha256 mismatch"; }
}
gpu_fetch_sdk > "$G/sdk-fetch.log" 2>&1 & p1=$!
fetch_mesa & p2=$!
gpu_venv > "$G/venv.log" 2>&1 & p3=$!
wait $p1 || { tail -5 "$G/sdk-fetch.log"; gpu_die "SDK fetch failed"; }
wait $p2 || gpu_die "mesa fetch failed"
wait $p3 || { tail -5 "$G/venv.log"; gpu_die "venv failed"; }
echo "mesa-linux: SDK $(basename "$(readlink -f "$SDK")") (theos/sdks ${SDKS_COMMIT:0:7}), Mesa $MESA_VERSION archive ok"

# 2. source tree = archive + topaz patches (a tree patched with other patches is unpacked again)
S=$M/mesa-$MESA_VERSION
PATCHES=$(cat "$TOPAZ"/userland/mesa/*.patch | gpu_sha256)
if [ "${CLEAN:-0}" = 1 ] || [ ! -d "$S" ] || [ "$(cat "$S/.laurel-patches" 2>/dev/null)" != "$PATCHES" ]; then
  rm -rf "$S" "$M"/build-*
  tar -xJf "$DL/mesa-$MESA_VERSION.tar.xz" -C "$M"
  for p in "$TOPAZ"/userland/mesa/*.patch; do
    patch -s --no-backup-if-mismatch -d "$S" -p1 < "$p" || gpu_die "patch $(basename "$p") does not apply"
  done
  echo "$PATCHES" > "$S/.laurel-patches"
  echo "mesa-linux: patched with $(ls "$TOPAZ"/userland/mesa/*.patch | xargs -n1 basename | tr '\n' ' ')"
fi
rm -rf "$S/src/redwood-drm"
cp -R "$TOPAZ/userland/mesa/redwood-drm" "$S/src/redwood-drm"
# our redwood-drm changes (userland/laurel/gpu/mesa-patches: 0001 redwood_drm_surface_drawn for kernel request 0x7d)
for p in "$LAUREL_MESA_PATCHES"/*.patch; do
  [ -f "$p" ] || continue
  patch -s --no-backup-if-mismatch -d "$S/src/redwood-drm" -p1 < "$p" || gpu_die "patch $(basename "$p") does not apply to redwood-drm"
done

# 3. compiler wrappers (meson wants one program per language) and the cross file
# --ld-path only on link lines: on a compile-only line clang warns "argument unused", and meson's
# feature checks use -Werror=unused-command-line-argument (every check failed: "struct timespec": NO)
for c in clang clang++; do
  x=
  [ $c = clang++ ] && x=-fuse-cxa-atexit
  cat > "$G/bin/ios-$c" <<W
#!/bin/sh
ld="--ld-path=$LD64"
for a in "\$@"; do case "\$a" in -c|-S|-E|-M|-MM) ld=;; esac; done
exec $(command -v $c) -target arm64-apple-ios$IOS_MIN $CPU_FLAGS \$ld $x "\$@"
W
  chmod +x "$G/bin/ios-$c"
done
cat > "$M/cross.ini" <<INI
[binaries]
c = ['$G/bin/ios-clang', '-isysroot', '$SDK']
cpp = ['$G/bin/ios-clang++', '-isysroot', '$SDK']
objc = ['$G/bin/ios-clang', '-isysroot', '$SDK']
ar = '$(command -v $AR)'
ranlib = '$(command -v $RANLIB)'
strip = '$(command -v $STRIP)'
pkg-config = 'false'

[host_machine]
system = 'darwin'
subsystem = 'ios'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'

[properties]
needs_exe_wrapper = true
INI

DRIVERS=${DRIVERS:-softpipe,freedreno}
B=$M/build-${DRIVERS//,/-}
export PATH=$DEPS/venv/bin:$PATH
# -O3 with debug info (kept in $DSYM, gpu_dsym); no LTO: the theos ld64 cannot read clang 23 bitcode [I].
# A build directory made with other CPU flags is made again (the wrapper's flags are not in ninja's view).
FLAGS_STAMP="$CPU_FLAGS O3 g"
[ "$(cat "$B/.laurel-flags" 2>/dev/null)" = "$FLAGS_STAMP" ] || rm -rf "$B"
if [ ! -f "$B/build.ninja" ]; then
  meson setup "$B" "$S" --cross-file "$M/cross.ini" --wrap-mode=nofallback \
    --prefix=$PREFIX --libdir=lib -Doptimization=3 -Ddebug=true -Db_ndebug=true \
    -Dplatforms= -Dgallium-drivers="$DRIVERS" -Dfreedreno-kmds=msm -Dvulkan-drivers= -Dglx=disabled -Degl=disabled -Dgbm=disabled \
    -Dosmesa=true -Dllvm=disabled -Dshared-glapi=enabled -Dgles1=disabled -Dgles2=enabled -Dopengl=true \
    -Dzstd=disabled -Dxmlconfig=disabled -Dexpat=disabled -Dshader-cache=disabled -Dvalgrind=disabled \
    -Dlibunwind=disabled -Dglvnd=disabled -Dvideo-codecs= -Dtools= -Dgallium-vdpau=disabled -Dgallium-va=disabled \
    -Dgallium-xa=disabled -Dlmsensors=disabled -Dbuild-tests=false > "$M/meson-setup.log" 2>&1 ||
    { tail -30 "$M/meson-setup.log"; gpu_die "meson setup failed (log: $M/meson-setup.log)"; }
  echo "$FLAGS_STAMP" > "$B/.laurel-flags"
fi
echo "mesa-linux: ninja -j$NPROC ($DRIVERS)"
ninja -C "$B" -j"$NPROC" > "$M/ninja.log" 2>&1 || { grep -m 20 -E "error:|FAILED" "$M/ninja.log"; gpu_die "ninja failed (log: $M/ninja.log)"; }

O=$M/out
L=$B/src/gallium/targets/osmesa/libOSMesa.8.dylib
[ -s "$L" ] || gpu_die "no $L"
cp "$L" "$O/libOSMesa.8.dylib"
gpu_dsym "$O/libOSMesa.8.dylib"
"$INSTALL_NAME_TOOL" -id $PREFIX/lib/libOSMesa.8.dylib "$O/libOSMesa.8.dylib"
"$LDID" -S "$O/libOSMesa.8.dylib"
"$NM" -gU "$O/libOSMesa.8.dylib" | awk '$3 ~ /^_gl/ { print substr($3, 2) }' > "$O/exported-gl.txt"
cp "$S/src/mapi/glapi/registry/gl.xml" "$O/gl.xml"
gpu_mesa_inputs | gpu_sha256 > "$O/built-from"
gpu_check_v80 "$O/libOSMesa.8.dylib" || gpu_die "libOSMesa has ARMv8.1+ instructions"
"$NM" -gU "$O/libOSMesa.8.dylib" | grep -q ' _redwood_drm_surface_drawn$' || gpu_die "libOSMesa does not export redwood_drm_surface_drawn"
file "$O/libOSMesa.8.dylib"
echo "mesa-linux: $O/libOSMesa.8.dylib, $(wc -c < "$O/libOSMesa.8.dylib" | tr -d ' ') bytes, $(wc -l < "$O/exported-gl.txt") gl* functions, $(( $(date +%s) - T0 )) s"
