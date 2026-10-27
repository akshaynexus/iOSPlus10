#!/bin/sh
# Capture where wifid waits when its device init stalls (README-wifi.md "0346 analysis", notes 65).
# Symptom in the kernel log: `wifid gets 96 (VIRTUAL_IF_ROLE)` / `97` and then no `wifid gets 19 (POWER)`,
# no `exec wifianalyticsd` for more than ~10 s. Run this while the stall lasts (SSH root needed).
#   scripts/wifi/wifid-stall.sh [SECONDS]     spindump of wifid (default 3 s) + all processes,
#                                             saved to logs/wifid-spindump-<date>.txt
# Uses /usr/sbin/spindump of the 20H392 root (kernel stackshot). Env as scripts/net/ssh-phone.sh.
set -eu
REPO=$(cd "$(dirname "$0")/../.." && pwd)
SSHP=$REPO/scripts/net/ssh-phone.sh
SEC=${1:-3}
case $SEC in *[!0-9]*|"") echo "wifid-stall: SECONDS must be a number" >&2; exit 2 ;; esac
mkdir -p "$REPO/logs"
OUT=$REPO/logs/wifid-spindump-$(date +%Y%m%d-%H%M%S).txt
R=/private/var/tmp/wifid-spindump.txt
# Target wifid first (its threads sorted on top), all other processes after it: the peer that wifid
# waits for (a daemon in a mach_msg / XPC reply wait) is in the same report.
"$SSHP" "exec /bin/sh -c 'ps ax | grep -E \"[w]ifid|[b]luetoothd|[c]fprefsd|[k]eybagd\"; rm -f $R;
  /usr/sbin/spindump wifid $SEC 10 -o $R >/dev/null 2>&1 || echo \"spindump exit \$?\"; ls -l $R'" </dev/null
"$SSHP" pull "$R" "$OUT"
echo "wifid-stall: $OUT ($(wc -l < "$OUT") lines). Read the wifid main thread stack first."
