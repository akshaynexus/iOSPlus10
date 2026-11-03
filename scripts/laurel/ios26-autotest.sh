#!/bin/bash
# Mi A3 iOS 26: an agent tests the UI with no finger, from the PC over SSH and USB. Docs: docs/laurel_sprout/ios26-autotest.md.
#   scripts/laurel/ios26-autotest.sh install             build laurel-autotest, copy it to /usr/local/bin on the phone (no other file; a file in /var/tmp has no entitlements)
#   scripts/laurel/ios26-autotest.sh check               LAUREL AUTOTEST: on|off: ...
#   scripts/laurel/ios26-autotest.sh tap X Y [MS]        also: swipe X0 Y0 X1 Y1 [MS], edge bottom|top|left|right [LEN] [MS] [AT], key power|volup|voldown|home [MS]. Panel pixels 720x1560
#   scripts/laurel/ios26-autotest.sh open BUNDLE_ID      start an app; home: go to the Home Screen
#   scripts/laurel/ios26-autotest.sh shot [NAME]         the frame on the panel: logs/autotest-shots/NAME.png
#   scripts/laurel/ios26-autotest.sh seq N [MAX_MS]      N flips: logs/autotest-shots/seq-TIME/ and one line with frames that equal an older frame, and black frames
#   scripts/bg.sh autotest scripts/laurel/ios26-autotest.sh run [--only a,b] [--scenario FILE]    the scenario; the table is in logs/autotest-DATE.txt
#   scripts/laurel/ios26-autotest.sh test                the tests that need no phone
# Env as scripts/net/ssh-phone.sh. Never flashes, never reboots, never restarts a process, never changes a setting on the phone.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
. "$REPO/scripts/lib/env.sh"
SSHP=$REPO/scripts/net/ssh-phone.sh
TOOL=/usr/local/bin/laurel-autotest
OP=$OUT/bin/op10tool
SHOTS=$REPO/logs/autotest-shots

need_op() {
  [ -x "$OP" ] || { echo "ios26-autotest: no $OP: scripts/bg.sh op10tool scripts/setup/build-op10tool.sh" >&2; exit 2; }
}

case "${1:-}" in
install)
  "$REPO/userland/laurel/autotest/build.sh"
  "$SSHP" push "$OUT/laurel/autotest/laurel-autotest" /private/var/tmp/laurel-autotest.new
  # A new file: scp writes in place, and the kernel keeps the signature of the old contents of a file that ran. /var/tmp has no valid signature here.
  "$SSHP" "cp /private/var/tmp/laurel-autotest.new $TOOL.new && chmod 755 $TOOL.new && mv $TOOL.new $TOOL; rm -f /private/var/tmp/laurel-autotest.new; $TOOL check"
  ;;
shot)
  need_op
  mkdir -p "$SHOTS"
  name=${2:-shot-$(date +%H%M%S)}
  "$SSHP" "$TOOL shot" > "$SHOTS/$name.bin"
  "$OP" autotest-png "$SHOTS/$name.bin" "$SHOTS/$name.png"
  ;;
seq)
  need_op
  [ -n "${2:-}" ] || { echo "usage: $0 seq N [MAX_MS]" >&2; exit 2; }
  mkdir -p "$SHOTS"
  name=seq-$(date +%H%M%S)
  "$SSHP" "$TOOL seq $2 ${3:-3000}" > "$SHOTS/$name.bin"
  "$OP" autotest-seq "$SHOTS/$name.bin" "$SHOTS/$name"
  echo "files: $SHOTS/$name/"
  ;;
home)
  "$SSHP" "$TOOL key home"
  ;;
run)
  need_op
  shift
  OP10TOOL=$OP exec python3 -I "$REPO/scripts/laurel/ios26-autotest.py" "$@"
  ;;
test)
  OP10TOOL=$OP python3 -I "$REPO/scripts/laurel/ios26-autotest.py" --self-test
  cargo test --release --manifest-path "$REPO/tools/op10tool/Cargo.toml" --target-dir "$OUT/cargo" autotest
  ;;
check|tap|swipe|edge|key|open|surfaces|awake)
  args=$*
  exec "$SSHP" "$TOOL $args"
  ;;
*)
  sed -n 2,11p "$0"
  exit 2
  ;;
esac
