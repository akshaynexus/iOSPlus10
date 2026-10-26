#!/bin/sh
# Host unit test of the Bluetooth HCI shim (bsd/dev/negroni_bt_shim.c of patches 0333-0338): the 0338 legacy LE ->
# extended LE translation (command bytes, answer rewrites, advertising chains, report conversion) and the 0337 vendor
# answers. macOS and Linux (needs cc). Quick, foreground is fine.
#   scripts/kernel/test-bt-shim.sh TREE
#     TREE  a patched xnu tree (scripts/kernel/patched-tree.sh OUTDIR [0339]): the test compiles its
#           bsd/dev/negroni_bt_shim.c and negroni_bt.h, so it checks exactly the code that goes into the kernel.
# Test source: tools/bt-shim-test/bt_shim_test.c. Build products: out/bt-shim-test/.
set -eu
. "$(dirname "$0")/../lib/env.sh"
TREE=${1:?usage: test-bt-shim.sh TREE}
SRC=$TREE/bsd/dev
[ -f "$SRC/negroni_bt_shim.c" ] || { echo "no $SRC/negroni_bt_shim.c" >&2; exit 1; }
D=$OUT/bt-shim-test
rm -rf "$D"
mkdir -p "$D/sys"
# kernel headers the shim includes: stand-ins with the libc equivalents
printf '#include <stdio.h>\n#include <string.h>\n#include <strings.h>\n#include <stdint.h>\n#include <stdbool.h>\n#ifndef MIN\n#define MIN(a, b) ((a) < (b) ? (a) : (b))\n#endif\n' > "$D/sys/param.h"
: > "$D/sys/systm.h"
cp "$SRC/negroni_bt.h" "$D/"
build() { ${CC:-cc} -O1 -g -Wall -DARM64_BOARD_CONFIG_NEGRONI "$@" -I"$D" -o "$D/bt_shim_test" \
  "$REPO/tools/bt-shim-test/bt_shim_test.c" "$SRC/negroni_bt_shim.c"; }
build -fsanitize=address,undefined -fno-sanitize-recover=all 2>/dev/null || build
"$D/bt_shim_test" | grep -v '^NEGRONI BT: shim table '
