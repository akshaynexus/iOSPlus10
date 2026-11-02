#!/bin/sh
# Host proof of kernel patch post/9010, with the real code of 23F84 under ios26-user-emu.py: the gate of BlastDoor/Sandbox.swift in MessagesBlastDoorService.
#   scripts/bg.sh blastdoor-test scripts/laurel/test-ios26-blastdoor.sh [LOWERED_DIR]
# Without the answer: fatal "BlastDoor cannot run unsandboxed." With it: sandbox_check of itself, state flag blastdoor-post-launch, the gate returns. Host only.
set -eu
. "$(dirname "$0")/../lib/env.sh"
export EMU_LOWERED="${1:-$HOME/op10-apple/ios26/23F84-n104ap/lowered}"
E=/System/Library/PrivateFrameworks/MessagesBlastDoorSupport.framework/XPCServices/MessagesBlastDoorService.xpc/MessagesBlastDoorService
W=$OUT/user-emu
mkdir -p "$W"
a=0
"$REPO/scripts/laurel/ios26-user-emu.sh" "$E" --secs 300 --blastdoor-gate > "$W/blastdoor-old.log" 2>&1 || a=$?
grep -a '^RESULT blastdoor-gate' "$W/blastdoor-old.log"
[ "$a" = 3 ] && grep -aq 'fatal: BlastDoor cannot run unsandboxed' "$W/blastdoor-old.log" || { echo "FAIL: old kernel answer: expected the fatal"; exit 1; }
b=0
"$REPO/scripts/laurel/ios26-user-emu.sh" "$E" --secs 300 --blastdoor-gate --sandbox-self > "$W/blastdoor-new.log" 2>&1 || b=$?
grep -a -e '^RESULT blastdoor-gate' -e "^sandbox_enable_state_flag" "$W/blastdoor-new.log"
[ "$b" = 0 ] && grep -aq "sandbox_enable_state_flag 'blastdoor-post-launch'" "$W/blastdoor-new.log" || { echo "FAIL: new kernel answer: the gate did not return"; exit 1; }
echo PASS
