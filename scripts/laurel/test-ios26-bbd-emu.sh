#!/bin/sh
# Host test of the crash of boot 9 (docs/laurel_sprout/ios26-backboardd.md): CoreBrightness' real code under Unicorn, with a fake IOKit at the function level.
#   scripts/bg.sh ios26-bbd-emu scripts/laurel/test-ios26-bbd-emu.sh [LOWERED_DIR]
# 1 today's registry: the phone's fault: pc CoreBrightness+0x169924, lr +0x165298, far 0.
# 2 with the properties of post/9005: the function returns a display, with the table.
# 3 with these properties: the frames of the crash: handleDisplayArrival: -> setupInternalModules -> the module of the crash, to their end.
# Not a proof of what follows: no CADisplay, no XPC, no threads. Blocks stay on their queues. Host only.
set -eu
. "$(dirname "$0")/../lib/env.sh"
export EMU_LOWERED=${1:-$HOME/op10-apple/ios26/23F84-n104ap/lowered}
W=$OUT/user-emu/bbd
mkdir -p "$W"
python3 -I "$REPO/scripts/laurel/ios26-backlight-props.py" before "$W/before.plist"
python3 -I "$REPO/scripts/laurel/ios26-backlight-props.py" after "$W/after.plist"
E_=$REPO/scripts/laurel/ios26-user-emu.sh
"$E_" /usr/libexec/backboardd --secs 500 --display-create "$W/before.plist" > "$W/before.log" 2>&1 || true
"$E_" /usr/libexec/backboardd --secs 500 --display-create "$W/after.plist" > "$W/after.log" 2>&1 || true
"$E_" /usr/libexec/backboardd --secs 500 --display-create "$W/after.plist" --container > "$W/container.log" 2>&1 || true
bad=0
grep -a -q 'RESULT display-create: did not return: pc CoreBrightness+0x169924 .* lr CoreBrightness+0x165298 .*stop fault 0$' "$W/before.log" && echo "before: the phone's fault: pc CoreBrightness+0x169924, lr +0x165298, far 0" || { echo "before: NOT the phone's fault: $(grep -a 'RESULT display-create' "$W/before.log")"; bad=1; }
if grep -a -q 'RESULT display-create: returned a display' "$W/after.log"; then
  echo "after: returned a display"; grep -a -E '^(display 0x|lMaxProduct|digital dimming)' "$W/after.log"
  grep -a -q 'digital dimming flag +0x5ec 0' "$W/after.log" || { echo "after: digital dimming is on"; bad=1; }
else echo "after: $(grep -a 'RESULT display-create' "$W/after.log")"; bad=1; fi
grep -a -q 'RESULT display-create: the container path returned' "$W/container.log" && echo "container: handleDisplayArrival: and setupInternalModules returned" || { echo "container: $(grep -a 'RESULT display-create' "$W/container.log")"; bad=1; }
[ $bad = 0 ] && echo "PASS: logs in $W" || { echo "FAIL: logs in $W"; exit 1; }
