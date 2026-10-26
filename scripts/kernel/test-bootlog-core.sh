#!/bin/sh
# Host unit test of the boot log checks of patch 0367 (write gate, HFS+ end / area start, ctl number
# parser, CRC-32). macOS and Linux (needs cc and zlib headers). Quick, foreground is fine.
#   scripts/kernel/test-bootlog-core.sh [PATCH]
#     PATCH  default patches/xnu/0367-negroni-bootlog.patch
# The header bsd/dev/negroni_bootlog_core.h is taken from the patch (a new file there), so the test
# checks exactly the code that goes into the kernel. Test source: tools/bootlog-core-test/.
set -eu
. "$(dirname "$0")/../lib/env.sh"
PATCH=${1:-$REPO/patches/xnu/0367-negroni-bootlog.patch}
D=$OUT/bootlog-core-test
rm -rf "$D"
mkdir -p "$D"
awk '/^\+\+\+ b\/bsd\/dev\/negroni_bootlog_core\.h$/ {p=1; next}
     p && /^diff --git / {exit}
     p && /^@@/ {next}
     p && /^\+/ {print substr($0, 2)}' "$PATCH" > "$D/negroni_bootlog_core.h"
[ -s "$D/negroni_bootlog_core.h" ] || { echo "no negroni_bootlog_core.h in $PATCH" >&2; exit 1; }
${CC:-cc} -O2 -Wall -Wextra -I"$D" -o "$D/bootlog_core_test" "$REPO/tools/bootlog-core-test/bootlog_core_test.c" -lz
"$D/bootlog_core_test"
