#!/bin/sh
# Host test of DarwinWindowTop (laurel mu 0104: DarwinBootPkg/Driver/WindowTop.h, the UEFI memory above the XNU window). macOS and Linux, under 1 s.
#   scripts/laurel/test-darwinboot-top.sh [PATCH]
# The header comes from the patch, so the test checks the text that goes into DarwinBoot.
set -eu
. "$(dirname "$0")/../lib/env.sh"
PATCH=${1:-$REPO/patches/laurel/mu/0104-darwinboot-window-top.patch}
D=$OUT/darwinboot-top-test
rm -rf "$D"
mkdir -p "$D"
awk '/^\+\+\+ b\/DarwinBootPkg\/Driver\/WindowTop\.h/ {p=1; next}
     p && /^diff / {exit}
     p && /^@@/ {next}
     p && /^\+/ {print substr($0, 2)}' "$PATCH" > "$D/WindowTop.h"
[ -s "$D/WindowTop.h" ] || { echo "test-darwinboot-top: no WindowTop.h in $PATCH" >&2; exit 1; }
${CC:-cc} -O2 -Wall -Wextra -Werror -I"$D" -o "$D/test" "$REPO/tools/darwinboot-top-test/test.c"
"$D/test"
