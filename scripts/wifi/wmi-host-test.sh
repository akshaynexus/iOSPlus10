#!/bin/sh
# Host test of the Wi-Fi patches 0320-0323 (patches/xnu/tests/wlan-wmi-test.c): QMI WLAN_CFG / WLAN_MODE /
# HOST_CAP(gpios) encodings, HTC READY / header / trailer parsers, WMI TLV walk, 802.11 beacon parser.
#   scripts/wifi/wmi-host-test.sh TREE     (TREE: a patched xnu tree with 0320-0323, patched-tree.sh)
# macOS or Linux with cc (clang or gcc) and ASan. Builds in a temp dir, removes it after.
set -eu
. "$(dirname "$0")/../lib/env.sh"
TREE=${1:?usage: wmi-host-test.sh TREE}
D=$TREE/bsd/dev
for f in negroni_wlan_qmi.c negroni_wlan_qmi.h negroni_wlfw_tables.h negroni_wlan_ce.c negroni_wlan_ce.h \
    negroni_wlan_wmi.c negroni_wlan_wmi.h; do
  [ -f "$D/$f" ] || { echo "no $D/$f (0320-0323 not in the tree)" >&2; exit 1; }
done
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
cp "$D/negroni_wlan_qmi.h" "$D/negroni_wlfw_tables.h" "$D/negroni_wlan_ce.h" "$D/negroni_wlan_wmi.h" "$W/"
hdr='#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <errno.h>'
{ echo "$hdr"; echo '#include "negroni_wlan_qmi.h"'
  awk '/generic QMI TLV coder/{f=1;next} /=+ WLFW client =+/{f=0} f' "$D/negroni_wlan_qmi.c"; } > "$W/codec.c"
{ echo "$hdr"; echo '#include "negroni_wlan_ce.h"'
  awk '/==== pure HTC READY parser/{f=1;next} /==== end of the pure parser ====/{f=0} f' "$D/negroni_wlan_ce.c"; } > "$W/ready.c"
{ echo "$hdr"; echo '#include "negroni_wlan_ce.h"'; echo '#include "negroni_wlan_wmi.h"'
  awk '/==== pure parsers/{f=1;next} /==== end of the pure parsers ====/{f=0} f' "$D/negroni_wlan_wmi.c"; } > "$W/wmi.c"
${CC:-cc} -std=gnu11 -g -O1 -fsanitize=address,undefined -fno-sanitize-recover=all -DARM64_BOARD_CONFIG_NEGRONI \
  -I"$W" "$REPO/patches/xnu/tests/wlan-wmi-test.c" "$W/codec.c" "$W/ready.c" "$W/wmi.c" -o "$W/t" \
  -Wno-unused-function -Wno-unused-const-variable
"$W/t"
