#!/bin/sh
# Source files docs/laurel_sprout/boot-menu.md reads (no code from them runs here). Output: out/refs/boot-menu/ (git-ignored).
#   scripts/bg.sh menu-refs scripts/laurel/boot-menu-refs.sh
set -eu
. "$(dirname "$0")/../lib/env.sh"
D=$OUT/refs/boot-menu; mkdir -p "$D"
get() { # NAME URL: one try per branch name, stops at the first answer
  n=$1; shift
  for u in "$@"; do
    if curl -fsSL --retry 2 -o "$D/$n" "$u"; then echo "$n <- $u"; return 0; fi
  done
  echo "MISSING $n" >&2; return 0
}
RAW=https://raw.githubusercontent.com
B=$RAW/LineageOS/android_hardware_qcom_bootctrl
get boot_control.cpp "$B/lineage-24.0-caf/boot_control.cpp" "$B/lineage-23.2-caf/boot_control.cpp" "$B/lineage-23.0-caf/boot_control.cpp" "$B/lineage-22.2-caf/boot_control.cpp" "$B/lineage-22.2/boot_control.cpp"
get BootControl.cpp "$B/lineage-24.0-caf/aidl/BootControl.cpp" "$B/lineage-23.2-caf/aidl/BootControl.cpp"
G=$RAW/LineageOS/android_hardware_qcom_bootctrl
get gpt-utils.h "$G/lineage-24.0-caf/gpt-utils.h" "$G/lineage-23.2-caf/gpt-utils.h"
get gpt-utils.cpp "$G/lineage-24.0-caf/gpt-utils.cpp" "$G/lineage-23.2-caf/gpt-utils.cpp"
A=$RAW/QRD-Development/abl/uefi.lnx.3.0.r12-rel/QcomModulePkg
get abl-PartitionTableUpdate.c "$A/Library/BootLib/PartitionTableUpdate.c"
get abl-PartitionTableUpdate.h "$A/Include/Library/PartitionTableUpdate.h"
get abl-BootLinux.c "$A/Library/BootLib/BootLinux.c"
get abl-LinuxLoader.c "$A/Application/LinuxLoader/LinuxLoader.c"
get abl-FastbootCmds.c "$A/Library/FastbootLib/FastbootCmds.c"
ls -l "$D"
