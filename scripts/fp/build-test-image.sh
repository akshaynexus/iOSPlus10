#!/bin/sh
# Full kernel build (all patches/xnu) + a fingerprint test image, under the shared kernel lock
# out/kernel/.lock (held across both steps, as the agent rules require).
#   scripts/bg.sh fp-build scripts/fp/build-test-image.sh [NAME] [BOOTARGS]
#     NAME     image dir suffix: out/ios16-NAME (default fp3)
#     BOOTARGS added to the config args (default: the stage-C probe
#              "negronifp=3 negronifp_hl=2 negronipanic=30 negronipanicreason=2")
#   Stage A/B image: scripts/fp/build-test-image.sh fp "negronifp=2 negronifp_hl=1 negronipanic=30 negronipanicreason=2"
#   KERNEL_ONLY=1 scripts/fp/build-test-image.sh      kernel build only (proof build, no image)
#   Capture image:   scripts/fp/build-test-image.sh fp4 "negronifp=4 negronifp_hl=2 negronifb_te=1 negronipanic=30 negronipanicreason=2"
#   (0354: negronifp_hl only allows the overlay: the disc shows in the capture with a finger on the sensor, the
#    lock-screen glyph with FPD=1 root-finish; nothing from boot)
# Output: out/kernel/local-<time>/kernel.development.negroni (link out/kernel/kernel.macho), out/ios16-NAME/.
set -eu
. "$(dirname "$0")/../lib/env.sh"
NAME=${1:-fp3}
ARGS=${2:-"negronifp=3 negronifp_hl=2 negronipanic=30 negronipanicreason=2"}
L=$OUT/kernel/.lock
until mkdir "$L" 2>/dev/null; do sleep 30; done
trap 'rmdir "$L" 2>/dev/null || true' EXIT
scripts/kernel/build-local.sh
[ "${KERNEL_ONLY:-0}" = 1 ] && { shasum -a 256 "$OUT/kernel/kernel.macho"; exit 0; }
IOS16_OUT=$OUT/ios16-$NAME BOOTARGS_ADD="$ARGS" scripts/ios16/build.sh
shasum -a 256 "$OUT/kernel/kernel.macho" "$OUT/ios16-$NAME/boot_a.img"
