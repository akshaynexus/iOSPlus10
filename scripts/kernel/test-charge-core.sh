#!/bin/sh
# Host unit test of the charge-only mode decisions of patch 0377 (boot decision, power key, unplug,
# screen timer). macOS and Linux (needs cc). Quick, foreground is fine.
#   scripts/kernel/test-charge-core.sh [PATCH]
#     PATCH  default patches/xnu/0377-negroni-charge-mode.patch
# The header bsd/dev/negroni_charge_core.h is taken from the patch (a new file there), so the test
# checks exactly the code that goes into the kernel. Test source: tools/charge-core-test/.
set -eu
. "$(dirname "$0")/../lib/env.sh"
PATCH=${1:-$REPO/patches/xnu/0377-negroni-charge-mode.patch}
D=$OUT/charge-core-test
rm -rf "$D"
mkdir -p "$D"
awk '/^\+\+\+ b\/bsd\/dev\/negroni_charge_core\.h$/ {p=1; next}
     p && /^diff --git / {exit}
     p && /^@@/ {next}
     p && /^\+/ {print substr($0, 2)}' "$PATCH" > "$D/negroni_charge_core.h"
[ -s "$D/negroni_charge_core.h" ] || { echo "no negroni_charge_core.h in $PATCH" >&2; exit 1; }
${CC:-cc} -O2 -Wall -Wextra -Werror -I"$D" -o "$D/charge_core_test" "$REPO/tools/charge-core-test/charge_core_test.c"
"$D/charge_core_test"
