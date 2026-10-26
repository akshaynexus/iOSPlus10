#!/bin/sh
# Full kernel build (all patches/xnu, 0289 among them: the IOSurface CPU lock waits for the surface's GPU fence,
# RedwoodWaitsForGPU) + the GL/Metal test image out/ios16-gl2, under the shared kernel lock out/kernel/.lock
# (held across both steps, as the agent rules require: another job relinks out/kernel/kernel.macho otherwise).
#   scripts/bg.sh gl2-build scripts/gpu/build-test-image.sh
# Output: out/kernel/local-<time>/kernel.development.negroni (link out/kernel/kernel.macho), out/ios16-gl2/
# (config boot-args + negronipanic=30 negronipanicreason=2: a panic comes back to fastboot by itself).
# Knobs of 0289 at boot: negronisurf_gpuwait=MS (default 50, 0 = the lock never waits; docs/gpu-abi.md section 9).
set -eu
. "$(dirname "$0")/../lib/env.sh"
L=$OUT/kernel/.lock
until mkdir "$L" 2>/dev/null; do sleep 30; done
trap 'rmdir "$L" 2>/dev/null || true' EXIT
"$REPO/scripts/kernel/build-local.sh"
IOS16_OUT=$OUT/ios16-gl2 BOOTARGS_ADD="${BOOTARGS_ADD:-negronipanic=30 negronipanicreason=2}" "$REPO/scripts/ios16/build.sh"
shasum -a 256 "$OUT/kernel/kernel.macho" "$OUT/ios16-gl2/boot_a.img" "$OUT/ios16-gl2/esp.img" "$OUT/ios16-gl2/vendor_boot_a.img"
