#!/bin/sh
# Build Mu-Silicium negroniPkg in the build container.
#   scripts/uefi/build.sh [DEBUG|RELEASE]      (default DEBUG, like the port)
# Output: out/mu/SILICIUM_UEFI-<target>.fd (copied from the Mu Build/ folder).
# Long: run it as  scripts/bg.sh mu-build scripts/uefi/build.sh
set -eu
. "$(dirname "$0")/../lib/env.sh"
TARGET=${1:-DEBUG}
MU=$EXT/Mu-Silicium-negroni
# build_uefi.py skips stuart setup/update when a Build/ folder exists (e.g. after a stopped run), so
# the NuGet dependencies (mu_nasm, Mu-Basetools, onecrypto-bin, ...) could stay missing. Run both
# steps explicitly first; they are quick when everything is already in place.
"$REPO/scripts/setup/in-docker.sh" sh -c "
  set -e
  cd '$MU'
  export UNIXNU_ROOT='$EXT/UniXNU'
  python3 Platforms/OnePlus/negroniPkg/DeviceBuild.py --setup -t $TARGET
  python3 Platforms/OnePlus/negroniPkg/DeviceBuild.py --update -t $TARGET
  python3 build_uefi.py -d negroni -r $TARGET"
fd=$MU/Build/negroniPkg/${TARGET}_CLANGPDB/FV/SILICIUM_UEFI.fd
mkdir -p "$OUT/mu"
cp "$fd" "$OUT/mu/SILICIUM_UEFI-$TARGET.fd"
ls -l "$OUT/mu/SILICIUM_UEFI-$TARGET.fd"
