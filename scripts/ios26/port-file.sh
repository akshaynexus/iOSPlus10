#!/bin/bash
# Carry the iOS 16 change of FILE (xnu-8796 pristine -> negroni, trees from scripts/ios26/ios16-ref-tree.sh) to the
# xnu-12377 work tree (default out/kernel/local-ios26/work, a git tree; commit there, export with git diff into
# patches/xnu-12377/NNNN-*.patch). Files that 8796 does not have are copied.
#   scripts/ios26/port-file.sh FILE...
# Prints per file: copied / ok (fuzz count) / REJECT (FILE.rej left for hand work) / MISSING-in-12377.
set -u
. "$(dirname "$0")/../lib/env.sh"
A=$OUT/kernel/local-ios26/ref16/pristine
B=$OUT/kernel/local-ios26/ref16/negroni
W=${WORK:-$OUT/kernel/local-ios26/work}
for f in "$@"; do
  if [ ! -f "$A/$f" ]; then
    mkdir -p "$(dirname "$W/$f")"; cp "$B/$f" "$W/$f"; echo "copied  $f"; continue
  fi
  if [ ! -f "$W/$f" ]; then echo "MISSING-in-12377 $f"; continue; fi
  out=$(diff -u "$A/$f" "$B/$f" | patch -s -t -F3 -N "$W/$f" 2>&1); rc=$?
  if [ $rc = 0 ]; then echo "ok      $f $(printf '%s' "$out" | grep -c fuzz)"
  else echo "REJECT  $f -> $f.rej"; fi
  rm -f "$W/$f.orig"
done
