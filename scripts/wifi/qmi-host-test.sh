#!/bin/sh
# Host test of the Wi-Fi QMI coder (0266) and QRTR decoder (0265): patches/xnu/tests/wlan-qmi-test.c.
#   scripts/wifi/qmi-host-test.sh TREE     (TREE: a patched xnu tree with 0265/0266, patched-tree.sh)
# macOS or Linux with cc (clang or gcc) and ASan. Builds in a temp dir, removes it after.
set -eu
. "$(dirname "$0")/../lib/env.sh"
TREE=${1:?usage: qmi-host-test.sh TREE}
D=$TREE/bsd/dev
for f in negroni_wlan_qmi.c negroni_wlan_qmi.h negroni_wlfw_tables.h negroni_wlan_qrtr.c negroni_wlan_qrtr.h; do
  [ -f "$D/$f" ] || { echo "no $D/$f (0265/0266 not in the tree)" >&2; exit 1; }
done
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
cp "$D/negroni_wlan_qmi.h" "$D/negroni_wlfw_tables.h" "$W/"
hdr='#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <errno.h>'
{ echo "$hdr"; echo '#include "negroni_wlan_qmi.h"'
  awk '/generic QMI TLV coder/{f=1;next} /=+ WLFW client =+/{f=0} f' "$D/negroni_wlan_qmi.c"; } > "$W/codec.c"
{ echo "$hdr"; echo '#define WLAN_TX_LEN 0x2000u'; echo 'struct mhi_host;'
  sed -n '/^#define QRTR_PROTO_VER_1/,/^};/p' "$D/negroni_wlan_qrtr.h"
  echo 'int negroni_qrtr_parse(const uint8_t *buf, uint32_t len, struct qrtr_pkt *out);'
  awk '/^static inline uint32_t$/{f=1} /^\/\* MHI channel 21 callback/{f=0} f' "$D/negroni_wlan_qrtr.c"; } > "$W/qrtrparse.c"
${CC:-cc} -std=gnu11 -g -O1 -fsanitize=address,undefined -fno-sanitize-recover=all -DARM64_BOARD_CONFIG_NEGRONI \
  -I"$W" "$REPO/patches/xnu/tests/wlan-qmi-test.c" "$W/codec.c" "$W/qrtrparse.c" -o "$W/t" -Wno-unused-function
"$W/t"
