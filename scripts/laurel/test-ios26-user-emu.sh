#!/bin/sh
# Host test of a lowered root: each program must reach main() under ios26-user-emu.py. Programs: the ones that died on the phone in
# boot 8 (ANECompiler over-written by trampolines, docs/laurel_sprout/ios26-entry.md), and one that lived.
#   scripts/bg.sh ios26-user-emu scripts/laurel/test-ios26-user-emu.sh [LOWERED_DIR]
#   CRASHLOG=FILE     instead: every program with a "CRASH name[pid] sig 11" line in that USB log. One line per program, parallel.
set -eu
. "$(dirname "$0")/../lib/env.sh"
L=${1:-$HOME/op10-apple/ios26/23F84-n104ap/lowered}
export EMU_LOWERED=$L
W=$OUT/user-emu
mkdir -p "$W"
"$REPO/scripts/laurel/ios26-user-emu.sh" --help > /dev/null   # makes the venv once, before the parallel runs
if [ -n "${CRASHLOG:-}" ]; then
  names=$(grep -a -o -E 'CRASH [^ []+\[[0-9]+\] sig 11' "$CRASHLOG" | sed -E 's/CRASH ([^[]+)\[.*/\1/' | sort -u)
  progs=
  for n in $names; do
    f=$(find "$L/macho/os" -type f -name "$n*" -perm -u+r | grep -v -E 'Tests|\.dylib$|\.plist$|\.plugin/' | head -1)
    [ -n "$f" ] && progs="$progs ${f#"$L/macho/os"}" || echo "no file for $n"
  done
else
  progs="/usr/libexec/runningboardd /usr/libexec/watchdogd /usr/libexec/DumpPanic /usr/libexec/seld /usr/libexec/powerexceptionsd /usr/sbin/notifyd"
fi
one() {
  log=$W/$(basename "$1").log
  if "$REPO/scripts/laurel/ios26-user-emu.sh" "$1" --secs 600 > "$log" 2>&1; then
    echo "$1: $(grep -a '^reached main' "$log")"
  else
    echo "$1: $(grep -a '^RESULT' "$log" | sed 's/^RESULT [^:]*: //') $(grep -a '^pc ' "$log" | cut -c1-70)"
    echo x >> "$W/.bad"
  fi
}
rm -f "$W/.bad"
n=0
for p in $progs; do
  one "$p" &
  n=$((n + 1))
  [ $((n % NPROC)) = 0 ] && wait
done
wait
[ ! -e "$W/.bad" ] && echo "PASS: $n programs reach main() on $L" || { echo "FAIL: $(wc -l < "$W/.bad") of $n programs on $L"; exit 1; }
