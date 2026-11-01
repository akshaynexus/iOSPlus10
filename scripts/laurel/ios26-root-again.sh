#!/bin/sh
# Proof that the root build gives the same bytes: hash the image, build it again (FORCE=1), hash it again, then a third run with the same inputs must stop at "inputs unchanged".
#   scripts/bg.sh ios26-again scripts/laurel/ios26-root-again.sh
set -eu
. "$(dirname "$0")/../lib/env.sh"
I=${APPLE:-$HOME/op10-apple}/ios26/23F84-n104ap/root/ios26-root.img
a=$(sha256sum "$I" | cut -d' ' -f1)
FORCE=1 "$REPO/scripts/laurel/ios26-root.sh"
b=$(sha256sum "$I" | cut -d' ' -f1)
echo "image before $a"
echo "image after  $b"
[ "$a" = "$b" ] || { echo "ios26-root-again: FAILED: the bytes differ"; exit 1; }
"$REPO/scripts/laurel/ios26-root.sh" | grep -E 'inputs unchanged|all checks OK'
echo "ios26-root-again: PASS: same bytes, and the third run left the image"
