#!/bin/sh
# Private copies of external/Mu-Silicium-negroni and external/UniXNU for one worktree: mu-build.sh patches its tree in place, and the main
# checkout's tree is shared with other agents. btrfs reflink: no real disk cost at the start. Self-contained: each copy gets its own git dir.
#   scripts/bg.sh mu-tree scripts/laurel/mu-private-tree.sh [SRC_EXTERNAL_DIR]
# Output: out/laurel-mu-tree/{Mu-Silicium-negroni,UniXNU}. Then: MU_TREE=... UNIXNU_TREE=... SETUP=0 scripts/laurel/mu-build.sh. Delete the folder when done.
set -eu
. "$(dirname "$0")/../lib/env.sh"
MAIN=$(git -C "$REPO" worktree list --porcelain | sed -n '1s/^worktree //p')
SRC=${1:-$MAIN/external}
D=$OUT/laurel-mu-tree
mkdir -p "$D"
cp_tree() { # NAME: working tree + git dir of the submodule NAME
  n=$1
  rm -rf "${D:?}/$n"
  cp -a --reflink=auto "$SRC/$n" "$D/$n"
  rm -rf "$D/$n/Build"
  gd=$(git -C "$SRC/$n" rev-parse --absolute-git-dir)
  rm -f "$D/$n/.git"
  cp -a --reflink=auto "$gd" "$D/$n/.git"
  git -C "$D/$n" config --unset core.worktree || true
  # nested submodules: each .git file points into the source's git dir; point it into the copy
  find "$D/$n" -mindepth 2 -name .git -type f | while read -r f; do
    dir=${f%/.git}; rel=${dir#"$D/$n/"}
    old=$(sed 's/^gitdir: //' "$SRC/$n/$rel/.git")
    case "$old" in /*) ;; *) old=$(cd "$SRC/$n/$rel" && cd "$old" 2>/dev/null && pwd -P) || continue ;; esac
    suffix=${old#"$gd"}
    [ "$suffix" != "$old" ] || { echo "skip $rel: $old"; continue; }
    printf 'gitdir: %s\n' "$D/$n/.git$suffix" > "$f"
    git config -f "$D/$n/.git$suffix/config" core.worktree "$dir"
  done
  echo "$n: $(git -C "$D/$n" rev-parse --short HEAD), $(git -C "$D/$n" status --short | wc -l) changed files"
}
cp_tree Mu-Silicium-negroni
cp_tree UniXNU
git -C "$D/UniXNU/drivers/DarwinBoot" rev-parse --short HEAD
du -sh "$D"
