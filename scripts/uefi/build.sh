#!/bin/sh
# Build Mu-Silicium negroniPkg in the build container.
#   scripts/uefi/build.sh [DEBUG|RELEASE]      (default DEBUG, like the port)
# Output: out/mu/SILICIUM_UEFI-<target>.fd (copied from the Mu Build/ folder).
# Long: run it as  scripts/bg.sh mu-build scripts/uefi/build.sh
set -eu
. "$(dirname "$0")/../lib/env.sh"
TARGET=${1:-DEBUG}
MU=$EXT/Mu-Silicium-negroni
"$REPO/scripts/setup/in-docker.sh" sh -c "cd '$MU' && UNIXNU_ROOT='$EXT/UniXNU' python3 build_uefi.py -d negroni -r $TARGET"
fd=$MU/Build/negroniPkg/${TARGET}_CLANGPDB/FV/SILICIUM_UEFI.fd
mkdir -p "$OUT/mu"
cp "$fd" "$OUT/mu/SILICIUM_UEFI-$TARGET.fd"
ls -l "$OUT/mu/SILICIUM_UEFI-$TARGET.fd"
