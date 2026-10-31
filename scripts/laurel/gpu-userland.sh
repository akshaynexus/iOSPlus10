#!/bin/bash
# The iOS-side GPU pieces for the Mi A3, built on Linux (no Mac): CoreAnimation's OpenGL ES renderer in backboardd
# draws through Mesa freedreno on the Adreno 610 (kernel: TopazAdreno + RedwoodGPU, patches topaz 0901-0947 + laurel 2150/2151).
#   scripts/bg.sh laurel-gpu-user scripts/laurel/gpu-userland.sh      (runs mesa-linux.sh first when Mesa is missing or stale)
# Sources: userland/laurel/gpu/bbd_wrap.c (ours: kill switches, crash guard); read-only:
# external/ios-topaz/userland/gpu/{eagl.c,gl_osmesa.c,redwood_gl.h,topaz_inject.c}; the EAGL
# table generator external/hackios-scion/userland/mkeagl.py + src/eagl_slots.txt (the offsets of iOS's OpenGLES dispatch table).
# Output: out/laurel/gpu/root/ = the files root-add-gpu.sh installs, laid out as on the phone:
#   topaz/lib/libOSMesa.8.dylib  topaz/lib/libtopaz-gl.dylib  topaz/lib/libtopaz-inject.dylib  usr/libexec/backboardd.wrap
#   usr/share/firmware/laurel/   (scripts/laurel/gpu-firmware.sh: the phone's own a610_zap + a630_sqe.fw)
set -euo pipefail
. "$(dirname "$0")/gpu-env.sh"
gpu_need_toolchain
gpu_fetch_sdk
U=$TOPAZ/userland/gpu
M=$G/mesa/out
want=$(cat "$TOPAZ"/userland/mesa/*.patch "$TOPAZ"/userland/mesa/redwood-drm/* | gpu_sha256)
if [ ! -s "$M/libOSMesa.8.dylib" ] || [ "$(cat "$M/built-from" 2>/dev/null)" != "$want" ]; then
  echo "gpu-userland: Mesa missing or older than the topaz Mesa patches: scripts/laurel/mesa-linux.sh"
  "$(dirname "$0")/mesa-linux.sh"
fi
O=$G/obj
R=$G/root
rm -rf "$O" "$R"
mkdir -p "$O" "$R$PREFIX/lib" "$R/usr/libexec"

# 1. the EAGL dispatch table: one function per slot of -[EAGLContext getMacroContextPrivate]
python3 -I "$SCION/userland/mkeagl.py" "$SCION/userland/src/eagl_slots.txt" "$M/gl.xml" "$M/exported-gl.txt" "$U/eagl.c" > "$O/eagl_gen.h"
echo "gpu-userland: eagl_gen.h: $(grep -c '^static' "$O/eagl_gen.h" || true) generated functions"

# 2. libtopaz-gl.dylib: OpenGL ES behind EAGLContext (eagl.c) on Mesa's OSMesa (gl_osmesa.c)
gpu_cc "$R$PREFIX/lib/libtopaz-gl.dylib" -dynamiclib -install_name $PREFIX/lib/libtopaz-gl.dylib -I"$O" -I"$U" \
  -framework CoreFoundation -framework IOKit -framework IOSurface -lobjc "$M/libOSMesa.8.dylib" \
  "$U/eagl.c" "$U/gl_osmesa.c" 2> "$O/libtopaz-gl.log" || { cat "$O/libtopaz-gl.log"; gpu_die "libtopaz-gl did not build"; }
# 3. libtopaz-inject.dylib: inserted into backboardd; loads libtopaz-gl once the kernel publishes RedwoodGPU
gpu_cc "$R$PREFIX/lib/libtopaz-inject.dylib" -dynamiclib -install_name $PREFIX/lib/libtopaz-inject.dylib \
  -framework CoreFoundation -framework IOKit -lobjc "$U/topaz_inject.c" 2> "$O/inject.log" ||
  { cat "$O/inject.log"; gpu_die "libtopaz-inject did not build"; }
# 4. the backboardd stand-in (ours): the loader only without gpu=0/gl=0 and after < 2 fast exits, execs /usr/libexec/real/backboardd
gpu_cc "$R/usr/libexec/backboardd.wrap" "$REPO/userland/laurel/gpu/bbd_wrap.c" 2> "$O/bbd.log" ||
  { cat "$O/bbd.log"; gpu_die "bbd_wrap did not build"; }
cp "$M/libOSMesa.8.dylib" "$R$PREFIX/lib/"

# ad-hoc signatures (the kernel's AMFI stand-in accepts them; the code directory hashes must still match)
for f in "$R$PREFIX/lib/libtopaz-gl.dylib" "$R$PREFIX/lib/libtopaz-inject.dylib" "$R/usr/libexec/backboardd.wrap"; do
  "$LDID" -S "$f"
  gpu_check_v80 "$f" || gpu_die "$(basename "$f") has ARMv8.1+ instructions"
done
# every library they load must be on the phone: the iOS shared cache, or /topaz/lib
llvm-objdump --macho --dylibs-used "$R$PREFIX/lib/libtopaz-gl.dylib" | tail -n +2 | grep -vE '^\s+(/usr/lib/|/System/Library/|/topaz/lib/)' &&
  gpu_die "libtopaz-gl links a library that is not on the phone"

F=$G/firmware
if [ -s "$F/a610_zap.mdt" ]; then
  mkdir -p "$R$FW_DIR_ON_PHONE"
  cp "$F"/a610_zap.mdt "$F"/a610_zap.b0* "$R$FW_DIR_ON_PHONE/"
  [ -s "$F/a630_sqe.fw" ] && cp "$F/a630_sqe.fw" "$R$FW_DIR_ON_PHONE/"
else
  echo "gpu-userland: note: no firmware in $F (scripts/laurel/gpu-firmware.sh): the kernel will log 'LAUREL GPU: off: zap shader failed'"
fi
(cd "$R" && find . -type f | sort | { while read -r f; do gpu_sha256_files "$f"; done; } > "$G/root.SHA256SUMS")
(cd "$R" && find . -type f -exec ls -l {} + | awk '{print $5, $9}')
echo "gpu-userland: $R (root-add-gpu.sh installs it)"
