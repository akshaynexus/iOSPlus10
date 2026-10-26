#!/bin/sh
# Bluetooth reference sources (read only; git-ignored under out/src). Adds sparse paths to the
# partial clones that scripts/setup/fetch-oneplus-sources.sh and the audio/Wi-Fi scripts made.
#   scripts/bt/fetch-sources.sh        (network; run with scripts/bg.sh bt-src ...)
# out/src/linux      (torvalds/linux):  hci_qca.c, btqca.[ch], btbcm.[ch] + hci_bcm.c (Broadcom vendor
#                                       opcodes for the 0333 shim), qcom_geni_serial.c, geni-se,
#                                       gcc-sm8450, pinctrl-sm8450, clk-rpmh, icc sm8450
# out/src/op-kernel  (OnePlus sm8450):  msm_geni_serial.c, qcom-geni-se.c, pinctrl-waipio.c, btpower.c
# out/src/op-modules (OnePlus modules): the btpower DT binding
set -eu
. "$(dirname "$0")/../lib/env.sh"
S=$OUT/src
add() {
  r=$1; shift
  [ -d "$S/$r/.git" ] || { echo "missing $S/$r (scripts/setup/fetch-oneplus-sources.sh, scripts/audio/fetch-sources.sh)" >&2; exit 1; }
  git -C "$S/$r" sparse-checkout add "$@"
  git -C "$S/$r" checkout -q
}
add linux \
  /drivers/bluetooth/hci_qca.c /drivers/bluetooth/btqca.c /drivers/bluetooth/btqca.h \
  /drivers/bluetooth/hci_uart.h /drivers/bluetooth/hci_h4.c \
  /drivers/tty/serial/qcom_geni_serial.c /drivers/soc/qcom/qcom-geni-se.c \
  /include/linux/soc/qcom/geni-se.h /drivers/clk/qcom/gcc-sm8450.c /drivers/clk/qcom/clk-rpmh.c /drivers/clk/qcom/clk-rcg2.c /drivers/clk/qcom/clk-branch.c \
  /include/dt-bindings/clock/qcom,gcc-sm8450.h /drivers/pinctrl/qcom/pinctrl-sm8450.c \
  /drivers/interconnect/qcom/sm8450.c /drivers/interconnect/qcom/sm8450.h \
  /include/net/bluetooth/hci.h /drivers/soc/qcom/qcom-geni-se.c \
  /drivers/bluetooth/btbcm.c /drivers/bluetooth/btbcm.h /drivers/bluetooth/hci_bcm.c
add op-kernel \
  /drivers/tty/serial/msm_geni_serial.c /drivers/soc/qcom/qcom-geni-se.c \
  /include/linux/qcom-geni-se.h /drivers/pinctrl/qcom/pinctrl-waipio.c \
  /drivers/bluetooth/btpower.c /include/linux/btpower.h
add op-modules /kernel_platform/qcom/proprietary/devicetree/bindings/bluetooth/btpower.txt
for f in linux/drivers/bluetooth/hci_qca.c linux/drivers/bluetooth/btqca.c \
         op-kernel/drivers/tty/serial/msm_geni_serial.c op-kernel/drivers/bluetooth/btpower.c; do
  [ -e "$S/$f" ] && echo "ok $f" || echo "MISSING $f"
done
