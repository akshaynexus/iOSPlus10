#!/bin/bash
# Mi A3 iOS 26 boot image: the same chain as scripts/laurel/uefi-image.sh (ABL -> Mu -> UniXNU -> DarwinBoot -> XNU) with the
# xnu-12377 kernel and the donor ADT of the iOS 26 path. Output in its own folder: out/laurel-ios26/uefi/. It writes nothing to the phone.
#   scripts/bg.sh ios26-image scripts/laurel/ios26-image.sh
#   DONOR=n104ap (default)   KERNEL=path   EXTRA_ARGS=...   UEFI_W=path
# Inputs: out/laurel-kernel-ios26/out/kernel.ios26.development.sweet.4k (kernel-ios26-linux.sh), the Mu FD + BootShim (make laurel-mu; a
# worktree takes the main checkout's), the stock boot image (DTB), $APPLE/ios26/23F84-$DONOR/$DONOR.adt (ios26-donor.sh).
set -euo pipefail
. "$(dirname "$0")/../lib/env.sh"
DONOR=${DONOR:-n104ap}
main=$(git -C "$REPO" worktree list --porcelain | sed -n '1s/^worktree //p')
mu=$OUT/laurel/mu; [ -f "$mu/SILICIUM_UEFI-DEBUG.fd" ] || mu=$main/out/laurel/mu
[ -d "$OUT/venv" ] || { [ -d "$main/out/venv" ] && ln -sfn "$main/out/venv" "$OUT/venv"; }
export LAUREL_STAMP_IOS26=1 MU_DIR=$mu UEFI_W=${UEFI_W:-$OUT/laurel-ios26/uefi} MKADT_EXTRA="--donor $DONOR" ENTRY_TITLE=${ENTRY_TITLE:-iOS 26 (laurel XNU)}
export KERNEL=${KERNEL:-$OUT/laurel-kernel-ios26/out/kernel.ios26.development.sweet.4k}
exec "$REPO/scripts/laurel/uefi-image.sh" "$@"
