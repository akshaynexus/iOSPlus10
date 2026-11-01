#!/bin/sh
# Mi A3: build the root, flash userdata (ERASES the iOS data: owner confirms first), flash boot_b, boot, capture the USB log.
#   scripts/bg.sh laurel-full scripts/laurel/root-flash-test.sh     (always in tmux; sudo password: tmux attach -t laurel-full)
# Needs: the stages for root.sh and out/laurel/uefi/laurel-uefi-boot.img built, the USB log listener running (make usblog).
# The phone can be in iOS (ctl bootloader) or in fastboot. HOLD_S=420: log time. The phone stays in iOS after the test.
set -eu
. "$(dirname "$0")/../lib/env.sh"
cd "$(dirname "$0")/../.."
fb() { lsusb | grep -q 18d1:d00d; }
to_fastboot() { fb || out/bin/op10tool ctl bootloader || true; until fb; do sleep 2; done; }
sudo env APPLE="${APPLE:-$HOME/op10-apple}" scripts/laurel/root.sh
to_fastboot
scripts/laurel/flash-root.sh
# flash-root ends with a reboot into the old boot_b; wait for it, then back to fastboot for the new kernel
i=0; until out/bin/op10tool ctl ping 2>/dev/null | grep -q pong || fb; do sleep 2; i=$((i + 1)); [ $i -lt 120 ] || break; done
to_fastboot
env IMG=out/laurel/uefi/laurel-uefi-boot.img HOLD_S="${HOLD_S:-420}" NOBACK=1 BOOT=reboot scripts/laurel/boot-test.sh
