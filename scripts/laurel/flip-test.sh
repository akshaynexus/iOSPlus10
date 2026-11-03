#!/bin/sh
# Host test of the flip rules (patches 2981-2982): laurel_flip_core.h as the patch makes it, and the places the patch must touch.
# macOS and Linux (needs cc). Takes a second, foreground is fine.  scripts/laurel/flip-test.sh
set -eu
. "$(dirname "$0")/../lib/env.sh"
P=$REPO/patches/laurel/xnu
D=$OUT/flip-test
rm -rf "$D"; mkdir -p "$D"
A=$P/2981-laurel-flip-not-before-drawn.patch
C=$P/2982-laurel-flip-fence-at-swap.patch
awk '$0 == "+++ b/iokit/Kernel/arm/laurel_flip_core.h" {p=1; next}
     p && /^diff / {exit}
     p && /^@@/ {next}
     p && /^\+/ {print substr($0, 2)}' "$A" > "$D/laurel_flip_core.h"
[ -s "$D/laurel_flip_core.h" ] || { echo "flip-test: no laurel_flip_core.h in $A" >&2; exit 1; }
(cd "$D" && awk '/^diff --git a\/iokit\/Kernel\/arm\/laurel_flip_core\.h/ {p=1} p && /^diff / && !/laurel_flip_core/ {exit} p {print}' "$C" | sed 's#a/iokit/Kernel/arm/##; s#b/iokit/Kernel/arm/##' | patch -s -p0 laurel_flip_core.h)
${CC:-cc} -O2 -Wall -Wextra -Werror -I"$D" -o "$D/flip_test" "$REPO/tools/flip-test/flip_test.c"
"$D/flip_test"
# a refused frame must not release what is on the panel: showDirect returns before fShowHold changes
grep -q '^+		if (!present(rec)) {' "$A" || { echo "flip-test: showDirect does not check present" >&2; exit 1; }
for w in lfl_refuse_not_drawn lfl_swap_older lfl_shown_again; do
  n=$(grep -c "^+.*$w(" "$A")
  [ "$n" -ge 2 ] || { echo "flip-test: $w is not called" >&2; exit 1; }
done
grep -q 'lfl_fence_for_flip(held' "$C" || { echo "flip-test: 2982 does not use the rule" >&2; exit 1; }
echo "flip-test: patch calls the tested rules"
