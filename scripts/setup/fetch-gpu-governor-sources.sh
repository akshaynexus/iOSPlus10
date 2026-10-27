#!/bin/sh
# Reference sources for patch 0389 (GPU DCVS modelled on Qualcomm's msm_adreno_tz + KGSL pwrscale): extends the sparse
# checkout of the OnePlus kernel (out/src/op-kernel, made by scripts/setup/fetch-oneplus-sources.sh; OnePlusOSS
# android_kernel_oneplus_sm8450 branch oneplus/sm8450_b_16.0_oneplus_10_pro, pinned commit below) with the GPU devfreq
# governors and KGSL power scaling. GPL-2.0 code; a port keeps the SPDX line and names this commit.
#   scripts/bg.sh fetch-gpugov scripts/setup/fetch-gpu-governor-sources.sh
set -eu
. "$(dirname "$0")/../lib/env.sh"
K=$OUT/src/op-kernel
PIN=e9da592    # "Synchronize code for OnePlus ... NE2211_16.0.3.520(EX01)", QCOM AU_LINUX_KERNEL.PLATFORM.1.0.R1.00.00.00.000.130
[ -d "$K/.git" ] || { echo "no $K: run scripts/setup/fetch-oneplus-sources.sh first" >&2; exit 1; }
head=$(git -C "$K" rev-parse --short=7 HEAD)
[ "$head" = "$PIN" ] || { echo "op-kernel is at $head, not the pinned $PIN" >&2; exit 1; }
git -C "$K" sparse-checkout add '/drivers/gpu/msm/governor_msm_adreno_tz.c' '/drivers/gpu/msm/governor_gpubw_mon.c' \
  '/drivers/gpu/msm/msm_adreno_devfreq.h' '/drivers/gpu/msm/kgsl_pwrscale.*' '/drivers/gpu/msm/kgsl_bus.*' \
  '/drivers/gpu/msm/kgsl_pwrctrl.h' '/drivers/devfreq/governor.h' '/drivers/firmware/qcom_scm.c' '/drivers/firmware/qcom_scm.h' \
  '/drivers/firmware/qcom_scm-smc.c' '/include/linux/qcom_scm.h'
git -C "$K" checkout -q HEAD
ls -l "$K/drivers/gpu/msm/governor_msm_adreno_tz.c" "$K/drivers/gpu/msm/governor_gpubw_mon.c" \
  "$K/drivers/gpu/msm/msm_adreno_devfreq.h" "$K/drivers/gpu/msm/kgsl_pwrscale.c" "$K/drivers/gpu/msm/kgsl_bus.c"
