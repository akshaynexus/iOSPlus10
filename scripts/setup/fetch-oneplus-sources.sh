#!/bin/sh
# Reference sources for power/thermal/charger/GPU-GMU/USB work: extends the sparse checkout of the OnePlus kernel
# (out/src/op-kernel, OnePlusOSS android_kernel_oneplus_sm8450) and adds the OnePlus modules+devicetree repo
# (out/src/op-modules: vendor/oplus/kernel/charger = oplus_chg, display-drivers, the full DTS). Linux code is a
# reference for register programming only; nothing of it runs in XNU. Run in tmux: scripts/bg.sh fetch-oneplus scripts/setup/fetch-oneplus-sources.sh
set -eu
cd /Users/akshaycm/Documents/GitRepos/iOSPlus10
K=out/src/op-kernel
git -C "$K" sparse-checkout add 'drivers/power/supply/*' 'drivers/power/reset/*' 'drivers/thermal/qcom/*' 'drivers/thermal/thermal_core.c' 'drivers/cpufreq/qcom-cpufreq-hw.c' 'drivers/spmi/*' 'drivers/soc/qcom/pmic-pon-log.c' 'drivers/input/misc/qpnp-power-on.c' 'drivers/usb/dwc3/*msm*' 'drivers/usb/dwc3/core.c' 'drivers/gpu/msm/*gmu*' 'drivers/gpu/msm/*gen7*' 'drivers/gpu/msm/kgsl_pwrctrl.c' 'drivers/gpu/msm/adreno-gpulist.h' 'drivers/gpu/msm/adreno_hfi.h' 'drivers/gpu/msm/adreno.h' 'drivers/gpu/msm/adreno_pm4types.h' 'drivers/gpu/msm/kgsl_util.h' 'include/dt-bindings/*'
git -C "$K" checkout -q HEAD
echo "op-kernel added:"; ls "$K/drivers/power/supply" "$K/drivers/thermal/qcom" "$K/drivers/spmi" 2>/dev/null | head -40; ls "$K/drivers/gpu/msm" 2>/dev/null | head -20
M=out/src/op-modules
if [ ! -d "$M/.git" ]; then
  git clone -q --depth 1 --filter=blob:none --no-checkout -b oneplus/sm8450_v_15.0.0_oneplus_10_pro https://github.com/OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_sm8450 "$M" || git clone -q --depth 1 --filter=blob:none --no-checkout https://github.com/OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_sm8450 "$M"
fi
git -C "$M" sparse-checkout set --no-cone 'vendor/oplus/kernel/charger/*' 'vendor/oplus/kernel/charger/**' 'vendor/qcom/opensource/*thermal*/**' 'vendor/oplus/kernel/thermal/**' 'vendor/qcom/proprietary/devicetree-*/qcom/*waipio*' 'vendor/qcom/proprietary/devicetree-*/qcom/*pm8350*' 'vendor/qcom/proprietary/devicetree-*/qcom/*pmk8350*' 'vendor/oplus/kernel/*/devicetree/**' '**/oplus_chg*' '**/*negroni*' '**/*NE2211*' 'vendor/qcom/opensource/display-drivers/**' 2>/dev/null || true
git -C "$M" checkout -q HEAD 2>&1 | tail -2 || true
echo "op-modules:"; du -sh "$M"; find "$M" -maxdepth 4 -type d | head -30
# Charger over GLINK (docs/charger-glink-plan.md): the OnePlus pmic_glink router and Linux mainline pmic_glink + battmgr.
git -C "$K" sparse-checkout add 'drivers/soc/qcom/pmic_glink*' 'drivers/soc/qcom/altmode*' 'include/linux/soc/qcom/*'
git -C "$K" checkout -q HEAD
L=out/src/linux
if [ -d "$L/.git" ]; then
  git -C "$L" sparse-checkout add '/drivers/soc/qcom/pmic_glink*.c' '/drivers/power/supply/qcom_battmgr.c' '/include/linux/soc/qcom/pmic_glink.h'
  git -C "$L" checkout -q HEAD
  ls -l "$L/drivers/soc/qcom/"pmic_glink*.c "$L/drivers/power/supply/qcom_battmgr.c"
fi
