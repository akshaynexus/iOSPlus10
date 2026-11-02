#!/bin/sh
# Run a lowered iOS 26 program on the host until main(): dyld + lowered cache under Unicorn (scripts/laurel/ios26-user-emu.py).
#   scripts/laurel/ios26-user-emu.sh /usr/libexec/runningboardd [--verbose] [--inits] [--trace-after 0]
#   EMU_LOWERED=DIR   lowered folder (default ~/op10-apple/ios26/23F84-n104ap/lowered)
# Host only. Unicorn is in its own venv under out/. One run takes seconds, so this may run in the foreground.
set -eu
. "$(dirname "$0")/../lib/env.sh"
V=$OUT/venv-user-emu
[ -x "$V/bin/python" ] || python3 -m venv "$V"
"$V/bin/python" -c 'import unicorn' 2>/dev/null || "$V/bin/pip" -q install 'unicorn==2.1.4'
exec "$V/bin/python" -I "$REPO/scripts/laurel/ios26-user-emu.py" "$@"
