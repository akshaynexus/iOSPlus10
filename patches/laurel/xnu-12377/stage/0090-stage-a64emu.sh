#!/bin/sh
# The EL0 emulator of the iOS 26 kernel: the files in tools/laurel-a64emu, the same ones as the host test (scripts/laurel/test-a64emu.sh). Only this kernel.
set -eu
R=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
for f in laurel_a64emu.c laurel_a64emu.h laurel_a64emu_asm.h; do
  cp "$R/tools/laurel-a64emu/$f" "osfmk/arm64/$f"
done
