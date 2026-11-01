#!/bin/sh
# Host test of the cellular QMI client of patches 2760 + 2780 + 2786 (bsd/dev/laurel_cell.c): a simulated modem answers
# UIM / DMS / NAS / WDS requests; 15 scenarios (one SIM in low power, dual SIM with secondary provisioning,
# online + registration + hot swap with the IPA state (laurel_ipa_state, patch 2780) forced on, no UIM service, UIM silent, cell=0,
# modem never READY, no SIM; 2786: mode 5 then online, mode error, ONLINE refused, NAS bind retries, bars rule; 2930: mode stays 5 (6 bounded rounds), low power refused, all refused, mode indication; + the
# SpringBoard bridge's parser (userland/laurel/cell/cellbar_state.h) on the kernel's own text). macOS and Linux (needs cc). Quick, foreground is fine.
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
# later patches that change laurel_cell.c (2780: the radio waits for laurel_ipa_state()): their hunks on top
for p in "$REPO"/patches/laurel/xnu/2780-laurel-ipa-v42.patch "$REPO"/patches/laurel/xnu/2786-laurel-cell-radio-state.patch \
    "$REPO"/patches/laurel/xnu/2930-laurel-cell-radio-online.patch "$REPO"/patches/laurel/xnu/2932-laurel-cell-data.patch; do
  [ -f "$p" ] && [ "$PATCH" = "$REPO/patches/laurel/xnu/2760-laurel-cellular-qmi.patch" ] || continue
  awk '/^diff / {p = ($0 ~ /b\/bsd\/dev\/laurel_cell\.c$/)} p' "$p" > "$D/cell-later.diff"
  [ -s "$D/cell-later.diff" ] && (cd "$D" && patch -s -p0 laurel_cell.c < cell-later.diff) ||
    { [ ! -s "$D/cell-later.diff" ] || { echo "test-cell: $(basename "$p") does not apply to laurel_cell.c" >&2; exit 1; }; }
done
for h in sys/param.h sys/systm.h sys/errno.h sys/sysctl.h kern/clock.h kern/locks.h pexpert/pexpert.h; do
  echo '#include "kstub.h"' > "$D/inc/$h"
done
${CC:-$(command -v clang || echo cc)} -O1 -g -Wall -Wextra -Werror -Wno-unused-function -I"$D/inc" -I"$T" -I"$D" -I"$REPO/userland/laurel/cell" \
  -o "$D/cell_test" "$T/cell_test.c"
"$D/cell_test"
