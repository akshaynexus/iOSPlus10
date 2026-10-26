#!/bin/sh
# Test an image without risking the USB link (owner rule 2026-10-27): boot_a keeps a known-good image (default
# out/ios16-safe: stable boot + working USB gadget), the test image boots from RAM with `fastboot boot`, so a hang, a
# watchdog reset or a lost USB gadget falls back to the good boot_a. Run it with scripts/bg.sh (it waits for fastboot):
#   scripts/bg.sh test-boot scripts/flash/test-boot.sh out/ios16-everything [out/ios16-safe]
# Get the phone to fastboot first: out/bin/op10tool ctl bootloader (from iOS or from the panic screen, patch 0360).
set -eu
T=${1:?usage: $0 TEST_OUT [SAFE_OUT]}
SAFE=${2:-out/ios16-safe}
[ -f "$T/boot_a.img" ] && [ -f "$SAFE/boot_a.img" ] || { echo "missing $T/boot_a.img or $SAFE/boot_a.img" >&2; exit 1; }
until fastboot devices 2>/dev/null | grep -q fastboot; do sleep 2; done
cur=$(fastboot getvar current-slot 2>&1 | sed -n 's/^current-slot: //p')
[ "$cur" = a ] || { echo "current slot is '$cur', not a: stop" >&2; exit 1; }
want=$(shasum -a 256 "$SAFE/boot_a.img" | cut -c1-64)
if [ "$(cat out/.boot_a.sha256 2>/dev/null)" != "$want" ]; then
  env IOS16_OUT="$SAFE" scripts/flash/ios16.sh boot --yes
  echo "$want" > out/.boot_a.sha256
fi
fastboot boot "$T/boot_a.img"
echo "ram-booted $T at $(date +%H:%M:%S)"
