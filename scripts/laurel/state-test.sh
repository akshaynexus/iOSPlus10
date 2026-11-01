#!/bin/sh
# Host test of the boot state table (macOS and Linux, foreground, under 2 s): laurel_state_core.h comes from the patch, so the test checks the code that goes into the kernel. ASan + UBSan.
#   scripts/laurel/state-test.sh
set -eu
. "$(dirname "$0")/../lib/env.sh"
P=$REPO/patches/laurel/xnu/2951-laurel-boot-state.patch
D=$OUT/laurel/state-test
rm -rf "$D"; mkdir -p "$D"
awk -v f="+++ b/bsd/dev/laurel_state_core.h" '$0 == f {p=1; next}
     p && /^diff / {exit}
     p && /^@@/ {next}
     p && /^\+/ {print substr($0, 2)}' "$P" > "$D/laurel_state_core.h"
[ -s "$D/laurel_state_core.h" ] || { echo "state-test: no core header in $P" >&2; exit 1; }
# strlcpy: stock on macOS and glibc 2.38; else a copy for the test only
cat > "$D/compat.h" <<'H'
#include <stdio.h>
#include <string.h>
#ifndef __APPLE__
#undef strlcpy
static inline size_t t_strlcpy(char *d, const char *s, size_t n) { size_t l = strlen(s); if (n) { size_t c = l >= n ? n - 1 : l; memcpy(d, s, c); d[c] = 0; } return l; }
#define strlcpy t_strlcpy
#endif
H
cp "$REPO/scripts/laurel/state-test.c" "$D/test.c"
${CC:-cc} -g -O1 -Wall -Wextra -fsanitize=address,undefined -fno-sanitize-recover=undefined -include "$D/compat.h" -I"$D" -o "$D/test" "$D/test.c"
ASAN_OPTIONS=detect_leaks=0 "$D/test"
