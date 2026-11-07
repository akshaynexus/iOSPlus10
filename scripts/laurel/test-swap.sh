#!/bin/bash
# Host test of laurel 3080 (LAUREL SWAP): the decision that the kernel runs (osfmk/vm/laurel_swap_core.h, taken out of
# patches/laurel/xnu/3080-laurel-swap.patch) for every compressor mode, with and without the kill switch and a vm_compressor= boot-arg.
# Seconds; no device.
set -eu
REPO=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
python3 -I - "$REPO/patches/laurel/xnu/3080-laurel-swap.patch" "$T/laurel_swap_core.h" <<'PY'
import sys
out = []; take = False
for line in open(sys.argv[1]):
    if line.startswith('+++ b/osfmk/vm/laurel_swap_core.h'):
        take = True; continue
    if take and (line.startswith('diff ') or line.startswith('--- a/')):
        break
    if take and line.startswith('+'):
        out.append(line[1:])
open(sys.argv[2], 'w').write(''.join(out))
assert out, 'no laurel_swap_core.h in the patch'
PY
cat > "$T/t.c" <<'C'
#include <stdio.h>
#include <string.h>
#include "laurel_swap_core.h"
static int fails;
static void t(uint32_t mode, bool en, bool hand, uint32_t want, const char *why_want) {
    const char *why = NULL; uint32_t got = laurel_swap_decide(mode, en, hand, &why);
    int ok = got == want && why && strcmp(why, why_want) == 0;
    printf("%s mode 0x%02x enabled %d by_hand %d -> 0x%02x (%s)%s\n", ok ? "ok  " : "FAIL", mode, en, hand, got, why ? why : "(null)", ok ? "" : " want 0x");
    if (!ok) fails++;
}
int main(void) {
    /* the Mi A3 kernels: iOS 26 (NO_SWAP) and iOS 16 without CONFIG_FREEZE (NOT_CONFIGURED) go to COMPRESSOR_WITH_SWAP */
    t(LSW_COMPRESSOR_NO_SWAP, true, false, LSW_COMPRESSOR_WITH_SWAP, "compressor without swap");
    t(LSW_NOT_CONFIGURED, true, false, LSW_COMPRESSOR_WITH_SWAP, "compressor without swap");
    t(LSW_DEFAULT, true, false, LSW_COMPRESSOR_WITH_SWAP, "compressor without swap");
    /* a freezer kernel keeps its freezer and gains the swap file */
    t(LSW_FREEZER_NO_SWAP, true, false, LSW_FREEZER_WITH_SWAP, "freezer without swap");
    t(LSW_FREEZER_DEFAULT, true, false, LSW_FREEZER_WITH_SWAP, "freezer without swap");
    /* already with swap: unchanged */
    t(LSW_COMPRESSOR_WITH_SWAP, true, false, LSW_COMPRESSOR_WITH_SWAP, "already with swap");
    t(LSW_FREEZER_WITH_SWAP, true, false, LSW_FREEZER_WITH_SWAP, "already with swap");
    /* kill switch: every mode stays */
    for (uint32_t m = 0; m <= 0x20; m = m ? m << 1 : 1) t(m, false, false, m, "laurelswap=0");
    /* vm_compressor= by hand: every mode stays */
    for (uint32_t m = 0; m <= 0x20; m = m ? m << 1 : 1) t(m, true, true, m, "vm_compressor= set by hand");
    printf("test-swap: %s (%d failures)\n", fails ? "FAIL" : "PASS", fails);
    return fails ? 1 : 0;
}
C
cc -std=c11 -Wall -Wextra -Werror -I"$T" -o "$T/t" "$T/t.c"
"$T/t"
