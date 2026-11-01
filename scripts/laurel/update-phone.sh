#!/bin/sh
# Mi A3: one command from sources to the phone with its data kept: build everything, update the root in place, flash the kernel to boot_b. No userdata flash.
#   scripts/bg.sh rupd-phone scripts/laurel/update-phone.sh           (always in tmux; sudo password for root.sh: tmux attach -t rupd-phone)
# Steps: build-all.sh, root.sh (writes the sparse image for a clean install and the update payload), flash-check, root-update.sh (REBOOT=0), then `ctl bootloader`,
#        boot-test.sh (boot_b only), root-update.sh --after-boot (registers new apps). docs/laurel_sprout/root-update.md.
# BUILD=0: no build, use what is there. KERNEL=0: no boot_b flash; `ctl reboot` instead. HOLD_S=180: log time. The phone stays in iOS.
# Exit 3 from the root update = only a full flash can do this: this script stops; nothing was written. Clean install: scripts/laurel/root-flash-test.sh.
# Needs: USB log listener (make usblog), SSH to the phone. Same switches as root.sh (AUDIO=0 ...).
set -eu
. "$(dirname "$0")/../lib/env.sh"
# main(): sh reads a function whole, so an edit of this file during the run cannot change what runs
main() {
cd "$(dirname "$0")/../.."
M=scripts/laurel/root-manifest.py
APPLE=${APPLE:-$HOME/op10-apple}
BOOTIMG=out/laurel/uefi/laurel-uefi-boot.img
fb() { lsusb | grep -q 18d1:d00d; }
to_fastboot() { fb || out/bin/op10tool ctl bootloader || true; until fb; do sleep 2; done; }
if [ "${BUILD:-1}" != 0 ]; then
  scripts/laurel/build-all.sh
  python3 -I "$M" preflight
  # shellcheck disable=SC2046  # the words are NAME=VALUE switches
  sudo env APPLE="$APPLE" $(python3 -I "$M" switches) scripts/laurel/root.sh
fi
python3 -I "$M" flash-check "$APPLE/laurel-ios16-root.manifest" "$APPLE/laurel-ios16-root.simg" "$BOOTIMG"
if [ "${KERNEL:-1}" = 0 ]; then
  scripts/laurel/root-update.sh
  return 0
fi
# The root first: then the phone reboots only once, into the new kernel and the new root together
REBOOT=0 scripts/laurel/root-update.sh
to_fastboot
ROOT_UPDATE_WAIT_S=${ROOT_UPDATE_WAIT_S:-900} scripts/laurel/root-update.sh --after-boot &
after=$!
env IMG="$BOOTIMG" HOLD_S="${HOLD_S:-180}" NOBACK=1 BOOT=reboot scripts/laurel/boot-test.sh
wait "$after"
echo "update-phone: done: kernel in boot_b, root updated, /private/var kept"
}
main "$@"
exit 0
