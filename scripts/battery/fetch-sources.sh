#!/bin/bash
# Fetch the public reference sources for the battery work (patches/xnu/README-battery.md) into
# out/research/battery/ (git-ignored). Read-only research input; nothing is built or run from it.
#   scripts/bg.sh batt-src scripts/battery/fetch-sources.sh     (macOS and Linux: needs curl)
set -uo pipefail
. "$(dirname "$0")/../lib/env.sh"
D=$OUT/research/battery
mkdir -p "$D"
U=https://raw.githubusercontent.com/torvalds/linux/master
get() { # URL FILE
  if [ -s "$D/$2" ]; then echo "have $2"; return; fi
  if curl -sfL --max-time 120 -o "$D/$2.part" "$1"; then mv "$D/$2.part" "$D/$2"; echo "ok   $2"; else rm -f "$D/$2.part"; echo "FAIL $1"; fi
}
for f in drivers/power/supply/qcom_battmgr.c drivers/soc/qcom/pmic_glink.c drivers/iio/adc/qcom-spmi-adc5.c \
         drivers/iio/adc/qcom-vadc-common.c include/linux/iio/adc/qcom-vadc-common.h drivers/spmi/spmi-pmic-arb.c \
         include/dt-bindings/iio/qcom,spmi-adc7-pm8350b.h include/dt-bindings/iio/qcom,spmi-adc7-pmk8350.h \
         include/dt-bindings/iio/qcom,spmi-vadc.h; do
  get "$U/$f" "$(basename "$f")" &
done
# Qualcomm downstream (GKI 5.10, SM8450) as OnePlus ships it for the 10 Pro: BCL (PM8350B VBAT/IBAT),
# the battmgr client, the ADC_TM driver (the LineageOS sm8450 tree has no drivers/thermal/qcom/bcl_pmic5.c)
K=https://raw.githubusercontent.com/OnePlusOSS/android_kernel_oneplus_sm8450/oneplus/sm8450_v_15.0.0_oneplus_10_pro
for f in drivers/thermal/qcom/bcl_pmic5.c drivers/power/supply/qti_battery_charger.c drivers/soc/qcom/pmic_glink.c \
         drivers/thermal/qcom/adc-tm5.c drivers/iio/adc/qcom-spmi-adc5-gen3.c; do
  get "$K/$f" "down-$(basename "$f")" &
done
# OnePlus official SM8450 source (OnePlus 10 Pro branch): the OPLUS charger over pmic_glink
O=https://raw.githubusercontent.com/OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_sm8450/oneplus/sm8450_v_15.0.0_oneplus_10_pro
for f in vendor/oplus/kernel/charger/charger_ic/oplus_battery_sm8450.c vendor/oplus/kernel/charger/charger_ic/oplus_battery_sm8450.h \
         vendor/oplus/kernel/charger/gauge_ic/oplus_bq27541.c vendor/oplus/kernel/charger/gauge_ic/oplus_bq27541.h; do
  get "$O/$f" "op-$(basename "$f")" &
done
wait
ls -l "$D"
