#!/bin/sh
# Reference sources for patches 0287 (GPU hang recovery) and 0288 (CPU idle): extends the sparse checkout of
# the OnePlus kernel (out/src/op-kernel, made by scripts/setup/fetch-oneplus-sources.sh) with the KGSL
# dispatcher/fault code and the cpuidle/PSCI drivers. Linux code is a reference only; nothing of it runs in XNU.
#   scripts/bg.sh fetch-gpur scripts/setup/fetch-gpur-cpuidle-sources.sh
set -eu
. "$(dirname "$0")/../lib/env.sh"
K=$OUT/src/op-kernel
[ -d "$K/.git" ] || { echo "no $K: run scripts/setup/fetch-oneplus-sources.sh first" >&2; exit 1; }
git -C "$K" sparse-checkout add 'drivers/gpu/msm/adreno_dispatch.*' 'drivers/gpu/msm/adreno.c' \
  'drivers/gpu/msm/adreno_hwsched.*' 'drivers/gpu/msm/kgsl_iommu.c' 'drivers/gpu/msm/adreno_snapshot.c' \
  'drivers/cpuidle/*' 'drivers/cpuidle/governors/*' 'drivers/firmware/psci/*' 'include/linux/psci.h' \
  'include/uapi/linux/psci.h' 'arch/arm64/kernel/cpuidle.c' 'arch/arm64/kernel/psci.c'
git -C "$K" checkout -q HEAD
ls "$K/drivers/gpu/msm/adreno_dispatch.c" "$K/drivers/cpuidle" "$K/drivers/cpuidle/governors" "$K/drivers/firmware/psci"
