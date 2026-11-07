#!/bin/sh
# Parallel builds from one shared branch (owner, 2026-11-07: the single build lock made a grid lock).
# Each build runs in its own snapshot tree, so builds of different agents run at the same time. The big caches
# (SDK, toolchain, KDK, downloads), the Mu UEFI image, the dual-boot records and the host tools are shared by symlink.
#
#   scripts/laurel/snap-build.sh NAME [--ref REF | --local] -- COMMAND...
#     NAME      a short job name: the tree is ~/.t3/worktrees/iOSPlus10/build-NAME (reused by the next build of NAME)
#     --ref REF build that commit (default: HEAD of the main checkout, i.e. committed laurel-sprout)
#     --local   build HEAD plus every change in the main checkout (tracked and untracked, not ignored, not external/)
#     COMMAND   runs in the snapshot tree, e.g. scripts/laurel/kernel-ios26-linux.sh
#   scripts/laurel/snap-build.sh --list           the snapshot trees and their commits
#
# What stays one at a time: git commit and push in the main checkout, and a Mu UEFI build (it patches external/
# in place): scripts/laurel/build-lock.sh NAME COMMAND. A kernel, image or userland build needs no lock here.
set -eu
MAIN=$(cd "$(dirname "$0")/../.." && pwd)
BASE=${SNAP_BASE:-$HOME/.t3/worktrees/iOSPlus10}
if [ "${1:-}" = --list ]; then
  for d in "$BASE"/build-*; do [ -d "$d" ] && echo "$(basename "$d") $(git -C "$d" log -1 --format='%h %cr' 2>/dev/null)"; done
  exit 0
fi
[ $# -ge 3 ] || { echo "snap-build: NAME [--ref REF | --local] -- COMMAND..." >&2; exit 2; }
NAME=$1; shift
REF=HEAD; LOCAL=0
while [ $# -gt 0 ] && [ "$1" != -- ]; do
  case "$1" in --ref) REF=$2; shift 2 ;; --local) LOCAL=1; shift ;; *) echo "snap-build: unknown option $1" >&2; exit 2 ;; esac
done
[ "${1:-}" = -- ] || { echo "snap-build: -- COMMAND missing" >&2; exit 2; }
shift
T=$BASE/build-$NAME
cd "$MAIN"
C=$(git rev-parse "$REF^{commit}")
if [ "$LOCAL" = 1 ]; then
  # A commit object of the working tree, made with a private index: the main checkout's index is not touched.
  IDX=$(mktemp); trap 'rm -f "$IDX"' EXIT
  GIT_INDEX_FILE=$IDX git read-tree "$C"
  GIT_INDEX_FILE=$IDX git add -A -- . ':(exclude)external' 2>/dev/null
  TR=$(GIT_INDEX_FILE=$IDX git write-tree)
  C=$(git commit-tree "$TR" -p "$C" -m "snap-build $NAME: local state $(date +%Y%m%dT%H%M%S)")
fi
if [ -d "$T/.git" ] || [ -f "$T/.git" ]; then
  git -C "$T" checkout -q --detach --force "$C"
  git -C "$T" clean -qfd -e out -e logs -e external
else
  mkdir -p "$BASE"
  git worktree add -q --detach "$T" "$C"
fi
mkdir -p "$T/logs" "$T/out/laurel-kernel-ios26" "$T/out/laurel"
# Shared, read-mostly: caches and records that are the same for every build of this phone.
link() { [ -e "$MAIN/$1" ] || return 0; [ -L "$T/$1" ] && return 0; if [ -e "$T/$1" ]; then rm -rf "$T/$1"; fi; mkdir -p "$(dirname "$T/$1")"; ln -s "$MAIN/$1" "$T/$1"; }
for p in out/laurel-kernel-ios26/dl out/laurel-kernel-ios26/deps out/laurel-kernel-ios26/kdk out/laurel/mu out/laurel/dualboot out/bin out/cargo; do link "$p"; done
# The submodules: read only for a kernel or image build (Mu builds stay in the main checkout under build-lock.sh).
for s in $(git config -f .gitmodules --get-regexp 'submodule\..*\.path' | cut -d' ' -f2); do
  [ -d "$MAIN/$s" ] || continue
  if [ -L "$T/$s" ]; then continue; fi
  rmdir "$T/$s" 2>/dev/null || true
  [ -e "$T/$s" ] || ln -s "$MAIN/$s" "$T/$s"
done
echo "snap-build: $NAME at $(git -C "$T" log -1 --format='%h') in $T"
cd "$T"
exec "$@"
