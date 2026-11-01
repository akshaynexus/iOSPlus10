#!/bin/bash
# Pinned copies of the public AWDL and AirDrop code that docs/laurel_sprout/airdrop-awdl.md reads. Reference only: nothing here is built or run,
# and nothing from these trees goes into the kernel or the root without its license (LICENSES/, docs/airdrop-plan.md "License note").
#   scripts/bg.sh awdl-src scripts/debug/awdl-sources.sh     -> out/awdl-src/<name>, out/awdl-src/PINS.txt
# Each tree is checked out at its pin; a pin that no longer exists stops that tree only. Works on macOS and Linux (needs git, curl).
set -uo pipefail
here=$(cd "$(dirname "$0")/../.." && pwd)
W=$here/out/awdl-src
mkdir -p "$W"
: > "$W/PINS.txt"
fail=0

fetch() {  # name url sha
  local n=$1 url=$2 sha=$3 d=$W/$1
  if [ "$(git -C "$d" rev-parse HEAD 2>/dev/null)" = "$sha" ]; then
    echo "$n $sha (have)"
  else
    rm -rf "$d"
    mkdir -p "$d"
    git -C "$d" init -q
    git -C "$d" remote add origin "$url"
    if git -C "$d" fetch -q --depth 1 origin "$sha" && git -C "$d" -c advice.detachedHead=false checkout -q FETCH_HEAD; then
      echo "$n $sha"
    else
      echo "$n: FAILED at $sha" >&2
      fail=1
      return
    fi
  fi
  echo "$n $url $sha" >> "$W/PINS.txt"
}

# name                 url                                                        pin (2026-11-01)
fetch owly             https://github.com/t4t5/owly.git                           0f2ca4087e6d938d823e76c856fcd04d0a0162b6   # MIT; was omdrop-owl
fetch omdrop-awdl      https://github.com/netmojo-systems/omdrop-awdl.git         46ed6e17f0850fa258f37b1000737a53cb425b2b   # Broadcom BCM4387
fetch omdrop-plugin    https://github.com/netmojo-systems/omdrop-plugin.git       0ac99a8c469e67a3fd15934d985fe0de0cc8abb0   # MIT; AirDrop stack
fetch brcmfmac-awdl    https://github.com/andreanicassio/brcmfmac-awdl.git        ab96d9d75a5fe68c24fad05bdc8e2f96d3c19e5a   # ISC
fetch omdrop-bcm4360   https://github.com/bydash-xyz/omdrop-bcm4360.git           9c21284a5d9dcc7cca76bada5c3b3568fb6ac025   # GPL-2.0
fetch owl-windows      https://github.com/dantdmdarealguy/omdrop-owl-windows.git  441920466d8e388a60fe339e22cf26a8df497dda   # GPL-3.0; ESP32 as the radio
fetch owl              https://github.com/seemoo-lab/owl.git                      0ee3263f944ea721c355f826aa90d636d012a512   # GPL-3.0
fetch opendrop         https://github.com/seemoo-lab/opendrop.git                 11fe7ba7861093b302bc0637e8cb10adf2d29337   # GPL-3.0

# qcacld-3.0 frame injection on this chip family: single files of DX4GREY/kernel_xiaomi_beryllium (Poco F1, WCN3990), pin = merge of PR 1
QC=$W/qcacld-inject
QS=ad88d2a21e6f6d651188fde9534da3f372956a73
mkdir -p "$QC"
for f in drivers/staging/qcacld-3.0/core/wma/src/wma_frame_inject.c drivers/staging/qcacld-3.0/core/hdd/src/wlan_hdd_frame_inject.c \
  drivers/staging/qcacld-3.0/core/hdd/inc/wlan_hdd_frame_inject.h drivers/staging/qcacld-3.0/core/hdd/src/wlan_hdd_frame_validate.c \
  drivers/staging/qcacld-3.0/core/wma/src/wma_dev_if.c drivers/staging/qcacld-3.0/core/hdd/src/wlan_hdd_inject_security.c; do
  [ -s "$QC/${f##*/}" ] || curl -fsSL -o "$QC/${f##*/}" "https://raw.githubusercontent.com/DX4GREY/kernel_xiaomi_beryllium/$QS/$f" || { echo "qcacld-inject: $f FAILED" >&2; fail=1; }
done
echo "qcacld-inject https://github.com/DX4GREY/kernel_xiaomi_beryllium $QS" >> "$W/PINS.txt"

# NetSPI's report on Quick Share + AirDrop, linked from Google's post (not code)
[ -s "$W/netspi-google-feature-review-report.pdf" ] ||
  curl -fsSL -o "$W/netspi-google-feature-review-report.pdf" https://www.netspi.com/wp-content/uploads/2025/11/google-feature-review-report.pdf || fail=1
du -sh "$W"
exit $fail
