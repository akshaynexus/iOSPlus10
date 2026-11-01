#!/bin/bash
# Turnip (the same patched Mesa tree as the phone: HackiOS ir3 patches, userland/turnip, userland/laurel/metal/turnip-patches) built for this Linux host with Mesa's drm-shim:
# FD_GPU_ID=610 + LD_PRELOAD=libfreedreno_noop_drm_shim.so gives a fake msm kernel with the Adreno 610's device row. vkCreate*Pipelines runs the real SPIR-V -> NIR -> ir3 -> A610 code.
# No GPU runs, no pixel exists. Used by scripts/ios26/ir3-check.sh. Linux only. In tmux: scripts/bg.sh ios26-turnip-host scripts/ios26/turnip-host.sh
# Output: out/ios26/turnip-host/{libvulkan_freedreno.so,libfreedreno_noop_drm_shim.so,icd.json}
set -euo pipefail
. "$(cd "$(dirname "$0")/../laurel" && pwd)/metal-env.sh"
H=$OUT/ios26/turnip-host
TU=$OUT/gpu/turnip/mesa-25.0.7          # scripts/laurel/metal-build.sh turnip
[ -f "$TU/TURNIP-SOURCE" ] || { echo "turnip-host: no patched tree $TU: scripts/laurel/metal-build.sh turnip" >&2; exit 1; }
S=$H/mesa
mkdir -p "$H"
if [ ! -f "$S/.laurel-source" ] || ! cmp -s "$S/.laurel-source" "$TU/TURNIP-SOURCE"; then
  rm -rf "$S" "$H/build"
  cp -a "$TU" "$S"
  cp "$TU/TURNIP-SOURCE" "$S/.laurel-source"
fi
# the shim has no A610 row: the numbers of the laurel kernel (chip 0x06010000, GMEM 132 KiB), as scripts/laurel/mesa-host-bench.sh
N=$S/src/freedreno/drm-shim/freedreno_noop.c
grep -q 'gpu_id = 610' "$N" || sed -i 's|^static const struct msm_device_info device_infos\[\] = {|&\n   { .gpu_id = 610, .chip_id = CHIPID(6, 1, 0, 0xff), .gmem_size = 132 * 1024, },|' "$N"
# a newer glibc has its own once_flag and call_once in stdlib.h: the host's copy of Mesa's C11 header goes around them
T=$S/src/c11/threads.h
grep -q mesa_once_flag "$T" || sed -i 's|^#define C11_THREADS_H_INCLUDED_|&\n#include <stdlib.h>\n#undef ONCE_FLAG_INIT\n#define once_flag mesa_once_flag\n#define call_once mesa_call_once|' "$T"
if [ ! -f "$H/build/build.ninja" ]; then
  env -u SDK -u TU_CPU_FLAGS meson setup "$H/build" "$S" -Dbuildtype=release -Db_ndebug=true -Dplatforms= -Dglx=disabled -Degl=disabled -Dgbm=disabled \
    -Dgles1=disabled -Dgles2=disabled -Dopengl=false -Dshared-glapi=disabled -Dvulkan-drivers=freedreno -Dgallium-drivers= \
    -Dfreedreno-kmds=msm -Dllvm=disabled -Dtools=drm-shim -Dvalgrind=disabled -Dlibunwind=disabled -Dzstd=disabled -Dglvnd=disabled \
    -Dgallium-vdpau=disabled -Dgallium-va=disabled -Dgallium-xa=disabled -Dgallium-rusticl=false -Dbuild-tests=false \
    -Dperfetto=false -Dexpat=disabled -Dosmesa=false -Dvulkan-layers= -Dvideo-codecs= -Dshader-cache=disabled -Dxmlconfig=disabled > "$H/meson.log" 2>&1 || { tail -30 "$H/meson.log"; exit 1; }
fi
ninja -C "$H/build" -j"$NPROC" > "$H/ninja.log" 2>&1 || { tail -30 "$H/ninja.log"; exit 1; }
cp "$(find "$H/build" -name 'libvulkan_freedreno.so' | head -1)" "$H/"
cp "$(find "$H/build" -name 'libfreedreno_noop_drm_shim.so' | head -1)" "$H/"
cat > "$H/icd.json" <<JSON
{ "ICD": { "api_version": "1.3.0", "library_path": "$H/libvulkan_freedreno.so" }, "file_format_version": "1.0.0" }
JSON
ls -la "$H"/*.so
