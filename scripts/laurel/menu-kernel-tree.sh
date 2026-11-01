#!/bin/sh
# A kernel work tree for this worktree without new downloads: reflink copies of the main checkout's out/laurel-kernel and reference repos. Then scripts/laurel/kernel-linux.sh.
set -eu
. "$(dirname "$0")/../lib/env.sh"
MAIN=$(git -C "$REPO" worktree list --porcelain | sed -n '1s/^worktree //p')
[ -e "$OUT/laurel-kernel" ] || cp -a --reflink=auto "$MAIN/out/laurel-kernel" "$OUT/laurel-kernel"
for r in ios-topaz ios-sweet-linux; do [ -e "$EXT/$r" ] || ln -s "$MAIN/external/$r" "$EXT/$r"; done
du -sh "$OUT/laurel-kernel"
