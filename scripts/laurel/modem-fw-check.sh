#!/bin/sh
# Check a Mi A3 modem firmware image the way the kernel reads it (laurel patch 2400: FAT index of
# modem_<active slot>). Read-only; nothing is copied into the repo.
#   scripts/laurel/modem-fw-check.sh [IMAGE]
#   IMAGE: NON-HLOS.bin of the stock ROM (default ~/laurel-backup/stock/images/NON-HLOS.bin)
#          or a dump of the phone's modem_b partition.
# Prints the summary line the phone logs ("TopazModem: firmware: modem_b ...: FAT16, ...") and,
# for each file the Wi-Fi path needs, size / first cluster / runs / CRC-32. Exit 1 if one is missing.
set -eu
. "$(dirname "$0")/../lib/env.sh"
IMG=${1:-$HOME/laurel-backup/stock/images/NON-HLOS.bin}
[ -f "$IMG" ] || { echo "modem-fw-check: no $IMG" >&2; exit 1; }
OP=$REPO/tools/op10tool/target/release/op10tool
(cd "$REPO/tools/op10tool" && cargo build --release -q)
# modem.mdt + every split segment, the WLAN firmware, the board data files, the ADSP loader's mdt
files=$("$OP" fatls "$IMG" | awk 'NR > 1 { print $NF }' |
  grep -E '^image/(modem\.(mdt|b[0-9]+)|wlanmdsp\.mbn|bdwlan\..*|adsp\.mdt)$' || true)
# shellcheck disable=SC2086
"$OP" fatls "$IMG" image/modem.mdt image/wlanmdsp.mbn image/bdwlan.bin $files | awk '!seen[$0]++'
