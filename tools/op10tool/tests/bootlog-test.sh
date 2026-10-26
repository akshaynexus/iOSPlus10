#!/bin/sh
# Check `op10tool bootlog --file` on a fake area (tools/op10tool/tests/bootlog-fake.py): the summary lines,
# the ring order of a wrapped slot, that a slot with a bad CRC is skipped, and the UDP path with lost datagrams
# (tools/op10tool/tests/bootlog-fake-server.py on 127.0.0.1:5141). Works in out/test/bootlog.
set -eu
REPO=$(cd "$(dirname "$0")/../../.." && pwd)
. "$REPO/scripts/lib/env.sh"
T=$OUT/test/bootlog
rm -rf "$T"; mkdir -p "$T"
python3 "$REPO/tools/op10tool/tests/bootlog-fake.py" "$T/area.bin" >/dev/null
"$OUT/bin/op10tool" bootlog --file "$T/area.bin" --out "$T" --kernels "$T" | tee "$T/summary.txt"
fail=0
ok() { if "$@"; then echo "  ok: $*"; else echo "  FAIL: $*"; fail=1; fi; }
ok grep -q "boot    6 .*end: PANIC: panic(cpu 2" "$T/summary.txt"
ok grep -q "boot    7 .*end: reset without panic" "$T/summary.txt"
ok grep -q "next power-on PMIC PON log: pon=PS_HOLD reset=PMIC_WATCHDOG_S2" "$T/summary.txt"
ok grep -q "boot    5 .*end: clean restart" "$T/summary.txt"
ok test ! -e "$T/bootlog-9.txt"
# wrapped slot: the text must be continuous and end with the last line written
ok sh -c "tail -n 1 '$T/bootlog-7.txt' | grep -q '^boot 7 line'"
last=$(grep -v '^#' "$T/bootlog-7.txt" | sed -n '2,$p' | awk '{print $4}' | awk 'NR>1 && $1 != p+1 {bad=1} {p=$1} END {print bad+0}')
ok test "$last" = 0
# the same area over the UDP protocol (fake server on 127.0.0.1:5141, 10 % of the data datagrams dropped)
python3 "$REPO/tools/op10tool/tests/bootlog-fake-server.py" "$T/area.bin" 10 &
srv=$!
sleep 1
mkdir -p "$T/udp"
"$OUT/bin/op10tool" bootlog --host 127.0.0.1 --out "$T/udp" --kernels "$T" > "$T/udp/summary.txt" || fail=1
kill $srv 2>/dev/null || true
ok grep -q "boot    8 .*end: still running (this boot)" "$T/udp/summary.txt"
# the same console text (the "# end:" header line differs for boot 8: only the UDP source knows the current boot)
for b in 5 6 7 8; do
  grep -v '^#' "$T/bootlog-$b.txt" > "$T/a.txt"; grep -v '^#' "$T/udp/bootlog-$b.txt" > "$T/b.txt"
  ok cmp -s "$T/a.txt" "$T/b.txt"
done
[ $fail = 0 ] && echo "bootlog-test: all ok" || { echo "bootlog-test: FAILED"; exit 1; }
