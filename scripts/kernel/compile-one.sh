#!/bin/bash
# Syntax-check (or compile) one kernel C file against the last local build, in seconds, before a
# full build (scripts/kernel/build-local.sh). macOS + Xcode 15 (same compiler as the build).
#   scripts/kernel/compile-one.sh TREE FILE [-o OUT.o]      (FILE: a .c of bsd/, or a .cpp of iokit/)
#     TREE  a patched xnu tree (scripts/kernel/patched-tree.sh OUTDIR); its bsd/ osfmk/ ... are
#           used for the source includes; the generated headers come from the last full build
#     FILE  path of the .c file, relative to TREE (e.g. bsd/dev/negroni_glink.c; osfmk/ and pexpert/ .c too)
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
LOG=${COMPILE_LOG:-$W/build.log}   # COMPILE_LOG: another build log with the same lines (while a build rewrites build.log)
OBJ=$W/dxb/build/xnu.obj/DEVELOPMENT_ARM64_NEGRONI/bsd/DEVELOPMENT
[ -f "$LOG" ] && [ -d "$OBJ" ] || { echo "no $LOG or $OBJ: run scripts/kernel/build-local.sh once" >&2; exit 1; }
[ -f "$TREE/$FILE" ] || { echo "no $TREE/$FILE" >&2; exit 1; }
src=$W/dxb/xnu
case "$FILE" in
*.cpp)
  # a C++ (IOKit) file: the clang++ line of iokit/Kernel/arm/NegroniBattery.cpp (0271), same flags
  OBJ=$W/dxb/build/xnu.obj/DEVELOPMENT_ARM64_NEGRONI/iokit/DEVELOPMENT
  line=$(grep -m1 -E 'clang\+\+ -o NegroniBattery\.cpo -c .*/iokit/Kernel/arm/NegroniBattery\.cpp$' "$LOG" || true)
  [ -n "$line" ] || { echo "no compile line for NegroniBattery.cpp in $LOG" >&2; exit 1; }
  line=${line//-I$src\//-I$TREE/}
  line=${line% *}
  line=${line//-o NegroniBattery.cpo /}
  line=${line//-MD -MF NegroniBattery.d -MP/}
  ;;
osfmk/*.c|pexpert/*.c)
  # an osfmk or pexpert C file (0288): the clang line of osfmk/arm64/negroni_early.c or
  # pexpert/arm/pe_fiq.c (the component's own flags: MACH_KERNEL_PRIVATE etc.)
  comp=${FILE%%/*}
  ref=osfmk/arm64/negroni_early.c; [ "$comp" = pexpert ] && ref=pexpert/arm/pe_fiq.c
  base=$(basename "$ref" .c)
  OBJ=$W/dxb/build/xnu.obj/DEVELOPMENT_ARM64_NEGRONI/$comp/DEVELOPMENT
  line=$(grep -m1 -E "/clang -c .*/${ref//./\\.}\$" "$LOG" || true)
  [ -n "$line" ] || { echo "no compile line for $ref in $LOG" >&2; exit 1; }
  line=${line//-I$src\//-I$TREE/}
  line=${line% *}
  line=${line//-MD -MF $base.d -MP/}
  ;;
*)
  line=$(grep -m1 -E '/clang -c .*/bsd/dev/negroni_adsp\.c$' "$LOG" || true)
  [ -n "$line" ] || { echo "no compile line for negroni_adsp.c in $LOG" >&2; exit 1; }
  # the tree's sources instead of the build copy; our file instead of negroni_adsp.c; no .d file
  line=${line//-I$src\//-I$TREE/}
  line=${line% *}
  line=${line//-MD -MF negroni_adsp.d -MP/}
  ;;
esac
[ -d "$OBJ" ] || { echo "no $OBJ: run scripts/kernel/build-local.sh once" >&2; exit 1; }
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
