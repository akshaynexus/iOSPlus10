#!/bin/sh
# Full kernel build (all patches/xnu, 0330 + 0331 among them) + the Bluetooth test image, under the shared
# kernel lock out/kernel/.lock (held across both steps, as the agent rules require).
#   scripts/bg.sh bt-build scripts/bt/build-test-image.sh
# Output: out/kernel/local-<time>/kernel.development.negroni (link out/kernel/kernel.macho), out/ios16-bt/
# (config boot-args + negronibt=3: power, UART, HCI, firmware download; negronipanic=30 negronipanicreason=2).
# negronibt=3 needs out/firmware/wlan-area.bin with the BT pack on the phone (scripts/bt/mkbtarea.sh).
set -eu
. "$(dirname "$0")/../lib/env.sh"
L=$OUT/kernel/.lock
until mkdir "$L" 2>/dev/null; do sleep 30; done
trap 'rmdir "$L" 2>/dev/null || true' EXIT
"$REPO/scripts/kernel/build-local.sh"
IOS16_OUT=$OUT/ios16-bt BOOTARGS_ADD="negronibt=3 negronipanic=30 negronipanicreason=2" "$REPO/scripts/ios16/build.sh"
shasum -a 256 "$OUT/kernel/kernel.macho" "$OUT/ios16-bt/boot_a.img"
