#!/bin/bash
# Host tests of the native Metal stack: winsys against the fake kernel. Exit 0 only if all pass. No GPU, no phone.
#   scripts/bg.sh nmn-test scripts/laurel/native/test.sh [winsys]
set -euo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/metal-env.sh"
N=$REPO/userland/laurel/metal-native
S=$OUT/gpu/turnip/mesa-25.0.7
W=$OUT/ios26/native/test
mkdir -p "$W"
B=$OUT/gpu/turnip/build-ios
CF="-O1 -g -Wall -Wextra -Wno-unused-parameter -fsanitize=address,undefined -I$N/winsys -I$N/tests -I$S/include -I$S/src/freedreno/common -I$B/src/freedreno/registers/adreno -I$B/src/freedreno/registers"
for t in ${*:-winsys option}; do
  case $t in
  winsys)
    # the table in git is what Mesa's register file says
    python3 -I "$REPO/scripts/laurel/native/addr-regs.py" "$S/src/freedreno/registers/adreno/a6xx.xml" --header | diff - "$N/winsys/nw_addr_regs.h"
    clang -std=gnu11 $CF "$N/tests/test_winsys.c" "$N/tests/fake_kernel.c" "$N/winsys/nw.c" "$N/winsys/nw_check.c" -lpthread -o "$W/test_winsys"
    "$W/test_winsys"
    ;;
  option)
    "$REPO/scripts/laurel/option-rule-test.sh"
    ;;
  *) echo "test.sh: $t?" >&2; exit 2 ;;
  esac
done
