#!/bin/sh
# Full kernel build (all patches/xnu) + the fingerprint test image, under the shared kernel lock
# out/kernel/.lock (held across both steps, as the agent rules require).
#   scripts/bg.sh fp-build scripts/fp/build-test-image.sh
# Output: out/kernel/local-<time>/kernel.development.negroni (link out/kernel/kernel.macho), out/ios16-fp/.
set -eu
. "$(dirname "$0")/../lib/env.sh"
L=$OUT/kernel/.lock
until mkdir "$L" 2>/dev/null; do sleep 30; done
trap 'rmdir "$L" 2>/dev/null || true' EXIT
scripts/kernel/build-local.sh
IOS16_OUT=$OUT/ios16-fp BOOTARGS_ADD="negronifp=2 negronifp_hl=1 negronipanic=30 negronipanicreason=2" scripts/ios16/build.sh
shasum -a 256 "$OUT/kernel/kernel.macho" "$OUT/ios16-fp/boot_a.img"
