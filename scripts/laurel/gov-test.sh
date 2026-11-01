#!/bin/sh
# Host test of the Mi A3 CPU governor decision (patch 2890: bsd/dev/laurel_gov_core.h). macOS and Linux. Under 1 s, foreground.
#   scripts/laurel/gov-test.sh [PATCH]
# The header comes from the patch (a new file there), so the test checks the code that goes into the kernel.
set -eu
. "$(dirname "$0")/../lib/env.sh"
PATCH=${1:-$REPO/patches/laurel/xnu/2890-laurel-cpu-response.patch}
D=$OUT/gov-test
rm -rf "$D"
mkdir -p "$D"
awk '/^\+\+\+ b\/bsd\/dev\/laurel_gov_core\.h/ {p=1; next}
     p && /^diff / {exit}
     p && /^@@/ {next}
     p && /^\+/ {print substr($0, 2)}' "$PATCH" > "$D/laurel_gov_core.h"
[ -s "$D/laurel_gov_core.h" ] || { echo "gov-test: no laurel_gov_core.h in $PATCH" >&2; exit 1; }
${CC:-cc} -O2 -Wall -Wextra -Werror -I"$D" -o "$D/gov_test" "$REPO/tools/gov-test/gov_test.c"
"$D/gov_test"
