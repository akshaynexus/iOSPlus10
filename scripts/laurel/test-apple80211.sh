#!/bin/bash
# The 23F84 Apple80211 answers of the 12377 kernel, on the host: compiles the real bsd/dev/redwood_apple80211.c of the iOS 26 tree with a fake station side
# (tools/laurel-a80211-test), checks each struct size and field against offsets read in IO80211.framework, then the code words of those offsets in the N104AP cache
# if the cache is here. Host only: it can not show that wifid works on a phone.
#   scripts/laurel/test-apple80211.sh
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
SRC=$REPO/tools/laurel-a80211-test
X=${XNU_TREE:-$REPO/out/laurel-kernel-ios26/src/xnu}
[ -f "$X/bsd/dev/redwood_apple80211.c" ] || { echo "test-apple80211: no $X/bsd/dev/redwood_apple80211.c: run scripts/laurel/kernel-ios26-linux.sh first" >&2; exit 1; }
O=$REPO/out/laurel-a80211-test
rm -rf "$O"; mkdir -p "$O/inc/kern" "$O/inc/libkern" "$O/inc/machine" "$O/inc/sys"
for h in kern/kalloc.h kern/locks.h libkern/libkern.h machine/atomic.h sys/kern_event.h sys/kernel.h sys/proc.h sys/redwood_input.h sys/redwood_net.h sys/sockio.h sys/systm.h; do
  printf '#include "stub.h"\n' > "$O/inc/$h"
done
cp "$X/bsd/sys/redwood_sta.h" "$O/inc/sys/redwood_sta.h"
CC=${CC:-cc}
$CC -std=gnu11 -O1 -g -Wall -Wextra -Wno-unused-parameter -Wno-unused-function -Wno-sign-compare -Wno-format -fsanitize=address,undefined -fno-sanitize-recover=undefined \
  -I"$O/inc" -I"$SRC" -I"$X/bsd/dev" "$SRC/harness.c" -o "$O/harness"
"$O/harness"
python3 -I "$SRC/cache-words.py" "${CACHE_26:-$HOME/op10-apple/ios26/23F84-n104ap/tree/cache/dyld_shared_cache_arm64e}" "$REPO/scripts/ios26/cache-dis.py"
echo "test-apple80211: PASS"
