#!/bin/bash
# Host test of the pure Wi-Fi code in patches 2405 + 2407 (LaurelWifiPhy.h, LaurelWifiLink.h): an AP's elements in,
# mode, width, centre and peer arguments out; our elements; the WMM values; the rate table. No phone, no kernel.
#   scripts/laurel/wifi-phy-test.sh
set -euo pipefail
. "$(dirname "$0")/../lib/env.sh"
T=$OUT/wifi-phy-test
mkdir -p "$T"
sed -n '/^@@/,$ s/^+//p' "$REPO"/patches/laurel/xnu/2405-laurel-wifi-phy-header.patch > "$T/LaurelWifiPhy.h"
sed -n '/^@@/,$ s/^+//p' "$REPO"/patches/laurel/xnu/2407-laurel-wifi-link-header.patch > "$T/LaurelWifiLink.h"
${CC:-cc} -std=gnu11 -Wall -Wextra -Werror -g -fsanitize=address,undefined -I"$T" -o "$T/wifi-phy-test" "$REPO/scripts/laurel/wifi-phy-test.c"
"$T/wifi-phy-test"
