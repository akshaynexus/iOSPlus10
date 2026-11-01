#!/bin/sh
# Host test of the Bluetooth firmware choice and checks (bsd/dev/laurel_bt_fw.c, laurel 2600/2601) against the
# real files of the stock BTFM.bin (FAT image). The C file comes from the patch (no kernel build needed); the
# firmware is copied to out/bt-fw/ (git-ignored, never commit it).
#   scripts/laurel/bt-fw-test.sh [BTFM.bin]      default ~/laurel-backup/stock/images/BTFM.bin
# Cases: the Mi A3 chip (product 0x000f rom 0x0102 soc 0x40070120: WCN3950 family, cmbtfw12 + cmnv12) and a
# WCN3990 (product 0x000a rom 0x0201: crbtfw21 + crnv21). Needs cc, python3, mtools (mcopy).
set -eu
REPO=$(cd "$(dirname "$0")/../.." && pwd)
BTFM=${1:-$HOME/laurel-backup/stock/images/BTFM.bin}
W=$REPO/out/bt-fw
PATCH=$REPO/patches/laurel/xnu/2600-laurel-bluetooth-wcn3990.patch
[ -f "$BTFM" ] || { echo "bt-fw-test: no $BTFM" >&2; exit 1; }
command -v mcopy >/dev/null || { echo "bt-fw-test: needs mtools (mcopy)" >&2; exit 1; }
mkdir -p "$W/fw" "$W/src/sys"
for f in $(mdir -b -i "$BTFM" ::/image | sed 's|.*/||'); do
  case "$f" in *.tlv|*.bin) mcopy -o -n -i "$BTFM" "::/image/$f" "$W/fw/$f" ;; esac
done
# the new files of the patch, as the patch has them
python3 -I - "$PATCH" "$W/src" bsd/dev/laurel_bt_fw.c bsd/dev/laurel_bt.h <<'EOF'
import re, sys
patch, out, want = sys.argv[1], sys.argv[2], sys.argv[3:]
for part in re.split(r'(?m)^(?=diff -ruN )', open(patch).read()):
    m = re.match(r'diff -ruN a/(\S+) ', part)
    if m and m.group(1) in want:
        body = [l[1:] for l in part.split('\n')[4:] if l.startswith('+')]
        open(out + '/' + m.group(1).split('/')[-1], 'w').write('\n'.join(body) + '\n')
EOF
printf '#include <string.h>\n#include <stdio.h>\n' > "$W/src/sys/systm.h"
cc -O1 -Wall -Wno-unused-function -DARM64_BOARD_CONFIG_SWEET -I"$W/src" -o "$W/bt-fw-test" \
  "$REPO/scripts/laurel/bt-fw-test.c" "$W/src/laurel_bt_fw.c"
rc=0
echo "== Mi A3 chip: product 0x000f rom 0x0102 soc 0x40070120"
"$W/bt-fw-test" "$W/fw" 0x000f 0x0102 0x40070120 | tee "$W/mia3.txt" || rc=1
grep -q 'result: on: cmbtfw12.tlv + cmnv12.bin' "$W/mia3.txt" || { echo "bt-fw-test: FAIL (Mi A3 case)"; rc=1; }
echo "== WCN3990: product 0x000a rom 0x0201 soc 0x40010214"
"$W/bt-fw-test" "$W/fw" 0x000a 0x0201 0x40010214 | tee "$W/wcn3990.txt" || rc=1
grep -q 'result: on: crbtfw21.tlv + crnv21.bin' "$W/wcn3990.txt" || { echo "bt-fw-test: FAIL (WCN3990 case)"; rc=1; }
echo "== unknown product 0x00ee: must stay off"
if "$W/bt-fw-test" "$W/fw" 0x00ee 0x0102 0x40070120; then echo "bt-fw-test: FAIL (accepted)"; rc=1; fi
[ $rc = 0 ] && echo "bt-fw-test: all cases pass"
exit $rc
