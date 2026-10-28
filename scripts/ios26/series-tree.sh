#!/bin/bash
# Developer tree for the iOS 26 series: out/kernel/local-ios26/work = xnu-12377.121.6 + darwin-xnu-build's
# 26.0 sed fixes and patches (as build-kernel.sh/dxb apply them) + scripts/ios26/apply-series.py --commit,
# one git commit per step. To write a rule for a patch: look at its result line, edit the tree after that
# patch's commit, "git diff", express the difference in scripts/ios26/patch-rules.py.
#   scripts/ios26/series-tree.sh [--dev] [--upto NNNN]     (args go to apply-series.py)
# Needs out/kernel/local-ios26/{xnu-pristine,dxb} (made by build-kernel.sh). Takes about a minute.
set -euo pipefail
. "$(dirname "$0")/../lib/env.sh"
W=$OUT/kernel/local-ios26
D=$W/dxb
[ -d "$W/xnu-pristine/.git" ] && [ -d "$D/patches/26.0" ] || { echo "run scripts/ios26/build-kernel.sh (STAGE=prepare) once" >&2; exit 1; }
rm -rf "${W:?}/work"
(cd "$W/xnu-pristine" && tar cf - --exclude .git .) | (mkdir -p "$W/work" && cd "$W/work" && tar xf -)
cd "$W/work"
g() { git -c commit.gpgsign=false -c user.name=series-tree -c user.email=series-tree@localhost "$@"; }
git init -q && git add -A && g commit -q -m "xnu-12377.121.6"
# dxb build.sh patches(): sed fixes, then its 26.0 patches (only dxb's own, not the old zz-* copies)
sed -i '' 's|^AVAILABILITY_PL="${SDKROOT}/${DRIVERKITROOT}|AVAILABILITY_PL="${FAKEROOT_DIR}|g' bsd/sys/make_symbol_aliasing.sh
sed -i '' 's|^#include.*BSD.xcconfig.*||g' libsyscall/Libsyscall.xcconfig
sed -i '' 's|^LDFLAGS_KERNEL_SDK	= -L$(SDKROOT).*|LDFLAGS_KERNEL_SDK	= -L$(FAKEROOT_DIR)/usr/local/lib/kernel -lfirehose_kernel|g' makedefs/MakeInc.def
sed -i '' 's|^\(INCFLAGS_SDK[[:space:]]*=\) -I$(SDKROOT)/usr/local/include/\(kernel\)\{0,1\}|\1 -I$(FAKEROOT_DIR)/usr/local/include/kernel|' makedefs/MakeInc.def
sed -i '' 's|export MIG := $(shell $(XCRUN) -sdk $(SDKROOT) -find mig)|export MIG := $(shell find $(FAKEROOT_DIR) -name "mig")|g' makedefs/MakeInc.cmd
sed -i '' 's|export MIGCOM := $(shell $(XCRUN) -sdk $(SDKROOT) -find migcom)|export MIGCOM := $(shell find $(FAKEROOT_DIR) -name "migcom")|g' makedefs/MakeInc.cmd
for p in $(git -C "$D" ls-files patches/26.0 | grep '\.patch$'); do
  git apply --check "$D/$p" 2>/dev/null && git apply "$D/$p" && echo "dxb $(basename "$p")" || echo "dxb $(basename "$p"): skipped (as dxb does)"
done
g add -A && g commit -q -m "dxb 26.0"
python3 -I "$REPO/scripts/ios26/apply-series.py" "$W/work" --commit "$@"
