#!/bin/sh
# Host test of the cellular QMI client of patch 2760 (bsd/dev/laurel_cell.c): a simulated modem answers
# UIM / DMS / NAS / WDS requests; 8 scenarios (one SIM in low power, dual SIM with secondary provisioning,
# online + registration + hot swap with the IPA self-check forced on, no UIM service, UIM silent, cell=0,
# modem never READY, no SIM). macOS and Linux (needs cc). Quick, foreground is fine.
#   scripts/laurel/test-cell.sh [PATCH]
#     PATCH  default patches/laurel/xnu/2760-laurel-cellular-qmi.patch
# laurel_cell.c is taken from the patch (a new file there), so the test checks exactly the kernel code.
# Test source: tools/laurel-cell-test/.
set -eu
. "$(dirname "$0")/../lib/env.sh"
PATCH=${1:-$REPO/patches/laurel/xnu/2760-laurel-cellular-qmi.patch}
D=$OUT/laurel-cell-test
T=$REPO/tools/laurel-cell-test
rm -rf "$D"
mkdir -p "$D/inc/sys" "$D/inc/kern" "$D/inc/pexpert"
awk '/^\+\+\+ b\/bsd\/dev\/laurel_cell\.c$/ {p=1; next}
     p && /^diff / {exit}
     p && /^@@/ {next}
     p && /^\+/ {print substr($0, 2)}' "$PATCH" > "$D/laurel_cell.c"
[ -s "$D/laurel_cell.c" ] || { echo "no bsd/dev/laurel_cell.c in $PATCH" >&2; exit 1; }
for h in sys/param.h sys/systm.h sys/errno.h sys/sysctl.h kern/clock.h kern/locks.h pexpert/pexpert.h; do
  echo '#include "kstub.h"' > "$D/inc/$h"
done
${CC:-$(command -v clang || echo cc)} -O1 -g -Wall -Wextra -Werror -Wno-unused-function -I"$D/inc" -I"$T" -I"$D" \
  -o "$D/cell_test" "$T/cell_test.c"
"$D/cell_test"
