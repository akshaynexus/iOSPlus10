#!/bin/bash
# A git tree of the kernel source as the local/CI build patches it, to write or regenerate one
# of our patches against the real current state:
#   xnu-8796.141.3 (out/kernel/local/xnu-pristine, made by build-local.sh)
#   + darwin-xnu-build's sed fixes (dxb build.sh patches())
#   + the stage scripts (*.sh) of external/slop/negroni-ios/xnu/patches (they fetch sources)
#   + every *.patch of external/slop, dxb's own patches and patches/xnu, in the order dxb's
#     build.sh applies them (one glob over one directory), each "git apply --check"ed first and
#     skipped like dxb does when it does not apply.
# Each step is one commit, so "git diff HEAD" after your edit is the new patch.
#
#   scripts/kernel/patched-tree.sh OUTDIR [UPTO]
#     UPTO: stop before the first patch whose file name sorts at or after it (e.g. 0231 or
#           0231-negroni-gpu-present.patch). Default: apply everything.
#   STAGE=0 scripts/kernel/patched-tree.sh ...   skip the stage scripts (no network)
#
# Takes a few minutes (stage-script fetches): run it with scripts/bg.sh. OUTDIR is deleted first.
# Does not touch out/kernel/local/dxb or out/kernel/xnu.
set -euo pipefail
. "$(dirname "$0")/../lib/env.sh"
OUTDIR=${1:?usage: patched-tree.sh OUTDIR [UPTO]}
UPTO=${2:-}
PRISTINE=$OUT/kernel/local/xnu-pristine
DXB=$OUT/kernel/local/dxb
SLOP=$EXT/slop/negroni-ios/xnu/patches
[ -d "$PRISTINE/.git" ] || { echo "no $PRISTINE: run scripts/kernel/build-local.sh once" >&2; exit 1; }
[ -d "$DXB/patches" ] || { echo "no $DXB/patches: run scripts/kernel/build-local.sh once" >&2; exit 1; }
case "$OUTDIR" in /*) ;; *) OUTDIR=$PWD/$OUTDIR ;; esac

rm -rf "${OUTDIR:?}"
mkdir -p "$(dirname "$OUTDIR")"
cp -R "$PRISTINE" "$OUTDIR"
cd "$OUTDIR"
g() { git -c commit.gpgsign=false -c user.name=patched-tree -c user.email=patched-tree@localhost "$@"; }
step() { git add -A >/dev/null; g commit -q --allow-empty -m "$1"; }
g checkout -q -B patched
echo "xnu: $(git log --oneline -1)"

# dxb build.sh patches(): the same sed lines (FAKEROOT_DIR etc. stay literal)
sed -i '' 's|^AVAILABILITY_PL="${SDKROOT}/${DRIVERKITROOT}|AVAILABILITY_PL="${FAKEROOT_DIR}|g' bsd/sys/make_symbol_aliasing.sh
sed -i '' 's|^#include.*BSD.xcconfig.*||g' libsyscall/Libsyscall.xcconfig
sed -i '' 's|^LDFLAGS_KERNEL_SDK	= -L$(SDKROOT).*|LDFLAGS_KERNEL_SDK	= -L$(FAKEROOT_DIR)/usr/local/lib/kernel -lfirehose_kernel|g' makedefs/MakeInc.def
sed -i '' 's|^\(INCFLAGS_SDK[[:space:]]*=\) -I$(SDKROOT)/usr/local/include/\(kernel\)\{0,1\}|\1 -I$(FAKEROOT_DIR)/usr/local/include/kernel|' makedefs/MakeInc.def
sed -i '' 's|export MIG := $(shell $(XCRUN) -sdk $(SDKROOT) -find mig)|export MIG := $(shell find $(FAKEROOT_DIR) -name "mig")|g' makedefs/MakeInc.cmd
sed -i '' 's|export MIGCOM := $(shell $(XCRUN) -sdk $(SDKROOT) -find migcom)|export MIGCOM := $(shell find $(FAKEROOT_DIR) -name "migcom")|g' makedefs/MakeInc.cmd
step "dxb build.sh sed fixes"

# one directory, as build-local.sh fills dxb/patches: dxb's own (names without a number),
# slop's numbered patches and scripts, ours
P=$(mktemp -d)
trap 'rm -rf "$P"' EXIT
for f in "$DXB"/patches/*.patch; do
  case "$(basename "$f")" in [0-9][0-9][0-9][0-9]-*) ;; *) cp "$f" "$P/" ;; esac
done
cp "$SLOP"/*.patch "$SLOP"/*.sh "$P/"
rm -f "$P"/0127-negroni-gpu-show.patch   # collides with our 0230; see build-local.sh
cp "$REPO"/patches/xnu/*.patch "$P/" 2>/dev/null || true
before() { [ -z "$UPTO" ] || [[ "$(basename "$1")" < "$UPTO" ]]; }

if [ "${STAGE:-1}" != 0 ]; then
  for s in "$P"/*.sh; do
    before "$s" || continue
    echo "script $(basename "$s")"
    MACHINE_CONFIG=NEGRONI MACOS_VERSION=13.5 KDKROOT=${KDKROOT:-$OUT/kernel/local/kdk-empty} bash "$s"
    step "script $(basename "$s")"
  done
fi
skipped=0
for p in "$P"/*.patch; do
  if ! before "$p"; then
    echo "stop before $(basename "$p")"; break
  fi
  if err=$(git apply --check "$p" 2>&1); then
    git apply "$p"
    step "$(basename "$p")"
  else
    echo "SKIPPED $(basename "$p"): $err" | head -3
    skipped=$((skipped + 1))
  fi
done
echo "tree: $OUTDIR (branch patched, $(git rev-list --count HEAD) commits, $skipped patches skipped)"
