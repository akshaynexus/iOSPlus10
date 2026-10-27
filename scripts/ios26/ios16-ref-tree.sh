#!/bin/bash
# Make the iOS 16 reference trees for the iOS 26 patch port: xnu-8796.141.3 pristine and the same tree with only
# the negroni changes (slop stage scripts + slop patches without 0127 + patches/xnu, in the iOS 16 order; no dxb
# build patches, so a diff between the two trees is our port and nothing else).
#   scripts/ios26/ios16-ref-tree.sh  -> out/kernel/local-ios26/ref16/{pristine,negroni}, ref16/apply-report.txt
# scripts/ios26/port-file.sh then carries the change of one file to the 12377 work tree.
set -euo pipefail
. "$(dirname "$0")/../lib/env.sh"
SLOP=${SLOP:-$EXT/slop}
if [ ! -d "$SLOP/negroni-ios" ]; then
  main=$(git -C "$REPO" worktree list --porcelain | awk '/^worktree /{print $2; exit}')
  SLOP=$main/external/slop
fi
R=$OUT/kernel/local-ios26/ref16
mkdir -p "$R"
[ -d "$R/pristine/.git" ] || git clone -q --depth 1 --branch xnu-8796.141.3 https://github.com/apple-oss-distributions/xnu.git "$R/pristine"
rm -rf "$R/negroni"; mkdir -p "$R/negroni"
(cd "$R/pristine" && tar cf - --exclude .git .) | (cd "$R/negroni" && tar xf -)
cd "$R/negroni"
git init -q && git add -A && git commit -q -m pristine
export MACHINE_CONFIG=NEGRONI MACOS_VERSION=13.5
for s in "$SLOP"/negroni-ios/xnu/patches/*.sh; do bash "$s"; done
: > "$R/apply-report.txt"
for p in $( (ls "$SLOP"/negroni-ios/xnu/patches/*.patch; ls "$REPO"/patches/xnu/*.patch) | grep -v 0127-negroni-gpu-show \
    | awk -F/ '{print $NF"\t"$0}' | sort | cut -f2); do
  if git apply --check "$p" 2>/dev/null; then git apply "$p"; echo "applied $(basename "$p")"; else echo "SKIPPED $(basename "$p")"; fi
done >> "$R/apply-report.txt"
grep -c '^applied' "$R/apply-report.txt"; grep '^SKIPPED' "$R/apply-report.txt" || echo "skipped: none"
