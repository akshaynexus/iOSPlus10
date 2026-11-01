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
L=$RAW/LineageOS
for b in lineage-24.0 lineage-23.2 lineage-23.0; do
  get "adb-$b-main.cpp" "$L/android_packages_modules_adb/$b/daemon/main.cpp" || true
  [ -s "$D/adb-$b-main.cpp" ] && { AB=$b; break; }
done
AB=${AB:-lineage-23.2}
get adb-main.cpp "$L/android_packages_modules_adb/$AB/daemon/main.cpp"
get adb-socket_spec.cpp "$L/android_packages_modules_adb/$AB/socket_spec.cpp"
get adb-transport_fd.cpp "$L/android_packages_modules_adb/$AB/transport_fd.cpp"
get adb-transport_server.cpp "$L/android_packages_modules_adb/$AB/transport_server.cpp" "$L/android_packages_modules_adb/$AB/transport_local.cpp"
get adb-restart_service.cpp "$L/android_packages_modules_adb/$AB/daemon/restart_service.cpp"
for b in lineage-24.0 lineage-23.2 lineage-23.0; do
  get "AdbService-$b.java" "$L/android_frameworks_base/$b/services/core/java/com/android/server/adb/AdbService.java"
  get "AdbDebuggingManager-$b.java" "$L/android_frameworks_base/$b/services/core/java/com/android/server/adb/AdbDebuggingManager.java"
  get "LineageSettings-$b.java" "$L/android_lineage-sdk/$b/sdk/src/java/lineageos/providers/LineageSettings.java" "$L/android_lineage-sdk/$b/sdk/src/java/lineageos/providers/LineageSettings.java"
  [ -s "$D/AdbService-$b.java" ] && break
done
ls -l "$D" | tail -14
