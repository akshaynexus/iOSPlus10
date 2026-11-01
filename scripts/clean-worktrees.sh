#!/bin/sh
# Remove git worktrees whose work is merged (macOS and Linux). Run it after every merge of an agent branch.
#   scripts/clean-worktrees.sh                  show what would go (dry run)
#   scripts/clean-worktrees.sh --yes            remove it
#   INTO=origin/main scripts/clean-worktrees.sh  merged into which ref (default: origin/laurel-sprout; merge first, then remove)
# A worktree goes only if all of these are true: its branch is an ancestor of INTO, it has no uncommitted or untracked
# file (submodule state and symlinks under external/ do not count), it has no local commit that is missing on the
# remote branch, no process runs in it, nothing is mounted in it. The branch itself stays. Everything else is listed
# with the reason it stays. A branch at its base commit also counts as merged: the process check protects an agent that
# has just started, so run this from the coordinator only.
set -eu
cd "$(dirname "$0")/.."
TOP=$(pwd -P)
INTO=${INTO:-origin/laurel-sprout}
YES=0
[ "${1:-}" = --yes ] && YES=1
git fetch -q origin 2>/dev/null || echo "clean-worktrees: no fetch (the remote state can be old)"

busy() { # PATH: a process has it in its command line or as its current directory
  ps -eo args= 2>/dev/null | grep -F "$1" | grep -vF clean-worktrees | grep -qv grep && return 0
  for c in /proc/[0-9]*/cwd; do
    case "$(readlink "$c" 2>/dev/null)" in "$1"|"$1"/*) return 0 ;; esac
  done
  return 1
}

removed=0 kept=0
list=$(mktemp)
git worktree list --porcelain | awk '/^worktree /{w=substr($0,10)} /^branch /{print w "\t" substr($2,12)} /^detached/{print w "\t-"}' > "$list"
while IFS="$(printf '\t')" read -r w b; do
  [ "$w" = "$TOP" ] && continue
  why=
  if [ "$b" = - ]; then why="detached HEAD"
  elif ! git merge-base --is-ancestor "$b" "$INTO" 2>/dev/null; then why="not merged ($(git rev-list --count "$INTO..$b") commits)"
  elif git -C "$w" status --porcelain 2>/dev/null | grep -qvE '^.. external/'; then why="uncommitted files"
  elif git rev-parse -q --verify "origin/$b" >/dev/null && [ "$(git rev-list --count "origin/$b..$b")" != 0 ]; then why="commits not pushed"
  elif mount | grep -qF " $w/"; then why="a mount inside"
  elif busy "$w"; then why="a process runs in it"
  fi
  if [ -n "$why" ]; then
    echo "keep    $b ($w): $why"; kept=$((kept + 1)); continue
  fi
  if [ $YES = 1 ]; then
    git worktree remove --force "$w" && echo "removed $b ($w)"
  else
    echo "remove  $b ($w)"
  fi
  removed=$((removed + 1))
done < "$list"
rm -f "$list"
[ $YES = 1 ] && git worktree prune
echo "clean-worktrees: $removed $([ $YES = 1 ] && echo removed || echo 'to remove (dry run: --yes removes)'), $kept kept"
df -h . | tail -1
