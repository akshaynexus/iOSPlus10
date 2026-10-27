#!/bin/sh
# Reference sources for patch 0383 (CPU cluster idle + RPMh sleep/wake sets + sleep stats): extends the sparse
# checkout of the OnePlus kernel (out/src/op-kernel, made by scripts/setup/fetch-oneplus-sources.sh) with the
# RPMh RSC driver, the RPMh client API, cmd-db, the rpmh clocks/power domains and the sleep-stats drivers.
# Linux code is a reference only; nothing of it runs in XNU.
#   scripts/bg.sh fetch-rpmh scripts/setup/fetch-rpmh-sleep-sources.sh
set -eu
. "$(dirname "$0")/../lib/env.sh"
K=$OUT/src/op-kernel
[ -d "$K/.git" ] || { echo "no $K: run scripts/setup/fetch-oneplus-sources.sh first" >&2; exit 1; }
git -C "$K" sparse-checkout add 'drivers/soc/qcom/rpmh*' 'drivers/soc/qcom/cmd-db.c' 'drivers/soc/qcom/*stats*' \
  'drivers/soc/qcom/trace-rpmh.h' 'drivers/clk/qcom/clk-rpmh.c' 'drivers/soc/qcom/rpmhpd.c' \
  'drivers/regulator/rpmh-regulator.c' 'include/soc/qcom/rpmh.h' 'include/soc/qcom/tcs.h' \
  'drivers/cpuidle/*' 'kernel/time/tick-broadcast*.c' 'drivers/clocksource/arm_arch_timer.c'
git -C "$K" checkout -q HEAD
ls "$K/drivers/soc/qcom/" | grep -E 'rpmh|stats|cmd-db'

# Gunyah (the hypervisor under XNU on SM8450): its virtual PSCI for the VM's CPU_SUSPEND (PC and OSI variants)
G=$OUT/src/gunyah
mkdir -p "$G"
for f in hyp/vm/psci/src/psci_common.c hyp/vm/psci/aarch64/src/psci.c hyp/vm/psci_osi/src/psci_osi.c \
  hyp/vm/psci_pc/src/psci_pc.c hyp/vm/psci/include/psci_common.h hyp/platform/psci_smc/src/psci_smc.c \
  hyp/core/idle/src/idle.c hyp/vm/vpm_base/src/vpm_group.c hyp/vm/psci/psci.tc hyp/vm/psci_osi/psci_osi.tc; do
  mkdir -p "$G/$(dirname "$f")"
  curl -fsSL --retry 3 -o "$G/$f" "https://raw.githubusercontent.com/quic/gunyah-hypervisor/254727746fce809aba0e629a13711a954b246968/$f"
done
ls -R "$G" | head -40
