#!/bin/bash
# Build our iOS 16 kernel locally (macOS), with the same recipe as the CI (ci/negroni-xnu):
# darwin-xnu-build at DXB_SHA + slop negroni patches (external/slop) + patches/xnu/*.patch.
#   scripts/kernel/build-local.sh            (run in tmux: make kernel-local)
#   CLEAN=1 scripts/kernel/build-local.sh    (start from a fresh tree)
# Needs Xcode 15.x (scripts/kernel/install-xcode15.sh) and brew jq gum cmake ninja.
# Output: out/kernel/local-<UTC time>/kernel.development.negroni + patch-report.txt,
#         link out/kernel/kernel.macho (used by scripts/ios16/build.sh).
set -euo pipefail
. "$(dirname "$0")/../lib/env.sh"
DXB_SHA=663906528d1cd5ea8fde7de6f16de73db9511549
APP=${XCODE15_APP:-/Applications/Xcode_15.4.app}
W=$OUT/kernel/local
[ -d "$APP" ] || { echo "missing $APP: run scripts/kernel/install-xcode15.sh" >&2; exit 1; }
for t in jq gum cmake ninja; do command -v $t >/dev/null || brew install $t; done

[ "${CLEAN:-0}" = 1 ] && rm -rf "${W:?}/dxb"
mkdir -p "$W/bin" "$W/kdk-empty"
# dxb's install_deps wants xcodes (CI stubs it too); NEGRONI links no closed KDK library
# (MakeInc.def: only T6000/T8101/VMAPPLE), so an empty KDKROOT is enough.
printf '#!/bin/sh\nexit 0\n' > "$W/bin/xcodes"; chmod +x "$W/bin/xcodes"
if [ ! -d "$W/dxb/.git" ]; then
  git init -q "$W/dxb"
  git -C "$W/dxb" fetch -q --depth 1 https://github.com/blacktop/darwin-xnu-build "$DXB_SHA"
  git -C "$W/dxb" checkout -q FETCH_HEAD
  cp "$EXT"/slop/negroni-ios/xnu/patches/*.patch "$EXT"/slop/negroni-ios/xnu/patches/*.sh "$W/dxb/patches/"
  # libfirehose_kernel is built arm64e-only; the NEGRONI kernel is plain arm64
  sed -i '' 's/ARCHS="x86_64 arm64e" VALID_ARCHS="x86_64 arm64e"/ARCHS="x86_64 arm64e arm64" VALID_ARCHS="x86_64 arm64e arm64"/' "$W/dxb/build.sh"
fi
# our patches: always the current set (a changed patch needs CLEAN=1, since xnu is patched once)
cp "$REPO"/patches/xnu/*.patch "$W/dxb/patches/" 2>/dev/null || true
# rebuild the kernel binary each run (dxb skips build_xnu when it exists)
rm -f "$W"/dxb/build/xnu.obj/kernel.*

cd "$W/dxb"
export PATH="$W/bin:$PATH" DEVELOPER_DIR="$APP/Contents/Developer"
export MACOS_VERSION=13.5 KERNEL_CONFIG=${KERNEL_CONFIG:-DEVELOPMENT} MACHINE_CONFIG=NEGRONI KDKROOT="$W/kdk-empty"
xcodebuild -version
bash build.sh 2>&1 | tee "$W/build.log"
D=$OUT/kernel/local-$(date -u +%Y%m%d-%H%M%S)
mkdir -p "$D"
cp fakeroot/System/Library/Kernels/kernel.* "$D/"
grep -E "Applying patch|Skipping patch" "$W/build.log" | sed 's|.*/patches/||' > "$D/patch-report.txt" || true
(cd "$D" && shasum -a 256 kernel.* > SHA256SUMS)
ln -sfn "$(basename "$D")/kernel.$(echo "$KERNEL_CONFIG" | tr '[:upper:]' '[:lower:]').negroni" "$OUT/kernel/kernel.macho"
echo "skipped patches:"; grep Skipping "$D/patch-report.txt" || echo "  none"
"$REPO/scripts/lib/notify.sh" "local kernel build done: $D"
ls -l "$D" "$OUT/kernel/kernel.macho"
