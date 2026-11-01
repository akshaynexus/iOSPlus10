#!/bin/sh
# Make a camera patch from two trees of the patched kernel's camera files.
#   scripts/laurel/camera-patch.sh BASE WORK       (2773; BASE/bsd/{dev,conf}: the tree after 2772 + 2775; WORK: the same files, changed)
#   scripts/laurel/camera-patch.sh BASE WORK 2784-laurel-camera-light     (head: scripts/laurel/2784-laurel-camera-light.head)
#   scripts/laurel/camera-patch.sh BASE WORK 2913-laurel-camera-speed     (BASE/WORK also with iokit/Kernel/arm/TopazAdreno.cpp)
set -eu
B=${1:?base}; W=${2:?work}
REPO=$(cd "$(dirname "$0")/../.." && pwd)
N=${3:-2773-laurel-camera-quality}
P=$REPO/patches/laurel/xnu/$N.patch
H=$REPO/scripts/laurel/camera-patch.head
[ -z "${3:-}" ] || H=$REPO/scripts/laurel/$N.head
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/a" "$T/b"; cp -R "$B/bsd" "$T/a/"; cp -R "$W/bsd" "$T/b/"
[ ! -d "$B/iokit" ] || { cp -R "$B/iokit" "$T/a/"; cp -R "$W/iokit" "$T/b/"; }
{ sed -n '1,/^$/p' "$H"; (cd "$T" && diff -ruN a b | sed -E 's/^(---|\+\+\+) ([ab]\/[^\t]*).*/\1 \2/') || true; } > "$P"
grep -c '^diff ' "$P"
