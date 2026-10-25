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

# one build at a time (several agents may start one): wait for the lock, drop a stale one
mkdir -p "$OUT/kernel"
L=$OUT/kernel/local.lock
until mkdir "$L" 2>/dev/null; do
  pid=$(cat "$L/pid" 2>/dev/null || true)
  if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then rm -rf "${L:?}"; continue; fi
  echo "waiting for the running kernel build (pid ${pid:-?}) ..."; sleep 10
done
echo $$ > "$L/pid"
trap 'rm -rf "${L:?}"' EXIT
[ "${CLEAN:-0}" = 1 ] && rm -rf "${W:?}/dxb"
mkdir -p "$W/bin" "$W/kdk-empty"
# dxb's install_deps wants xcodes (CI stubs it too); NEGRONI links no closed KDK library
# (MakeInc.def: only T6000/T8101/VMAPPLE), so an empty KDKROOT is enough.
printf '#!/bin/sh\nexit 0\n' > "$W/bin/xcodes"; chmod +x "$W/bin/xcodes"
if [ ! -d "$W/dxb/.git" ]; then
  git init -q "$W/dxb"
  git -C "$W/dxb" fetch -q --depth 1 https://github.com/blacktop/darwin-xnu-build "$DXB_SHA"
  git -C "$W/dxb" checkout -q FETCH_HEAD
  # libfirehose_kernel is built arm64e-only; the NEGRONI kernel is plain arm64
  sed -i '' 's/ARCHS="x86_64 arm64e" VALID_ARCHS="x86_64 arm64e"/ARCHS="x86_64 arm64e arm64" VALID_ARCHS="x86_64 arm64e arm64"/' "$W/dxb/build.sh"
fi
# the port's patches (external/slop) and ours: always the current set (numbered files are ours/slop's;
# dxb's own patches have names without a number)
rm -f "$W"/dxb/patches/[0-9][0-9][0-9][0-9]-*.patch "$W"/dxb/patches/[0-9][0-9][0-9][0-9]-*.sh
cp "$EXT"/slop/negroni-ios/xnu/patches/*.patch "$EXT"/slop/negroni-ios/xnu/patches/*.sh "$W/dxb/patches/"
cp "$REPO"/patches/xnu/*.patch "$W/dxb/patches/" 2>/dev/null || true
echo "slop $(git -C "$EXT/slop" rev-parse --short HEAD), $(ls "$REPO"/patches/xnu/*.patch | wc -l | tr -d ' ') patches/xnu"
# every run patches a fresh xnu copy (the port's stage scripts refuse to run twice on one tree);
# the built helpers (mig, ctf tools, headers, libfirehose) in fakeroot/ are kept
XNU_TAG=xnu-8796.141.3
[ -d "$W/xnu-pristine/.git" ] || git clone -q --depth 1 --branch "$XNU_TAG" https://github.com/apple-oss-distributions/xnu.git "$W/xnu-pristine"
rm -rf "${W:?}/dxb/xnu" "${W:?}/dxb/build/xnu.obj" "${W:?}/dxb/build/xnu.sym"
cp -R "$W/xnu-pristine" "$W/dxb/xnu"

cd "$W/dxb"
export PATH="$W/bin:$PATH" DEVELOPER_DIR="$APP/Contents/Developer"
export MACOS_VERSION=13.5 KERNEL_CONFIG=${KERNEL_CONFIG:-DEVELOPMENT} MACHINE_CONFIG=NEGRONI KDKROOT="$W/kdk-empty"
xcodebuild -version
bash build.sh 2>&1 | tee "$W/build.log"
D=$OUT/kernel/local-$(date -u +%Y%m%d-%H%M%S)
mkdir -p "$D"
find fakeroot/System/Library/Kernels -maxdepth 1 -type f -name "kernel.*" -exec cp {} "$D/" \;
grep -E "Applying patch|Skipping patch" "$W/build.log" | sed -E 's#.*(Applying|Skipping) patch:? .*/patches/#\1 #' > "$D/patch-report.txt" || true
(cd "$D" && shasum -a 256 kernel.* > SHA256SUMS)
ln -sfn "$(basename "$D")/kernel.$(echo "$KERNEL_CONFIG" | tr '[:upper:]' '[:lower:]').negroni" "$OUT/kernel/kernel.macho"
# dxb skips a patch that does not apply (git apply --check): ours (02xx+) must all apply
echo "skipped patches:"; grep "^Skipping" "$D/patch-report.txt" || echo "  none"
if grep -qE "^Skipping 0[2-9][0-9][0-9]-" "$D/patch-report.txt"; then echo "ERROR: a patches/xnu patch did not apply (above)" >&2; fi
"$REPO/scripts/lib/notify.sh" "local kernel build done: $D"
ls -l "$D" "$OUT/kernel/kernel.macho"
