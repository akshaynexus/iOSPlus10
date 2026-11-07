#!/bin/sh
# laurel 3091: host test of the USB RX liveness rules: the header of the kernel patch, built with the host compiler. Result: PASS, exit 0.
set -eu
REPO=$(cd "$(dirname "$0")/../.." && pwd)
. "$REPO/scripts/lib/env.sh"
D=$OUT/usb-check-test
rm -rf "$D"; mkdir -p "$D"
P=$REPO/patches/laurel/xnu/3091-laurel-usb-check.patch
python3 -I - "$P" "$D/laurel_usb_check_core.h" <<'PY'
import re, sys
t = open(sys.argv[1]).read()
m = re.search(r'^\+\+\+ b/bsd/dev/laurel_usb_check_core\.h[^\n]*\n@@[^\n]*\n((?:\+[^\n]*\n)+)', t, re.M)
if not m:
    sys.exit('the core header is not in the patch')
open(sys.argv[2], 'w').write(''.join(l[1:] + '\n' for l in m[1].splitlines()))
PY
cc -std=c11 -Wall -Wextra -Werror -I"$D" -o "$D/usb-check-test" "$REPO/tools/usb-check-test/usb-check-test.c"
"$D/usb-check-test"
# the kernel side: the kill switch, the on line, the panic text and every action are in the patch
for s in 'laurelusbcheck' 'LAUREL USB CHECK: on:' 'LAUREL USB CHECK: off:' 'panic("LAUREL USB CHECK: RX dead' 'case LUC_ASK:' 'case LUC_REARM:' 'case LUC_RESTART:' 'case LUC_BACK:' 'ud_check_poll(now)'; do
  grep -qF -- "$s" "$P" || { echo "FAIL: $s is not in the patch"; exit 1; }
done
# 3090: the hold's default wait and the landing
Q=$REPO/patches/laurel/xnu/3090-laurel-panic-fastboot.patch
for s in 'laurelpanicfb' 'LR_PANIC_SECS_DEFAULT  30' 'LAUREL PANIC LANDING: on:' 'LAUREL PANIC LANDING: off:' 'laurel_reboot_set_mode(laurel_panic_mode())'; do
  grep -qF -- "$s" "$Q" || { echo "FAIL: $s is not in patch 3090"; exit 1; }
done
[ "$(grep -c 'laurel_reboot_set_mode(laurel_panic_mode())' "$Q")" -ge 3 ] || { echo "FAIL: 3090 must set the mode on all three reset paths (hold timeout, no USB, nested)"; exit 1; }
grep -q 'laurel_reboot_set_mode("normal")' "$Q" && grep -q '^-.*laurel_reboot_set_mode("normal")' "$Q" || { echo "FAIL: 3090 must remove the normal-mode resets of the panic path"; exit 1; }
! grep -q '^+.*laurel_reboot_set_mode("normal")' "$Q" || { echo "FAIL: 3090 adds a normal-mode reset"; exit 1; }
echo PASS
