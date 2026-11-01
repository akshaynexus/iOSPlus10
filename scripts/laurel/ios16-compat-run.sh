#!/bin/bash
# Show that the default iOS 16 Metal + Turnip build did not change with this branch: build the base commit and the branch head in this worktree (same paths), compare raw and normalized hashes (scripts/laurel/macho-norm.py).
#   scripts/bg.sh ios16-compat scripts/laurel/ios16-compat-run.sh BASE_COMMIT      commit everything first: it checks out BASE, then comes back. Nothing else may run in this worktree meanwhile. Minutes.
set -euo pipefail
REPO=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$REPO"
base=${1:?base commit}
head=$(git rev-parse --abbrev-ref HEAD)
[ -z "$(git status --porcelain -- scripts userland tools Makefile)" ] || { echo "ios16-compat: commit scripts and userland first" >&2; exit 2; }
C=$REPO/out/ios16-compat-run
rm -rf "$C"; mkdir -p "$C/base" "$C/head"
cp scripts/laurel/macho-norm.py "$C/"
build() {
  local where=$1 s
  for s in fetch turnip bridge plugin; do FORCE=1 scripts/laurel/metal-build.sh "$s" > "$C/$where-$s.log" 2>&1 || { tail -20 "$C/$where-$s.log"; return 1; }; done
  cp -a out/metal/stage "$C/$where/stage"
  cp out/gpu/turnip/libvulkan_freedreno.dylib "$C/$where/"
  cp out/metal/bridge/ios/libnative_metal_bridge.a "$C/$where/"
  # the default XNUtils: the same sources decide it, with XT_IOS26 unset
  SDK=$REPO/out/laurel-metal/sdk/iPhoneOS16.5.sdk scripts/laurel/xnutils-build.sh > "$C/$where-xnutils.log" 2>&1 || { tail -20 "$C/$where-xnutils.log"; return 1; }
  cp -a out/laurel/xnutils/root "$C/$where/xnutils"
}
trap 'git checkout -q "$head"' EXIT
git checkout -q --detach "$base"
build base
git checkout -q "$head"
trap - EXIT
build head
cd "$C"
list() { (cd "$1" && find . -type f | sort); }
same=0; diff=0
while read -r f; do
  if cmp -s "base/$f" "head/$f"; then same=$((same+1)); echo "same bytes   $f"; else
    diff=$((diff+1)); a=$(python3 -I macho-norm.py "base/$f" | cut -d' ' -f2); b=$(python3 -I macho-norm.py "head/$f" | cut -d' ' -f2)
    if [ "$a" = "$b" ]; then echo "same code    $f (differs in UUID and signature only)"; else echo "DIFFERENT    $f"; fi
  fi
done < <(list base)
echo "ios16-compat: $same same bytes, $diff with a byte difference"
