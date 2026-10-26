#!/bin/bash
# Write a flame/ or m2v/ patch from a pristine copy and an edited tree (the format fetch-sources.sh applies:
# a text header, then `git diff` with a/ and b/ paths relative to the tree root).
#   scripts/metal/make-patch.sh BASE_DIR EDITED_DIR HEADER_FILE OUT.patch
# Example (flame): BASE = a copy of out/metal/src/flame taken after fetch-sources.sh, EDITED = out/metal/src/flame.
set -euo pipefail
base=$(cd "$1" && pwd); edited=$(cd "$2" && pwd); header=$3; out=$4
tmp=$(mktemp)
(cd "$base" && git diff --no-index --no-color --src-prefix=a/ --dst-prefix=b/ . "$edited" || true) > "$tmp"
# git names the edited side by its absolute path: make both sides relative to the tree root
sed -e "s#^\(diff --git a/\)\./\(.*\) b$edited/\(.*\)#\1\2 b/\3#" -e "s#^--- a/\./#--- a/#" -e "s#^+++ b$edited/#+++ b/#" "$tmp" > "$tmp.2"
{ cat "$header"; echo; cat "$tmp.2"; } > "$out"
rm -f "$tmp" "$tmp.2"
grep -c '^+++ ' "$out" | xargs echo "files in patch:"
