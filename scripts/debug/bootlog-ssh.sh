#!/bin/sh
# Read the kernel boot log (patch 0367) over SSH instead of the USB command server, and print the summary.
#   scripts/debug/bootlog-ssh.sh [COUNT]      (COUNT: only the newest COUNT boots)
# Copies /dev/negronibootlog (root, read-only: the boot log area as a file, 8201 used blocks = 32 MiB) to
# out/bootlog/area-<date>.bin with dd over scripts/net/ssh-phone.sh, then runs `op10tool bootlog --file`
# (logs/bootlog-<boot>.txt per boot). Takes about 30 s on the USB link. Same env as ssh-phone.sh.
set -eu
REPO=$(cd "$(dirname "$0")/../.." && pwd)
. "$REPO/scripts/lib/env.sh"
D=$OUT/bootlog
mkdir -p "$D"
F=$D/area-$(date +%Y%m%d-%H%M%S).bin
"$REPO/scripts/net/ssh-phone.sh" "dd if=/dev/negronibootlog bs=4096 count=8201 2>/dev/null" > "$F"
sz=$(wc -c < "$F" | tr -d ' ')
[ "$sz" -ge 4096 ] || { echo "bootlog-ssh: $F has $sz bytes (kernel without 0367, or the boot log is off)" >&2; exit 1; }
echo "area dump: $F ($sz bytes)"
cd "$REPO"
# shellcheck disable=SC2086
"$OUT/bin/op10tool" bootlog --file "$F" ${1:-}
