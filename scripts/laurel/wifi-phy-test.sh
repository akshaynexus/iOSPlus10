#!/bin/bash
# Host test of the pure Wi-Fi code in patches 2405 + 2407 + 2880 + 2930 (LaurelWifiPhy.h, LaurelWifiLink.h, LaurelWifiPath.h, LaurelWifiAwdl.h): an AP's
# elements in, mode, width, centre and peer arguments out; our elements; the WMM values; the rate table; smoothed signal, which
# frames count, iOS's bars against its own arithmetic, when a scan may run while joined, the Tx slots. No phone, no kernel.
#   scripts/laurel/wifi-phy-test.sh
set -euo pipefail
. "$(dirname "$0")/../lib/env.sh"
T=$OUT/wifi-phy-test
mkdir -p "$T"
sed -n '/^@@/,$ s/^+//p' "$REPO"/patches/laurel/xnu/2405-laurel-wifi-phy-header.patch > "$T/LaurelWifiPhy.h"
sed -n '/^@@/,$ s/^+//p' "$REPO"/patches/laurel/xnu/2407-laurel-wifi-link-header.patch > "$T/LaurelWifiLink.h"
sed -n '/^@@/,$ s/^+//p' "$REPO"/patches/laurel/xnu/2880-laurel-wifi-path-header.patch > "$T/LaurelWifiPath.h"
sed -n '/^@@/,$ s/^+//p' "$REPO"/patches/laurel/xnu/2930-laurel-wifi-awdl-header.patch > "$T/LaurelWifiAwdl.h"
${CC:-cc} -std=gnu11 -Wall -Wextra -Werror -g -fsanitize=address,undefined -I"$T" -o "$T/wifi-phy-test" "$REPO/scripts/laurel/wifi-phy-test.c" -lm
"$T/wifi-phy-test"
