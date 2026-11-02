#!/bin/bash
# Host tests of the native Metal stack: winsys against the fake kernel. Exit 0 only if all pass. No GPU, no phone.
#   scripts/bg.sh nmn-test scripts/laurel/native/test.sh [winsys]
set -euo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/metal-env.sh"
N=$REPO/userland/laurel/metal-native
S=$OUT/ios26/turnip-host/mesa
W=$OUT/ios26/native/test
mkdir -p "$W"
CF="-O1 -g -Wall -Wextra -Wno-unused-parameter -fsanitize=address,undefined -I$N/winsys -I$N/tests -I$S/include -I$S/src/freedreno/common"
for t in ${*:-winsys option}; do
  case $t in
  winsys)
    clang -std=gnu11 $CF "$N/tests/test_winsys.c" "$N/tests/fake_kernel.c" "$N/winsys/nw.c" -lpthread -o "$W/test_winsys"
    "$W/test_winsys"
    ;;
  option)
    "$REPO/scripts/laurel/option-rule-test.sh"
    ;;
  *) echo "test.sh: $t?" >&2; exit 2 ;;
  esac
done
