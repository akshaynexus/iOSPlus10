#!/bin/bash
# Native Metal stack: copies the closed Adreno files of the owner's stock backup to out/ios26/native/closed, as a reference on this computer (owner decision 2026-11-03).
# Nothing from here goes into git: no blob, no disassembly, no image. docs/laurel_sprout/ios26-native-metal.md records facts in our words, with file and offset.
#   scripts/bg.sh nmn-closed scripts/laurel/native/closed-refs.sh
set -euo pipefail
. "$(cd "$(dirname "$0")/../../lib" && pwd)/env.sh"
V=${STOCK_VENDOR:-$HOME/laurel-backup/stock/images/vendor.img}
C=$OUT/ios26/native/closed
mkdir -p "$C"
R=$C/vendor.raw
trap 'rm -f "$R"' EXIT
simg2img "$V" "$R"
mkdir -p "$C/lib64/egl" "$C/lib64/hw" "$C/firmware"
for f in lib64/egl/libGLESv2_adreno.so lib64/egl/libEGL_adreno.so lib64/egl/eglSubDriverAndroid.so lib64/hw/vulkan.adreno.so \
         lib64/libgsl.so lib64/libllvm-glnext.so lib64/libadreno_utils.so lib64/libadreno_app_profiles.so \
         firmware/a610_zap.mdt firmware/a610_zap.b00 firmware/a610_zap.b01 firmware/a610_zap.b02 firmware/a630_sqe.fw; do
  debugfs -R "dump /$f $C/$f" "$R" >/dev/null 2>&1 || true
  [ -s "$C/$f" ] || { rm -f "$C/$f"; echo "closed-refs: no /$f in this image"; }
done
rm -f "$R"; trap - EXIT
find "$C" -type f -printf '%s %P\n' | sort -k2
