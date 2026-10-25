#!/bin/bash
# Syntax-check (or compile) one kernel C file against the last local build, in seconds, before a
# full build (scripts/kernel/build-local.sh). macOS + Xcode 15 (same compiler as the build).
#   scripts/kernel/compile-one.sh TREE FILE [-o OUT.o]
#     TREE  a patched xnu tree (scripts/kernel/patched-tree.sh OUTDIR); its bsd/ osfmk/ ... are
#           used for the source includes; the generated headers come from the last full build
#     FILE  path of the .c file, relative to TREE (e.g. bsd/dev/negroni_glink.c)
# Uses the clang command line that build.log recorded for bsd/dev/negroni_adsp.c (all -D/-W flags
# of DEVELOPMENT_ARM64_NEGRONI). Without -o: -fsyntax-only. Fails while a full build runs (the
# build deletes build/xnu.obj first).
set -euo pipefail
. "$(dirname "$0")/../lib/env.sh"
TREE=${1:?usage: compile-one.sh TREE FILE [-o OUT.o]}
FILE=${2:?usage: compile-one.sh TREE FILE [-o OUT.o]}
shift 2
case "$TREE" in /*) ;; *) TREE=$PWD/$TREE ;; esac
W=$OUT/kernel/local
LOG=$W/build.log
OBJ=$W/dxb/build/xnu.obj/DEVELOPMENT_ARM64_NEGRONI/bsd/DEVELOPMENT
[ -f "$LOG" ] && [ -d "$OBJ" ] || { echo "no $LOG or $OBJ: run scripts/kernel/build-local.sh once" >&2; exit 1; }
[ -f "$TREE/$FILE" ] || { echo "no $TREE/$FILE" >&2; exit 1; }
line=$(grep -m1 -E '/clang -c .*/bsd/dev/negroni_adsp\.c$' "$LOG" || true)
[ -n "$line" ] || { echo "no compile line for negroni_adsp.c in $LOG" >&2; exit 1; }
src=$W/dxb/xnu
# the tree's sources instead of the build copy; our file instead of negroni_adsp.c; no .d file
line=${line//-I$src\//-I$TREE/}
line=${line% *}
line=${line//-MD -MF negroni_adsp.d -MP/}
if [ "${1:-}" = -o ]; then
  out=${2:?-o needs a file}; case "$out" in /*) ;; *) out=$PWD/$out ;; esac
  extra="-o $out"
else
  extra="-fsyntax-only"
fi
cd "$OBJ"
# shellcheck disable=SC2086
eval "$line $extra -Wno-declaration-after-statement '$TREE/$FILE'"
echo "compile-one: $FILE OK"
