#!/bin/bash
# Read the Mi A3 stock modem firmware for facts about the radio path (read-only; output stays in out/re-modem, git-ignored).
#   scripts/debug/modem-re.sh [NON-HLOS.bin]            extract modem.* + mcfg list, join the segments, make the string table
#   scripts/debug/modem-re.sh grep PATTERN              grep the string table
set -eu
. "$(dirname "$0")/../lib/env.sh"
D=$OUT/re-modem
mkdir -p "$D"
if [ "${1:-}" = grep ]; then shift; exec grep -a -E -n "$@" "$D/modem.strings"; fi
IMG=${1:-$HOME/laurel-backup/stock/images/NON-HLOS.bin}
[ -f "$IMG" ] || { echo "modem-re: no $IMG" >&2; exit 1; }
mdir -/ -b -i "$IMG" ::/image/modem_pr > "$D/modem_pr.list" 2>/dev/null || true
mdir -b -i "$IMG" ::/image > "$D/image.list"
mkdir -p "$D/seg"
mcopy -n -i "$IMG" '::/image/modem.*' "$D/seg/"
cat "$D"/seg/modem.b* > "$D/modem.all"
strings -n 6 "$D/modem.all" > "$D/modem.strings"
wc -l "$D/modem.strings" "$D/modem_pr.list" "$D/image.list"
