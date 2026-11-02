#!/bin/sh
# Host test of the Mi A3 memory map (patch 2974): mkadt.py --dram auto on fake Mu FDs, the start.s bootstrap table budget, and the kernel's
# window self-check (osfmk/arm64/laurel_ram.c from patches 2100 + 2974, compiled for the host). macOS and Linux, about 2 s, foreground is fine.
# No script here or elsewhere starts XNU in QEMU: scripts/laurel/boot-menu-qemu.sh stops at the UEFI menu. So start.s and arm_vm_init do not run here.
set -eu
. "$(dirname "$0")/../lib/env.sh"
D=$OUT/ram-map-test
rm -rf "$D"
mkdir -p "$D/h/pexpert/arm64" "$D/h/kern" "$D/h/vm"
awk '/^\+\+\+ b\/osfmk\/arm64\/laurel_ram\.c$/ {p=1; next}
     p && /^diff / {exit}
     p && /^@@/ {next}
     p && /^\+/ {print substr($0, 2)}' "$REPO/patches/laurel/xnu/2100-laurel-ram-window.patch" > "$D/laurel_ram.c"
awk '/^diff --git a\/osfmk\/arm64\/laurel_ram\.c/ {p=1}
     p && /^diff --git/ && !/laurel_ram\.c/ {exit}
     p {print}' "$REPO/patches/laurel/xnu/2974-laurel-gpu-pool-1g-kernel-ram.patch" > "$D/2974-ram.patch"
(cd "$D" && patch -s -p3 laurel_ram.c < 2974-ram.patch)
for h in pexpert/arm64/board_config.h kern/misc_protos.h kern/startup.h pexpert/pexpert.h pexpert/arm64/boot.h pexpert/device_tree.h vm/vm_page.h; do : > "$D/h/$h"; done
${CC:-cc} -O1 -Wall -Wextra -Wno-unused-parameter -Wno-format -I"$D" -I"$D/h" -I"$REPO/tools/laurel-ram-test" -o "$D/laurel_ram_test" "$REPO/tools/laurel-ram-test/laurel_ram_test.c"
"$D/laurel_ram_test"
python3 -I "$REPO/scripts/laurel/ram-map-test.py" "$D"
