#!/bin/bash
# Incremental iOS 26 kernel build (developer loop): copy FILEs from the 12377 work tree
# (out/kernel/local-ios26/work, where patches/xnu-12377 are made) into the dxb tree that
# scripts/ios26/build-kernel.sh prepared, then run dxb's kernel make again, with make -k (all errors in one run).
#   scripts/ios26/kernel-make.sh [FILE...]          (FILE relative to the xnu root)
# Xcode 27.1 clang warns on every header (-Wreserved-identifier ...): the UniXNU-ios26 -Wno list keeps the log small.
# Log: out/kernel/local-ios26/make.log; errors: out/kernel/local-ios26/make-errors.txt.
# The release path stays scripts/ios26/build-kernel.sh (fresh tree, every patch applied by dxb).
set -uo pipefail
. "$(dirname "$0")/../lib/env.sh"
W=$OUT/kernel/local-ios26
X=$W/dxb/xnu
APP=${XCODE_APP:-/Applications/Xcode.app}
[ -d "$X" ] || { echo "no $X: run scripts/ios26/build-kernel.sh first" >&2; exit 1; }
for f in "$@"; do cp "$W/work/$f" "$X/$f" && echo "synced $f"; done
export DEVELOPER_DIR=$APP/Contents/Developer
T=$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin
export PATH="$W/bin:$T:$DEVELOPER_DIR/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
F=$W/dxb/fakeroot
KC=${KERNEL_CONFIG:-DEVELOPMENT}
[ "${ARCH_STRING:-arm64}" = arm64e ] && export NEGRONI_ARM64E=1
cd "$X"
make -k install -j"$NPROC" VERBOSE=YES \
  CTFCONVERT="$F/usr/local/bin/ctfconvert" CTFMERGE="$F/usr/local/bin/ctfmerge" CTFDUMP="$F/usr/local/bin/ctfdump" \
  SDKROOT=macosx TARGET_CONFIGS="$KC ARM64 NEGRONI" CONCISE=0 BUILD_WERROR=0 BUILD_LTO=0 \
  SRCROOT="$X" OBJROOT="$W/dxb/build/xnu.obj" SYMROOT="$W/dxb/build/xnu.sym" DSTROOT="$F" FAKEROOT_DIR="$F" \
  KDKROOT="${KDKROOT:-$OUT/kernel/kdk-25F84-headers}" TIGHTBEAMC=tightbeamc-not-supported RC_DARWIN_KERNEL_VERSION=25.5.0 \
  KERNEL_BUILDS_IN_PARALLEL=1 \
  CFLAGS_EXTRA="-Wno-reserved-identifier -Wno-pre-c11-compat -Wno-missing-designated-field-initializers -Wno-suggest-override -Wno-unnecessary-virtual-specifier -Wno-suggest-destructor-override -Wno-ms-bitfield-padding" \
  > "$W/make.log" 2>&1
rc=$?
grep -E "(error|fatal error):" "$W/make.log" | grep -v "^make" | sed "s#$X/##" | sort -u > "$W/make-errors.txt"
echo "make rc=$rc, $(wc -l < "$W/make-errors.txt" | tr -d ' ') error lines (make-errors.txt)"
head -40 "$W/make-errors.txt"
ls -l "$W"/dxb/build/xnu.obj/kernel.* 2>/dev/null
exit $rc
