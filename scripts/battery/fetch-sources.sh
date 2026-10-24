#!/bin/bash
# Fetch the public reference sources for the battery work (patches/xnu/README-battery.md) into
# out/research/battery/ (git-ignored). Read-only research input; nothing is built or run from it.
#   scripts/bg.sh batt-src scripts/battery/fetch-sources.sh     (macOS and Linux: needs curl)
set -uo pipefail
. "$(dirname "$0")/../lib/env.sh"
D=$OUT/research/battery
mkdir -p "$D"
U=https://raw.githubusercontent.com/torvalds/linux/master
L=https://raw.githubusercontent.com/LineageOS/android_kernel_qcom_sm8450/lineage-21
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
# Qualcomm downstream (GKI 5.10, SM8450): BCL (PM8350B VBAT/IBAT) and the battmgr client
for f in drivers/thermal/qcom/bcl_pmic5.c drivers/power/supply/qti_battery_charger.c drivers/soc/qcom/pmic_glink.c; do
  get "$L/$f" "down-$(basename "$f")" &
done
wait
ls -l "$D"
