#!/bin/bash
# Host test of the touch wire format on 23F84 (docs/laurel_sprout/ios26-touch.md). Each side is real code:
#   kernel: Apple's IOHIDEvent.cpp + SweetHIDTouch::touch of SweetHID.cpp, built on the host (tools/laurel-hid-test): the bytes of one finger down, move, up;
#   iOS: IOHIDEventCreateWithBytesInternal of 23F84 under Unicorn, the call of IOHIDEventServicePlugin, then the real getters.
# 1 the tree without post/9006: the parser cannot read the kernel: no child, no position. 2 with it: every value of the touch comes back.
#   scripts/bg.sh ios26-hid-emu scripts/laurel/test-ios26-hid.sh [LOWERED_DIR]
# Not a proof of what follows: backboardd's event system and UIKit do not run here. Host only.
set -eu
. "$(dirname "$0")/../lib/env.sh"
export EMU_LOWERED=${1:-$HOME/op10-apple/ios26/23F84-n104ap/lowered}
MAIN=$(git -C "$REPO" worktree list --porcelain | sed -n '1s/^worktree //p')
SRC=$OUT/laurel-kernel-ios26/src/xnu; [ -d "$SRC/iokit" ] || SRC=$MAIN/out/laurel-kernel-ios26/src/xnu
W=$OUT/user-emu/hid; rm -rf "$W"; mkdir -p "$W/base"
# the tree before post/9006 (the commit before it, when the tree has it)
c=$(git -C "$SRC" log --format=%H --grep='^post 9006' -1 2>/dev/null || true)
git -C "$SRC" archive "${c:-HEAD}${c:+~1}" iokit/Kernel/arm/hid | tar -x -C "$W/base"
H=$W/base/iokit/Kernel/arm/hid
cp -R "$H" "$W/1915"
mkdir -p "$W/tree2238"; ( cd "$W/tree2238"; git init -q .; cp -R "$W/base/iokit" .; git apply --whitespace=nowarn "$REPO/patches/laurel/xnu-12377/post/9006-laurel-hid-2238.patch" )
S=$REPO/tools/laurel-hid-test
# the real function, cut from the file
awk '/^SweetHIDTouch::touch\(int finger/{print "void"; p=1} p{print} p&&/^}/{exit}' "$H/SweetHID.cpp" > "$W/touch_body.inc"
[ -s "$W/touch_body.inc" ] || { echo "FAIL: no SweetHIDTouch::touch in $H/SweetHID.cpp"; exit 1; }
for v in before:$W/1915 after:$W/tree2238/iokit/Kernel/arm/hid; do
  n=${v%%:*}; d=${v#*:}
  clang++ -std=gnu++17 -w -I"$S/shim" -I"$W" -I"$d" "$S/hid_bytes.cpp" -o "$W/$n"
  "$W/$n" > "$W/$n.json"
  "$REPO/scripts/laurel/ios26-user-emu.sh" /usr/libexec/backboardd --secs 300 --hid-event "$W/$n.json" > "$W/$n.log" 2>&1 || true
  grep -a '^HID \|RESULT hid-event' "$W/$n.log" > "$W/$n.txt" || true
done
python3 -I "$REPO/scripts/laurel/test-ios26-hid-check.py" "$W"
