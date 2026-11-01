#!/bin/sh
# Mi A3: build the root, flash userdata (ERASES the iOS data: owner confirms first), flash boot_b, boot, capture the USB log.
#   scripts/bg.sh laurel-full scripts/laurel/root-flash-test.sh     (always in tmux; sudo password: tmux attach -t laurel-full)
# Needs: the stages for root.sh and out/laurel/uefi/laurel-uefi-boot.img built, the USB log listener running (make usblog).
# The phone can be in iOS (ctl bootloader) or in fastboot. HOLD_S=420: log time. BUILD=0: use the root image that exists (a flash
# retry). The phone stays in iOS after the test.
# Honest build (docs/laurel_sprout/build-honest.md): no sudo and no phone before the stages pass; no phone before root-manifest.py flash-check passes:
# the image exists, its run ended well, no feature is missing, and root, kernel, boot image and stages are still one build. It prints the inputs used.
# STALE_OK=1: flash this image as it is; the problems are still listed. Switches (AUDIO=0 ...) go through sudo.
set -eu
. "$(dirname "$0")/../lib/env.sh"
# main(): sh reads a function whole, so an edit of this file during the run cannot change what runs
main() {
cd "$(dirname "$0")/../.."
M=scripts/laurel/root-manifest.py
APPLE=${APPLE:-$HOME/op10-apple}
SIMG=$APPLE/laurel-ios16-root.simg
BOOTIMG=out/laurel/uefi/laurel-uefi-boot.img
fb() { lsusb | grep -q 18d1:d00d; }
to_fastboot() { fb || out/bin/op10tool ctl bootloader || true; until fb; do sleep 2; done; }
if [ "${BUILD:-1}" != 0 ]; then
  # A failed stage must show now, not after the sudo prompt and the root build
  python3 -I "$M" preflight
  # shellcheck disable=SC2046  # the words are NAME=VALUE switches
  sudo env APPLE="$APPLE" $(python3 -I "$M" switches) scripts/laurel/root.sh
fi
python3 -I "$M" flash-check "$APPLE/laurel-ios16-root.manifest" "$SIMG" "$BOOTIMG"
to_fastboot
scripts/laurel/flash-root.sh
# flash-root ends with a reboot into the old boot_b; wait for it, then back to fastboot for the new kernel
i=0; until out/bin/op10tool ctl ping 2>/dev/null | grep -q pong || fb; do sleep 2; i=$((i + 1)); [ $i -lt 120 ] || break; done
to_fastboot
env IMG="$BOOTIMG" HOLD_S="${HOLD_S:-420}" NOBACK=1 BOOT=reboot scripts/laurel/boot-test.sh
}
main "$@"
exit 0
