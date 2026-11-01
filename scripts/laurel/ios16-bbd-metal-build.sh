#!/bin/bash
# iOS 16 test option "backboardd on Metal": a cheap check, before the iOS 26 boot, of whether the Adreno 610 can composite on Metal. Never the default: default builds compile none of this.
# Output in its own tree, out/metal-bbd: NegroniMetal.bundle with -DLAUREL_BBD_METAL=1 + flame-bbd, the backboardd wrapper with the same define. Turnip and the bridge are the default ones (not built again).
#   scripts/bg.sh bbd-metal scripts/laurel/ios16-bbd-metal-build.sh       needs a default scripts/laurel/metal-build.sh and scripts/laurel/gpu-userland.sh first
# Install: METAL_BACKBOARDD=1 at the root build (scripts/laurel/root.sh), or scripts/laurel/root-add-bbd-metal.sh MOUNTED_ROOT. Design, fallback, lines: docs/laurel_sprout/ios26-metal.md section 6.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
OUTDIR=$REPO/out
export METAL_OUT=$OUTDIR/metal-bbd
export METAL_EXTRA_FLAME=$REPO/userland/metal/patches/flame-bbd
export METAL_EXPORTS_CACHE=$OUTDIR/metal/spi/exports
export NMTL_EXTRA_FLAGS="-DLAUREL_BBD_METAL=1"
export TURNIP_DYLIB=$OUTDIR/gpu/turnip/libvulkan_freedreno.dylib
[ -f "$TURNIP_DYLIB" ] || { echo "bbd-metal: no default Turnip: scripts/laurel/metal-build.sh" >&2; exit 1; }
[ -f "$OUTDIR/metal/bridge/ios/libnative_metal_bridge.a" ] || { echo "bbd-metal: no default bridge: scripts/laurel/metal-build.sh" >&2; exit 1; }
mkdir -p "$METAL_OUT/bridge/ios"
ln -sf "$OUTDIR/metal/bridge/ios/libnative_metal_bridge.a" "$METAL_OUT/bridge/ios/libnative_metal_bridge.a"
"$HERE/metal-build.sh" fetch
NO_IMPORT_CHECK=${NO_IMPORT_CHECK:-0} "$HERE/metal-build.sh" plugin
# the wrapper, with the flags of scripts/laurel/gpu-userland.sh
[ -n "${SDK:-}" ] || { [ ! -d "$OUTDIR/laurel-metal/sdk/iPhoneOS16.5.sdk" ] || export SDK=$OUTDIR/laurel-metal/sdk/iPhoneOS16.5.sdk; }
. "$HERE/gpu-env.sh"
W=$METAL_OUT/backboardd.wrap
gpu_cc "$W" -DLAUREL_BBD_METAL=1 "$REPO/userland/laurel/gpu/bbd_wrap.c"
gpu_dsym "$W"
"$LDID" -S "$W"
gpu_check_v80 "$W"
B=$METAL_OUT/stage/System/Library/Extensions/NegroniMetal.bundle/NegroniMetal
python3 -I "$REPO/scripts/laurel/armv80-check.py" "$B"
grep -a -c 'LAUREL BBD METAL' "$B" | sed 's/^/bbd-metal: lines in the plug-in: /'
ls -la "$W" "$B"
