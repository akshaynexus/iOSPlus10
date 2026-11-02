#!/bin/bash
# Mi A3 iOS 26 kernel: make post/9006 from Apple's IOHIDFamily and the hid folder of the series tree. Run in tmux: scripts/bg.sh hid-port scripts/laurel/ios26-hid-port.sh
# BASE: the hid folder before 9006 (default: the iOS 26 kernel tree of this checkout or of the main checkout, at the commit before post 9006).
set -euo pipefail
. "$(dirname "$0")/../lib/env.sh"
MAIN=$(git -C "$REPO" worktree list --porcelain | sed -n '1s/^worktree //p')
SRC=$OUT/laurel-kernel-ios26/src/xnu; [ -d "$SRC/iokit" ] || SRC=$MAIN/out/laurel-kernel-ios26/src/xnu
D=$OUT/re-hid/iohid
if [ ! -d "$D/.git" ] || ! git -C "$D" cat-file -e 2365347f5147a1e2a46de21acd08d27fe0906e85^{commit} 2>/dev/null; then
  rm -rf "$D"; mkdir -p "$D"; git init -q "$D"
  git -C "$D" fetch -q --depth 1 https://github.com/apple-oss-distributions/IOHIDFamily 2365347f5147a1e2a46de21acd08d27fe0906e85
  git -C "$D" fetch -q --depth 1 https://github.com/apple-oss-distributions/IOHIDFamily e31e90a24c27ad6cbe981650d12a1a4124065b03
  git -C "$D" checkout -q FETCH_HEAD
fi
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
# the hid folder with no 9006: the commit of the step before it, or the tree as it stands
c=$(git -C "$SRC" log --format=%H --grep='^post 9006' -1 2>/dev/null || true)
ref=${c:+$c~1}; ref=${ref:-HEAD}
git -C "$SRC" archive "$ref" iokit/Kernel/arm/hid | tar -x -C "$T"
python3 -I "$REPO/scripts/laurel/ios26-hid-port.py" "$D" "$T/iokit/Kernel/arm/hid" "$REPO/patches/laurel/xnu-12377/post/9006-laurel-hid-2238.patch"
