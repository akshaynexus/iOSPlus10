#!/bin/sh
# Make patches/laurel/xnu/2773-laurel-camera-quality.patch from two trees of the patched kernel's camera files.
#   scripts/laurel/camera-patch.sh BASE WORK       (BASE/bsd/{dev,conf}: the tree after 2772 + 2775; WORK: the same files, changed)
set -eu
B=${1:?base}; W=${2:?work}
REPO=$(cd "$(dirname "$0")/../.." && pwd)
P=$REPO/patches/laurel/xnu/2773-laurel-camera-quality.patch
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/a" "$T/b"; cp -R "$B/bsd" "$T/a/"; cp -R "$W/bsd" "$T/b/"
{ sed -n '1,/^$/p' "$REPO/scripts/laurel/camera-patch.head"; (cd "$T" && diff -ruN a b | sed -E 's/^(---|\+\+\+) ([ab]\/[^\t]*).*/\1 \2/') || true; } > "$P"
grep -c '^diff ' "$P"
