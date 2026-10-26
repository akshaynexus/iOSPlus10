#!/bin/sh
# Full kernel build (all patches/xnu, with 0277 charge loop, 0278 battery persistence/temperature,
# 0283 thermal trips, 0291 cpufreq floor) + the power test image, under the shared kernel lock
# out/kernel/.lock (held across both steps, as the agent rules require).
#   scripts/bg.sh pwr-build scripts/battery/build-pwr-image.sh [NAME] [BOOTARGS]
#     NAME     image dir suffix: out/ios16-NAME (default pwr)
#     BOOTARGS added to the config args (default: the charger/battery test set below)
#   lut variant: scripts/battery/build-pwr-image.sh pwr-lut "<default args> negronicpufreq_floor=lut"
# Output: out/kernel/local-<time>/kernel.development.negroni (link out/kernel/kernel.macho), out/ios16-NAME/.
# Fails when a patches/xnu patch did not apply (build-local.sh only prints it).
# IMAGE=0: the kernel only (no scripts/ios16/build.sh), e.g. a proof build for a review fix.
set -eu
. "$(dirname "$0")/../lib/env.sh"
NAME=${1:-pwr}
ARGS=${2:-"negronibatt=5 negroniadsp=1 negronichg_glink=1 negronichg_ma=1500 negronifb_sleep=0 negronipanic=30 negronipanicreason=2"}
L=$OUT/kernel/.lock
until mkdir "$L" 2>/dev/null; do sleep 30; done
trap 'rmdir "$L" 2>/dev/null || true' EXIT
"$REPO/scripts/kernel/build-local.sh"
K=$(readlink "$OUT/kernel/kernel.macho")
R=$OUT/kernel/$(dirname "$K")/patch-report.txt
for p in 0277 0278 0283 0291; do
  grep -q "^Applying $p-" "$R" || { echo "ERROR: $p not applied (see $R)" >&2; exit 1; }
done
if grep -qE "^Skipping 0[2-9][0-9][0-9]-" "$R"; then echo "ERROR: a patches/xnu patch was skipped (see $R)" >&2; exit 1; fi
if [ "${IMAGE:-1}" = 0 ]; then shasum -a 256 "$OUT/kernel/$K"; exit 0; fi
IOS16_OUT=$OUT/ios16-$NAME BOOTARGS_ADD="$ARGS" "$REPO/scripts/ios16/build.sh"
shasum -a 256 "$OUT/kernel/$K" "$OUT/ios16-$NAME/boot_a.img"
