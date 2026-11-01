#!/bin/bash
# Build the patched UniXNU as a plain AArch64 EFI app (UniXNU's own package/build.sh, Mu_Basecore of the Mu tree) and run scripts/laurel/boot-menu-qemu.py. No phone.
#   scripts/bg.sh menu-qemu scripts/laurel/boot-menu-qemu.sh
#   Needs the trees of scripts/laurel/mu-private-tree.sh after a mu-build.sh there (MU_TREE, UNIXNU_TREE; default out/laurel-mu-tree).
set -euo pipefail
. "$(dirname "$0")/../lib/env.sh"
T=$OUT/laurel-mu-tree
MU=${MU_TREE:-$T/Mu-Silicium-negroni}
UNIXNU=${UNIXNU_TREE:-$T/UniXNU}
GPT_DUMP=${GPT_DUMP:-$HOME/laurel-backup/android-20261102-0137}
cp "$REPO/tools/laurel-slot/laurel_slot.c" "$REPO/tools/laurel-slot/laurel_slot.h" "$REPO/tools/laurel-slot/uefi/LaurelSlot.c" "$UNIXNU/package/UniXNUPkg/Library/UniXNULib/"
PATH=$OUT/venv-mu/bin:$PATH UNIXNU_EDK2=$MU/Mu_Basecore "$UNIXNU/package/build.sh" -b DEBUG 2>&1 | tail -12
python3 -I "$REPO/scripts/laurel/boot-menu-qemu.py" "$UNIXNU/package/Build/Out/AARCH64-DEBUG/UniXNU.efi" "$GPT_DUMP" "$OUT/laurel/menu-qemu"
