#!/bin/sh
# Reflash the iOS root (userdata) on a phone that already runs our iOS chain, in the documented order
# (scripts/flash/ios16.sh header, docs/notes.md "fastbootd entry"): fastbootd boots the kernel from boot_a, so
#   1. bootloader: ios16.sh recovery      (stock boot_a, vendor_boot_a, dtbo_a, so fastbootd can start)
#   2. fastboot reboot fastboot           -> fastbootd
#   3. fastbootd:  ios16.sh userdata      ($APPLE/ios16-root.simg)
#   4. fastboot reboot bootloader
#   5. bootloader: ios16.sh vendor_boot, vbmeta, dtbo, boot with IOS16_OUT=$SAFE (the known-good boot_a), active
#   6. optional: scripts/flash/test-boot.sh TEST (RAM boot of a test image; boot_a keeps $SAFE)
# Run with scripts/bg.sh (it waits for the phone): scripts/bg.sh reflash scripts/flash/reflash-root.sh [TEST_OUT]
# Env: SAFE (default out/ios16-safe). Allowed partitions only (CLAUDE.md): boot_a, vendor_boot_a, vbmeta_a, dtbo_a,
# userdata; slot a.
set -eu
TEST=${1:-}
SAFE=${SAFE:-out/ios16-safe}
F=scripts/flash/ios16.sh
mode() { fastboot getvar is-userspace 2>&1 | sed -n 's/^is-userspace: //p'; }
until fastboot devices 2>/dev/null | grep -q fastboot; do sleep 2; done
[ "$(mode)" = no ] || { fastboot reboot bootloader; sleep 5; until [ "$(mode)" = no ]; do sleep 2; done; }
cur=$(fastboot getvar current-slot 2>&1 | sed -n 's/^current-slot: //p')
[ "$cur" = a ] || { echo "current slot is '$cur', not a: stop" >&2; exit 1; }
echo "== 1 recovery (stock boot/vendor_boot/dtbo)"; $F recovery --yes
echo "== 2 fastbootd"; fastboot reboot fastboot
until [ "$(mode)" = yes ]; do sleep 2; done
echo "== 3 userdata"; $F userdata --yes
echo "== 4 bootloader"; fastboot reboot bootloader; sleep 5
until [ "$(mode)" = no ]; do sleep 2; done
echo "== 5 iOS chain from $SAFE"
for s in vendor_boot vbmeta dtbo boot; do env IOS16_OUT="$SAFE" $F $s --yes; done
shasum -a 256 "$SAFE/boot_a.img" | cut -c1-64 > out/.boot_a.sha256
if [ -n "$TEST" ]; then
  echo "== 6 RAM test $TEST"; fastboot set_active a; scripts/flash/test-boot.sh "$TEST"
else
  env IOS16_OUT="$SAFE" $F active --yes
fi
echo "reflash done $(date +%H:%M:%S)"
