#!/bin/bash
# The CPU cost of Mesa's flush on this GPU's limits, measured on the host: Mesa 25.0.7 (same archive as the phone) built for
# Linux, freedreno + drm-shim (no GPU: submissions end at once), FD_GPU_ID=610 with GMEM 132 KiB. It answers one question that
# a host can answer: how the CPU time of a CoreAnimation-like frame moves with GMEM tiles or direct rendering. Absolute numbers are
# this host's, not the A73's. Not used by the phone build.
#   scripts/bg.sh lag-mesahost scripts/laurel/mesa-host-bench.sh
# Output: out/laurel/gpu-host/, the table goes to stdout. Source of the frame: userland/laurel/gpu/tests/flush_bench.c
set -euo pipefail
. "$(dirname "$0")/gpu-env.sh"
H=$OUT/laurel/gpu-host
S=$H/mesa-$MESA_VERSION
mkdir -p "$H"
[ -f "$DL/mesa-$MESA_VERSION.tar.xz" ] || { mkdir -p "$DL"; curl -fsSL --retry 5 -o "$DL/mesa-$MESA_VERSION.tar.xz" "$MESA_URL"; }
[ "$(sha256sum < "$DL/mesa-$MESA_VERSION.tar.xz" | cut -d' ' -f1)" = "$MESA_SHA256" ] || { echo "mesa-host-bench: archive hash" >&2; exit 1; }
[ -d "$S" ] || tar -xJf "$DL/mesa-$MESA_VERSION.tar.xz" -C "$H"
# the host's shim has no A610 row: the phone's numbers (kernel: chip 0x06010000, GMEM 132 KiB)
N=$S/src/freedreno/drm-shim/freedreno_noop.c
# a newer glibc has its own once_flag and call_once in stdlib.h: the host's copy of Mesa's C11 header goes around them
T=$S/src/c11/threads.h
grep -q mesa_once_flag "$T" || sed -i 's|^#define C11_THREADS_H_INCLUDED_|&\n#include <stdlib.h>\n#undef ONCE_FLAG_INIT\n#define once_flag mesa_once_flag\n#define call_once mesa_call_once|' "$T"
grep -q 'gpu_id = 610' "$N" || sed -i 's|^static const struct msm_device_info device_infos\[\] = {|&\n   { .gpu_id = 610, .chip_id = CHIPID(6, 1, 0, 0xff), .gmem_size = 132 * 1024 },|' "$N"
if [ ! -f "$H/build/build.ninja" ]; then
  meson setup "$H/build" "$S" -Dprefix="$H/inst" -Dbuildtype=release -Db_ndebug=true -Dplatforms= -Dglx=disabled -Degl=enabled -Dgbm=disabled \
    -Dgles1=disabled -Dgles2=enabled -Dopengl=true -Dshared-glapi=enabled -Dvulkan-drivers= -Dgallium-drivers=freedreno \
    -Dfreedreno-kmds=msm -Dllvm=disabled -Dtools=drm-shim -Dvalgrind=disabled -Dlibunwind=disabled -Dzstd=disabled -Dglvnd=disabled \
    -Dgallium-vdpau=disabled -Dgallium-va=disabled -Dgallium-xa=disabled -Dgallium-nine=false -Dgallium-opencl=disabled -Dgallium-rusticl=false \
    -Dperfetto=false -Dexpat=disabled -Dosmesa=false > "$H/meson.log" 2>&1 || { tail -30 "$H/meson.log"; exit 1; }
fi
ninja -C "$H/build" -j"$NPROC" install > "$H/ninja.log" 2>&1 || { tail -30 "$H/ninja.log"; exit 1; }
SHIM=$(find "$H/build" -name 'libfreedreno_noop_drm_shim.so' | head -1)
cc -O2 -o "$H/flush_bench" "$REPO/userland/laurel/gpu/tests/flush_bench.c" -I"$H/inst/include" -L"$H/inst/lib" -Wl,-rpath,"$H/inst/lib" -lEGL -lGLESv2 -lm
run() { # NAME VARS...
  local name=$1; shift
  env "$@" FD_GPU_ID=610 LD_LIBRARY_PATH="$(dirname "$(find "$H/build" -name 'libgallium-*.so' | head -1)"):$H/inst/lib" LD_PRELOAD="$SHIM" LIBGL_DRIVERS_PATH="$H/inst/lib/dri" GALLIUM_DRIVER=freedreno EGL_PLATFORM=surfaceless \
    "$H/flush_bench" "$name"
}
run autotune A=1
run gmem FD_MESA_DEBUG=gmem
run sysmem FD_MESA_DEBUG=sysmem
run autotune-noTC GALLIUM_THREAD=0
run gmem-noTC GALLIUM_THREAD=0 FD_MESA_DEBUG=gmem
run sysmem-noTC GALLIUM_THREAD=0 FD_MESA_DEBUG=sysmem
