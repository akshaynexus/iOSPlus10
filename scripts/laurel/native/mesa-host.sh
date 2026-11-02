#!/bin/bash
# Native Metal stack, host side: Mesa 25.0.7 (the same patched tree as the phone's Turnip) built for this Linux host with drm-shim and Mesa's freedreno tools.
# Gives: libfreedreno_noop_drm_shim.so, Turnip for the reference capture, cffdump + rddecompiler (command stream decoders), and the static compiler libraries (NIR, vtn, ir3, fdl) that the native tests link.
# No GPU runs here. Input: scripts/ios26/turnip-host.sh has made out/ios26/turnip-host/mesa. Output: out/ios26/native/mesa-host.
#   scripts/bg.sh nmn-mesa scripts/laurel/native/mesa-host.sh
set -euo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/metal-env.sh"
S=$OUT/ios26/turnip-host/mesa
B=$OUT/ios26/native/mesa-host
[ -f "$S/meson.build" ] || { echo "mesa-host: no $S: scripts/ios26/turnip-host.sh first" >&2; exit 1; }
mkdir -p "$(dirname "$B")"
if [ ! -f "$B/build.ninja" ]; then
  env -u SDK -u TU_CPU_FLAGS meson setup "$B" "$S" -Dbuildtype=release -Db_ndebug=false -Dplatforms= -Dglx=disabled -Degl=disabled -Dgbm=disabled \
    -Dgles1=disabled -Dgles2=disabled -Dopengl=false -Dshared-glapi=disabled -Dvulkan-drivers=freedreno -Dgallium-drivers= \
    -Dfreedreno-kmds=msm -Dllvm=disabled -Dtools=drm-shim,freedreno -Dvalgrind=disabled -Dlibunwind=disabled -Dzstd=disabled -Dglvnd=disabled \
    -Dgallium-vdpau=disabled -Dgallium-va=disabled -Dgallium-xa=disabled -Dgallium-rusticl=false -Dbuild-tests=false \
    -Dperfetto=false -Dexpat=disabled -Dosmesa=false -Dvulkan-layers= -Dvideo-codecs= -Dshader-cache=disabled -Dxmlconfig=disabled
fi
ninja -C "$B" -j"$NPROC" src/freedreno/decode/cffdump src/freedreno/decode/rddecompiler src/freedreno/vulkan/libvulkan_freedreno.so src/freedreno/drm-shim/libfreedreno_noop_drm_shim.so \
  src/freedreno/ir3/libfreedreno_ir3.a src/freedreno/fdl/libfreedreno_layout.a src/freedreno/common/libfreedreno_common.a src/compiler/nir/libnir.a src/compiler/spirv/libvtn.a \
  src/compiler/libcompiler.a src/util/libmesa_util.a src/freedreno/isa/libir3decode.a src/freedreno/isa/libir3encode.a src/compiler/isaspec/libisaspec.a
ls -la "$B/src/freedreno/decode/cffdump" "$B/src/freedreno/decode/rddecompiler"
