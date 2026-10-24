#!/bin/sh
# Build Mu-Silicium negroniPkg natively on macOS (Apple silicon): no Docker, no Rosetta, no Mono.
#   scripts/uefi/build-macos.sh [DEBUG|RELEASE]      (run in tmux: make mu-build-macos)
# Upstream supports only Linux/Windows hosts; this script fills the gaps:
# - Compiler: CLANGPDB needs only clang, lld-link and llvm-lib -> Homebrew llvm + lld, linked into
#   out/tools/llvm-bin (CLANG_BIN, used by tools_def.template for CLANGPDB).
# - BaseTools (GenFw, GenFv, GenFfs, ...): the prebuilt Mu-Basetools have no macOS build, so they are
#   compiled from Mu_Basecore/BaseTools/Source/C and put where stuart looks for this host
#   (Mu-Basetools_extdep/MacOs-ARM-64; stuart's host name on Apple silicon).
# - NuGet deps: scripts/uefi/fetch-extdeps.sh (curl). nasm is not used for AARCH64 targets.
# - Python: out/venv (Mu requirements, scripts/setup/native-tools.sh).
# The Mu tree and its Build/ folder are shared with scripts/uefi/build.sh: do not run both at once.
set -eu
. "$(dirname "$0")/../lib/env.sh"
[ "$(uname -s)" = Darwin ] || { echo "macOS only; on Linux use scripts/uefi/build.sh" >&2; exit 1; }
TARGET=${1:-DEBUG}
MU=$EXT/Mu-Silicium-negroni
BT=$MU/Mu_Basecore/BaseTools

# 1. LLVM tools in one folder (llvm and lld are separate Homebrew formulae)
L=$OUT/tools/llvm-bin
mkdir -p "$L"
for d in "$(brew --prefix llvm)/bin" "$(brew --prefix lld)/bin"; do
  for t in "$d"/*; do ln -sf "$t" "$L/$(basename "$t")"; done
done
"$L/clang" --version | head -1
"$L/lld-link" --version | head -1

# 2. BaseTools C tools for this host
make -C "$BT/Source/C" -j"$(sysctl -n hw.ncpu)" CC=clang CXX=clang++ >/dev/null
HOSTDIR=$BT/Bin/Mu-Basetools_extdep/MacOs-ARM-64
mkdir -p "$HOSTDIR"
cp "$BT/Source/C/bin/"* "$HOSTDIR/"
ver=$(awk '/^version:/{print $2}' "$BT/Bin/basetoolsbin_ext_dep.yaml")
printf 'version: %s\n' "$ver" > "$BT/Bin/Mu-Basetools_extdep/extdep_state.yaml"
echo "BaseTools: $(ls "$HOSTDIR" | wc -l | tr -d ' ') tools in ${HOSTDIR#"$MU"/}"

# 3. NuGet-type deps without NuGet
"$REPO/scripts/uefi/fetch-extdeps.sh"

# 4. stuart setup/update/build with the native venv
cd "$MU"
export UNIXNU_ROOT="$EXT/UniXNU" CLANG_BIN="$L/" PATH="$L:$OUT/venv/bin:$PATH"
python3 Platforms/OnePlus/negroniPkg/DeviceBuild.py --setup -t "$TARGET"
python3 Platforms/OnePlus/negroniPkg/DeviceBuild.py --update -t "$TARGET"
python3 build_uefi.py -d negroni -r "$TARGET"
fd=$MU/Build/negroniPkg/${TARGET}_CLANGPDB/FV/SILICIUM_UEFI.fd
mkdir -p "$OUT/mu"
cp "$fd" "$OUT/mu/SILICIUM_UEFI-$TARGET-macos.fd"
ls -l "$OUT/mu/SILICIUM_UEFI-$TARGET-macos.fd"
