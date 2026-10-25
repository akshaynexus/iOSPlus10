#!/bin/bash
# Shallow, sparse clones of the audio reference sources into out/src/ (git-ignored).
#   scripts/bg.sh audio-src scripts/audio/fetch-sources.sh
# macOS and Linux: needs git >= 2.27 (partial clone + sparse checkout).
# Output: out/src/<name>/ (only the audio paths are checked out) and out/src/COMMITS.txt
# (repo, branch, commit: cite these in docs/notes.md "Audio").
# Licences: the Qualcomm/OnePlus kernel code and Linux are GPL-2.0: read them, do not paste
# them into the XNU tree. Write our own code from the protocol and cite the file.
set -euo pipefail
. "$(dirname "$0")/../lib/env.sh"
S=$OUT/src
mkdir -p "$S"

# name url branch sparse-patterns (non-cone, gitignore syntax); branch "-" = the default branch
clone() {
  local name=$1 url=$2 branch=$3; shift 3
  local b=(--branch "$branch")
  [ "$branch" != - ] || b=()
  if [ ! -d "$S/$name/.git" ]; then
    git clone -q --depth 1 --filter=blob:none --no-checkout "${b[@]+"${b[@]}"}" "$url" "$S/$name"
  fi
  git -C "$S/$name" sparse-checkout set --no-cone "$@"
  git -C "$S/$name" checkout -q "$( [ "$branch" = - ] && git -C "$S/$name" rev-parse --abbrev-ref HEAD || echo "$branch")"
  printf '%s %s %s\n' "$name" "$branch" "$(git -C "$S/$name" rev-parse HEAD)" >> "$S/COMMITS.txt.new"
}
rm -f "$S/COMMITS.txt.new"

# OnePlus official SM8450 (OxygenOS 16 = the phone's build NE2211_16.0.3.530): audio-kernel
# (AudioReach/GPR drivers, waipio machine driver), the oplus TFA98xx driver, the DTs.
OP_BR=oneplus/sm8450_b_16.0_oneplus_10_pro
clone op-modules https://github.com/OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_sm8450 "$OP_BR" \
  '*audio*' '*tfa98*' '*tfa9874*' '*sia81*' '*aw882*' '*waipio*.dts*' '*waipio*.dtsi' '*negroni*'
clone op-kernel https://github.com/OnePlusOSS/android_kernel_oneplus_sm8450 "$OP_BR" \
  '/drivers/soc/qcom/smp2p*' '/drivers/rpmsg/*' '/drivers/remoteproc/qcom_q6v5*' '/net/qrtr/*' \
  '/drivers/soc/qcom/qcom_aoss.c' '/drivers/soc/qcom/smem.c' '/drivers/mailbox/qcom-ipcc.c' \
  '/include/linux/soc/qcom/*' '*tfa98*'

# LineageOS kernel (same base, cleaned up).
clone lineage-kernel https://github.com/LineageOS/android_kernel_oneplus_sm8450 lineage-22.2 \
  '*audio*' '*tfa98*' '/drivers/soc/qcom/smp2p*' '/drivers/rpmsg/*' '/net/qrtr/*'

# Linux upstream (mainline AudioReach, GPR, GLINK, QRTR, PAS, TFA989x).
clone linux https://github.com/torvalds/linux - \
  '/drivers/remoteproc/qcom_q6v5*' '/drivers/remoteproc/qcom_common.*' '/drivers/soc/qcom/smp2p.c' \
  '/drivers/soc/qcom/smem.c' '/drivers/soc/qcom/apr.c' '/drivers/soc/qcom/qcom_aoss.c' \
  '/drivers/soc/qcom/pdr_*' '/drivers/soc/qcom/qcom_pd_mapper.c' '/drivers/soc/qcom/qmi_*' \
  '/drivers/rpmsg/qcom_glink*' '/drivers/rpmsg/rpmsg_internal.h' '/drivers/mailbox/qcom-ipcc.c' \
  '/net/qrtr/*' '/include/linux/soc/qcom/*' '/include/uapi/linux/qrtr.h' '/include/dt-bindings/soc/qcom,gpr.h' \
  '/include/dt-bindings/sound/qcom,q6dsp-lpass-ports.h' '/include/dt-bindings/sound/qcom,q6afe.h' \
  '/include/uapi/sound/snd_ar_tokens.h' '/sound/soc/qcom/qdsp6/*' '/sound/soc/qcom/sm8250.c' \
  '/sound/soc/qcom/sc8280xp.c' '/sound/soc/qcom/common.*' '/sound/soc/codecs/tfa989x.c' \
  '/sound/soc/codecs/tas2562.c' '/drivers/i2c/busses/i2c-qcom-geni.c' \
  '/drivers/soc/qcom/mdt_loader.c' '/drivers/firmware/qcom/qcom_scm.c' '/drivers/firmware/qcom/qcom_scm.h' \
  '/drivers/soc/qcom/qcom-geni-se.c' '/drivers/pinctrl/qcom/pinctrl-sm8450-lpass-lpi.c' '/drivers/pinctrl/qcom/pinctrl-sm8450.c'

# AudioReach topology (Linaro): mainline topology sources and the graph IDs.
clone audioreach-topology https://github.com/linux-msm/audioreach-topology - '*'

# AudioReach SPF (Qualcomm, BSD-3-Clause-Clear): the module/param API headers of the DSP side
# (hw_ep TDM/I2S, APM, PRM), and graph services (the ACDB file format and its reader, GSL).
clone audioreach-engine https://github.com/Audioreach/audioreach-engine - '*.h' '*.md' '/LICENSE*'
clone audioreach-graphservices https://github.com/Audioreach/audioreach-graphservices - '*'

mv "$S/COMMITS.txt.new" "$S/COMMITS.txt"
cat "$S/COMMITS.txt"
du -sh "$S"/* || true
