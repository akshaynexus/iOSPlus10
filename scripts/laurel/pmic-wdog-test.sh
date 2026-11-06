#!/bin/sh
# laurel 3030 / mu 0202: host test of the PMIC watchdog: the rules header of the kernel patch, built with the host compiler, and the same numbers in the
# UEFI side (tools/laurel-slot/uefi/LaurelPmicWdog.c). Result: PASS, exit 0.
set -eu
REPO=$(cd "$(dirname "$0")/../.." && pwd)
. "$REPO/scripts/lib/env.sh"
D=$OUT/pmic-wdog-test
rm -rf "$D"; mkdir -p "$D"
P=$REPO/patches/laurel/xnu/3030-laurel-pmic-wdog.patch
python3 -I - "$P" "$D/laurel_pmic_wdog_core.h" <<'PY'
import re, sys
t = open(sys.argv[1]).read()
m = re.search(r'^\+\+\+ b/bsd/dev/laurel_pmic_wdog_core\.h[^\n]*\n@@[^\n]*\n((?:\+[^\n]*\n)+)', t, re.M)
if not m:
    sys.exit('the core header is not in the patch')
open(sys.argv[2], 'w').write(''.join(l[1:] + '\n' for l in m[1].splitlines()))
PY
cc -std=c11 -Wall -Wextra -Werror -I"$D" -o "$D/pmic-wdog-test" "$REPO/tools/pmic-wdog-test/pmic-wdog-test.c"
"$D/pmic-wdog-test"
# the UEFI side carries the same registers and times: every LPW_ define it has must equal the kernel's
U=$REPO/tools/laurel-slot/uefi/LaurelPmicWdog.c
bad=0
for name in $(sed -n 's/^#define \(LPW_[A-Z0-9_]*\).*/\1/p' "$U"); do
  k=$(sed -n "s/^#define $name[[:space:]][[:space:]]*\([0-9a-fx]*\)u\?.*/\1/p" "$D/laurel_pmic_wdog_core.h")
  u=$(sed -n "s/^#define $name[[:space:]][[:space:]]*\([0-9a-fx]*\)u\?.*/\1/p" "$U")
  [ -n "$k" ] || { echo "FAIL: $name is in the UEFI side only"; bad=1; continue; }
  [ "$((k))" = "$((u))" ] || { echo "FAIL: $name: kernel $k, UEFI $u"; bad=1; }
done
[ "$bad" = 0 ] || exit 1
echo "pmic-wdog: the UEFI side matches the kernel header: $(sed -n 's/^#define \(LPW_[A-Z0-9_]*\).*/\1/p' "$U" | wc -l) defines"
echo PASS
