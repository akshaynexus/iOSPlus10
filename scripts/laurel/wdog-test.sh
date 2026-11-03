#!/bin/sh
# laurel 2986: host test of the watchdog's rules: the header of the patch, built with the host compiler. Result: PASS, exit 0.
set -eu
REPO=$(cd "$(dirname "$0")/../.." && pwd)
. "$REPO/scripts/lib/env.sh"
D=$OUT/wdog-test
rm -rf "$D"; mkdir -p "$D/core"
python3 -I - "$REPO/patches/laurel/xnu/2986-laurel-wdog.patch" "$D/core/laurel_wdog_core.h" <<'PY'
import re, sys
t = open(sys.argv[1]).read()
m = re.search(r'^\+\+\+ b/osfmk/arm64/laurel_wdog_core\.h\n@@[^\n]*\n((?:\+[^\n]*\n)+)', t, re.M)
if not m:
    sys.exit('the core header is not in the patch')
open(sys.argv[2], 'w').write(''.join(l[1:] + '\n' for l in m[1].splitlines()))
PY
cc -std=c11 -Wall -Wextra -Werror -I"$D/core" -o "$D/wdog-test" "$REPO/tools/wdog-test/wdog-test.c"
"$D/wdog-test"
