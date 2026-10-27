#!/bin/bash
# Try the whole iOS 16 kernel patch stack (slop negroni patches + patches/xnu) on xnu-12377.121.6, in the
# iOS 16 build order, and record per patch: clean / fuzz / partial / fail / stage.
# Cumulative: every hunk that applies (clean, with fuzz, or from a partial patch) stays in the tree, so later
# patches see it. upstream = all hunks already in 12377; clean = all hunks exact; fuzz = all hunks with offset/fuzz; partial = some hunks failed; fail = none.
# Nothing here goes into the real iOS 26 build: that uses only patches/xnu-12377 (scripts/ios26/build-kernel.sh).
#
#   scripts/ios26/patch-check.sh            -> out/kernel/local-ios26/patch-check.tsv (+ .log)
# Env: SLOP (external/slop checkout; the main checkout's is used when this tree's submodule is empty),
#      XNU (pristine 12377 tree, default out/kernel/local-ios26/xnu-pristine; scripts/ios26/build-kernel.sh clones it)
set -euo pipefail
. "$(dirname "$0")/../lib/env.sh"
SLOP=${SLOP:-$EXT/slop}
if [ ! -d "$SLOP/negroni-ios" ]; then
  main=$(git -C "$REPO" worktree list --porcelain | awk '/^worktree /{print $2; exit}')
  SLOP=$main/external/slop
fi
XNU=${XNU:-$OUT/kernel/local-ios26/xnu-pristine}
W=$OUT/kernel/local-ios26
T=$W/check-tree
[ -d "$XNU" ] || { echo "missing $XNU: run STAGE=prepare scripts/ios26/build-kernel.sh" >&2; exit 1; }
rm -rf "$T"; mkdir -p "$T"
(cd "$XNU" && tar cf - --exclude .git .) | (cd "$T" && tar xf -)
TSV=$W/patch-check.tsv LOG=$W/patch-check.log
: > "$LOG"; printf 'patch\tstatus\thunks_failed\thunks_total\tfiles_missing\n' > "$TSV"
# iOS 16 order (scripts/kernel/build-local.sh): slop patches without 0127, then ours; dxb applies in name order
list=$( (ls "$SLOP"/negroni-ios/xnu/patches/*.patch "$SLOP"/negroni-ios/xnu/patches/*.sh; ls "$REPO"/patches/xnu/*.patch) \
  | grep -v 0127-negroni-gpu-show | awk -F/ '{print $NF"\t"$0}' | sort | cut -f2)
for p in $list; do
  n=$(basename "$p")
  case "$n" in *.sh) printf '%s\tstage\t-\t-\t-\n' "$n" >> "$TSV"; continue ;; esac
  total=$(grep -c '^@@ ' "$p" || true)
  missing=0
  for f in $(grep '^--- a/' "$p" | sed 's#^--- a/##' | sort -u); do [ -f "$T/$f" ] || missing=$((missing+1)); done
  # one real run: hunks that apply stay (best effort, so later patches see as much as possible), the rest -> .rej
  out=$(cd "$T" && patch -p1 -N -t -F3 -i "$p" </dev/null 2>&1) && rc=0 || rc=$?
  # Apple/BSD patch: "N out of M hunks failed while patching F", "N out of M hunks ignored" (= already in the tree)
  failed=$(printf '%s\n' "$out" | awk '/hunks failed/ {n += $1} END {print n + 0}')
  ignored=$(printf '%s\n' "$out" | awk '/hunks ignored/ {n += $1} END {print n + 0}')
  echo "== $n rc=$rc" >> "$LOG"; printf '%s\n' "$out" >> "$LOG"
  find "$T" \( -name '*.orig' -o -name '*.rej' \) -delete
  # a file that 12377 does not have also gives "ignored": count those hunks as failed
  [ "$missing" -gt 0 ] && failed=$((failed + ignored)) && ignored=0
  if [ "$ignored" -gt 0 ] && [ "$ignored" -ge "$total" ]; then st=upstream
  elif [ "$failed" = 0 ]; then
    if printf '%s\n' "$out" | grep -q 'with fuzz\|offset'; then st=fuzz; else st=clean; fi
  elif [ "$failed" -lt "$total" ]; then st=partial
  else st=fail; fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$n" "$st" "$failed" "$total" "$missing" >> "$TSV"
done
cut -f2 "$TSV" | tail -n +2 | sort | uniq -c
echo "table: $TSV  log: $LOG"
