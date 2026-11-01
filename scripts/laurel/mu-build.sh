#!/bin/sh
# Build Mu-Silicium laurel_sproutPkg (Xiaomi Mi A3, SM6125) with UniXNU + DarwinBoot, natively on Linux (stuart, no
# container; macOS needs the BaseTools steps of scripts/uefi/build-macos.sh).
#   scripts/bg.sh laurel-mu scripts/laurel/mu-build.sh [DEBUG|RELEASE]      (always in tmux; 10-30 min the first time)
#   SETUP=0: skip the submodule setup (scripts/uefi/setup-mu.sh) when the tree is already prepared
#   CLEAN=1: empty Build/laurel_sproutPkg first
#   MU_RAM_LAYOUT=static (default) | late: memory map for the XNU window (docs/laurel_sprout/uefi-boot.md "RAM").
#     static = mu 0101: "Kernel RAM" 0xE1000000-0x1C0000000 in the static map (6 GB Mi A3 only; UEFI allocates
#     above 4 GiB from its first DXE). late = mu late/0101 instead (applied last): 240 MiB "UEFI RAM" 0x81000000
#     for early UEFI, RamManagerDxe adds 0xE1000000-0x1C0000000 late. Use late when Mu dies with the static map.
#     The ADT follows the FD (mkadt.py --dram auto); both give the window 0xE1004000 + 3264 MiB.
# Base: external/Mu-Silicium-negroni (akshaynexus fork of Project-Silicium/Mu-Silicium; it carries the UniXNU/DarwinBoot
# pieces negroni uses: SEC entry-argument HOB, NegroniBootMemoryDxe, Mu_Basecore boot-menu/timer patches). Its
# Platforms/Xiaomi/laurel_sproutPkg is identical to upstream Mu-Silicium 4bd8ae83 (checked 2026-11-01); our
# changes are patches/laurel/mu/*.patch (applied here, tree reset first). Qualcomm DXEs: the fork's Binaries
# submodule (Project-Silicium/Device-Binaries a1501e0c) has laurel_sprout/ (46 drivers, ButtonsDxe + ClockDxe patched).
# Output: out/laurel/mu/SILICIUM_UEFI-<target>.fd, out/laurel/mu/BootShim.bin (FD_BASE 0x5FC00000, 0x300000),
#         out/laurel/mu/Mu-laurel_sprout.img (Mu's own boot image, header v1, for reference only: we build ours
#         with scripts/laurel/uefi-image.sh).
set -eu
. "$(dirname "$0")/../lib/env.sh"
TARGET=${1:-DEBUG}
# MU_TREE / UNIXNU_TREE: build from other checkouts (a parallel agent's copy; default the submodules)
MU=${MU_TREE:-$EXT/Mu-Silicium-negroni}
UNIXNU=${UNIXNU_TREE:-$EXT/UniXNU}
VENV=$OUT/venv-mu
O=$OUT/laurel/mu
[ "$(uname -s)" = Linux ] || { echo "mu-build: Linux only (macOS: port the BaseTools steps of scripts/uefi/build-macos.sh)" >&2; exit 1; }
for t in clang lld-link llvm-lib llvm-objcopy uv git curl make python3; do
  command -v $t >/dev/null || { echo "mu-build: missing host tool $t" >&2; exit 1; }
done
[ -e "$MU/.git" ] || { echo "mu-build: external/Mu-Silicium-negroni is not checked out (git submodule update --init external/Mu-Silicium-negroni)" >&2; exit 1; }
[ -e "$UNIXNU/.git" ] || { echo "mu-build: external/UniXNU is not checked out (git submodule update --init external/UniXNU)" >&2; exit 1; }
T0=$(date +%s)
say() { echo "$(date +%H:%M:%S) mu-build: $*"; }

# 1. Python: Mu's own requirements (edk2-pytool-*) in their own venv (out/venv has only the image tools)
if [ ! -x "$VENV/bin/python3" ]; then uv venv -q "$VENV"; fi
VIRTUAL_ENV=$VENV uv pip install -q -r "$MU/pip-requirements.txt" pyyaml
say "venv $VENV: $("$VENV/bin/python3" -c 'import edk2toolext; print("edk2toolext", edk2toolext.__version__)' 2>/dev/null || echo edk2toolext)"

# 2. Submodules at the fork's pins + the fork's negroni patches (Mu_Basecore, Silicium-ACPI); DarwinBoot submodule
if [ "${SETUP:-1}" = 1 ]; then
  "$REPO/scripts/uefi/setup-mu.sh"
fi
# 3. Our laurel changes: reset every file they touch (before the DarwinBoot submodule update: a pin change cannot
# check out over a patched file), then apply them in order (re-runnable; a later patch may change a file an
# earlier one changed, e.g. mu 0101 after 0001). A patch whose paths start with DarwinBootPkg/ (mu 0102) goes to
# UniXNU's DarwinBoot submodule, one with package/ (mu 0201) to UniXNU, the others to the Mu tree. MU_RAM_LAYOUT=late: late/*.patch replace 0101, last.
DB=$UNIXNU/drivers/DarwinBoot
LAYOUT=${MU_RAM_LAYOUT:-static}
case "$LAYOUT" in static|late) ;; *) echo "mu-build: MU_RAM_LAYOUT must be static or late" >&2; exit 1 ;; esac
target() { if grep -q '^+++ b/DarwinBootPkg/' "$1"; then echo "$DB"; elif grep -q '^+++ b/package/' "$1"; then echo "$UNIXNU"; else echo "$MU"; fi; }
for pt in "$REPO"/patches/laurel/mu/*.patch "$REPO"/patches/laurel/mu/late/*.patch; do
  [ -f "$pt" ] || continue
  t=$(target "$pt")
  [ -e "$t/.git" ] || continue
  grep -E '^\+\+\+ b/' "$pt" | sed 's|^+++ b/||' | while read -r f; do git -C "$t" checkout -q -- "$f" 2>/dev/null || true; done
done
[ "${SETUP:-1}" != 1 ] || git -C "$UNIXNU" submodule update -q --init --depth 1 drivers/DarwinBoot   # SETUP=0: tree already prepared (scripts/laurel/mu-private-tree.sh)
say "DarwinBoot $(git -C "$UNIXNU/drivers/DarwinBoot" rev-parse --short HEAD), UniXNU $(git -C "$UNIXNU" rev-parse --short HEAD), Mu fork $(git -C "$MU" rev-parse --short HEAD), RAM layout $LAYOUT"
if [ "$LAYOUT" = late ]; then
  PATCHES=$(ls "$REPO"/patches/laurel/mu/*.patch | grep -v '/0101-'; ls "$REPO"/patches/laurel/mu/late/*.patch)
else
  PATCHES=$(ls "$REPO"/patches/laurel/mu/*.patch)
fi
for pt in $PATCHES; do
  t=$(target "$pt")
  git -C "$t" apply "$pt"
  say "applied $(basename "$pt") to $(case "$t" in "$DB") echo DarwinBoot ;; "$UNIXNU") echo UniXNU ;; *) echo Mu ;; esac)"
done
# the boot menu's slot core: one source, also built by the host test (scripts/laurel/boot-menu-test.sh). mu 0201 lists these in UniXNULib.inf.
cp "$REPO/tools/laurel-slot/laurel_slot.c" "$REPO/tools/laurel-slot/laurel_slot.h" "$REPO/tools/laurel-slot/uefi/LaurelSlot.c" "$UNIXNU/package/UniXNUPkg/Library/UniXNULib/"
miss=0
for f in $(grep -rhoE 'Binaries/laurel_sprout/[^ |}]+' "$MU/Platforms/Xiaomi/laurel_sproutPkg" | sort -u); do
  [ -e "$MU/$f" ] || { echo "MISSING $f"; miss=1; }
done
[ "$miss" = 0 ] || { echo "mu-build: Binaries/laurel_sprout incomplete" >&2; exit 1; }
say "all Binaries/laurel_sprout references present"

# 4. NuGet-type deps (mu_nasm) without NuGet/Mono
"$REPO/scripts/uefi/fetch-extdeps.sh"

# 5. stuart setup/update/build. CLANGPDB: clang + lld-link + llvm-lib from the host; objcopy = llvm-objcopy.
cd "$MU"
export UNIXNU_ROOT="$UNIXNU" PYTHON_COMMAND=python3 CLANGPDB_AARCH64_PREFIX=llvm- GIT_CONFIG_COUNT=1 \
       GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0='*' PATH="$VENV/bin:$PATH"
python3 Platforms/Xiaomi/laurel_sproutPkg/DeviceBuild.py --setup -t "$TARGET"
python3 Platforms/Xiaomi/laurel_sproutPkg/DeviceBuild.py --update -t "$TARGET"
python3 build_uefi.py -d laurel_sprout -r "$TARGET" ${CLEAN:+-c}
fd=$MU/Build/laurel_sproutPkg/${TARGET}_CLANGPDB/FV/SILICIUM_UEFI.fd
[ -f "$fd" ] || { echo "mu-build: no $fd" >&2; exit 1; }
mkdir -p "$O"
cp "$fd" "$O/SILICIUM_UEFI-$TARGET.fd"
cp BootShim/BootShim.bin "$O/BootShim.bin"
[ -f Mu-laurel_sprout.img ] && mv -f Mu-laurel_sprout.img "$O/Mu-laurel_sprout.img"
ls -l "$O"
say "done in $(( $(date +%s) - T0 )) s: $O/SILICIUM_UEFI-$TARGET.fd"
