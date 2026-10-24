#!/bin/bash
# Build the patched xnu source tree locally, exactly as the kernel CI does (darwin-xnu-build):
#   scripts/kernel/prepare-src.sh            -> out/kernel/xnu (git; commit "base"), out/kernel/patches.txt
# Patch set (one directory, applied in global name order, like dxb/patches in CI):
#   - blacktop/darwin-xnu-build top-level patches (pinned DXB_SHA)
#   - external/slop/negroni-ios/xnu/patches/*.{patch,sh}   (the negroni port, 0001-0124)
#   - patches/xnu/*.patch                                  (ours, 0200-...; NOT in "base")
# *.sh run first (MACHINE_CONFIG=NEGRONI MACOS_VERSION=13.5); a *.patch that does not apply is
# skipped with a warning (dxb build.sh behaviour). Base = everything except our patches, so
# each change can be made in its own worktree and exported as a patch against base.
# Long: run as  scripts/bg.sh kernel-src scripts/kernel/prepare-src.sh
set -euo pipefail
. "$(dirname "$0")/../lib/env.sh"
K=$OUT/kernel
XNU_TAG=xnu-8796.141.3
DXB_SHA=663906528d1cd5ea8fde7de6f16de73db9511549
mkdir -p "$K"
if [ ! -d "$K/dxb/.git" ]; then
  git init -q "$K/dxb"
  git -C "$K/dxb" fetch -q --depth 1 https://github.com/blacktop/darwin-xnu-build "$DXB_SHA"
  git -C "$K/dxb" checkout -q FETCH_HEAD
fi
rm -rf "$K/xnu" "$K/patchset"
git clone -q --depth 1 --branch "$XNU_TAG" https://github.com/apple-oss-distributions/xnu.git "$K/xnu"
mkdir -p "$K/patchset"
cp "$K"/dxb/patches/*.patch "$K/patchset/"
cp "$EXT"/slop/negroni-ios/xnu/patches/*.patch "$EXT"/slop/negroni-ios/xnu/patches/*.sh "$K/patchset/"

cd "$K/xnu"
# dxb build.sh edits before patching (FAKEROOT_DIR is a build-time variable, kept literal)
sed -i '' 's|^\(INCFLAGS_SDK[[:space:]]*=\) -I$(SDKROOT)/usr/local/include/\(kernel\)\{0,1\}|\1 -I$(FAKEROOT_DIR)/usr/local/include/kernel|' makedefs/MakeInc.def
sed -i '' 's|export MIG := $(shell $(XCRUN) -sdk $(SDKROOT) -find mig)|export MIG := $(shell find $(FAKEROOT_DIR) -name "mig")|g' makedefs/MakeInc.cmd
sed -i '' 's|export MIGCOM := $(shell $(XCRUN) -sdk $(SDKROOT) -find migcom)|export MIGCOM := $(shell find $(FAKEROOT_DIR) -name "migcom")|g' makedefs/MakeInc.cmd
for s in "$K"/patchset/*.sh; do
  echo "script $(basename "$s")"
  MACHINE_CONFIG=NEGRONI MACOS_VERSION=13.5 KDKROOT=/nonexistent bash "$s"
done
: > "$K/patches.txt"
for p in "$K"/patchset/*.patch; do
  if git apply --check "$p" 2>/dev/null; then git apply "$p"; echo "applied $(basename "$p")" >> "$K/patches.txt"
  else echo "SKIPPED $(basename "$p")" >> "$K/patches.txt"; fi
done
git add -A >/dev/null
git -c user.name=iosplus10 -c user.email=iosplus10@localhost commit -q -m "base: $XNU_TAG + dxb $DXB_SHA + slop $(git -C "$EXT/slop" rev-parse --short HEAD)"
git branch -f base >/dev/null
echo "applied $(grep -c ^applied "$K/patches.txt"), skipped $(grep -c ^SKIPPED "$K/patches.txt"):"
grep SKIPPED "$K/patches.txt" || true
