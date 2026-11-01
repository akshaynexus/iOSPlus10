#!/bin/bash
# Make the flame tree of the iOS 26 build ready for edits: the tree without our iOS 26 patch is committed, the patch is applied on top. Edit the files, then run with "save": the new patch is written.
#   scripts/ios26/flame-patch-edit.sh begin|save       (only touches out/ios26/metal/src/flame and userland/metal/patches/flame-ios26)
set -eu
REPO=$(cd "$(dirname "$0")/../.." && pwd)
D=$REPO/out/ios26/metal/src/flame
P=$REPO/userland/metal/patches/flame-ios26/0001-ios26-23f84-spi-linked-functions.patch
case "${1:-}" in
begin)
  git -C "$D" apply -R --whitespace=nowarn "$P"
  git -C "$D" add -A
  git -C "$D" -c user.name=x -c user.email=x@local commit -q -m "series without the iOS 26 patch" --allow-empty
  git -C "$D" apply --whitespace=nowarn "$P"
  ;;
save)
  git -C "$D" diff > "$P"
  wc -l "$P"
  ;;
*) sed -n 2,3p "$0"; exit 1 ;;
esac
