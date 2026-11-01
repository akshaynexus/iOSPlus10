#!/bin/bash
# Repair and verify a Mi A3 root image (HFS+). Exit 0 = clean; exit 1 = no sparse image may be made from it. root.sh and root-audio.sh call it.
#   scripts/laurel/root-fsck.sh IMAGE [--verify-first]
#   --verify-first: no repair when the first verify is clean (after mkiosroot, which ended with its own repair).
# Linux fsck_hfs 540.1 repairs the volume header and reports "Volume header needs minor repair (1, 0)" again on the next verify-only pass
# (seen 2026-11-01 after 3 repairs; catalog, extents, bitmap and attributes all pass). Exactly that one finding is accepted. Any other stops.
set -uo pipefail
IMG=${1:?usage: $0 IMAGE [--verify-first]}
ts() { date +%H:%M:%S; }
[ "${2:-}" != --verify-first ] || ! fsck.hfsplus -f -n "$IMG" >/dev/null 2>&1 || { echo "$(ts) root-fsck: volume clean"; exit 0; }
for i in 1 2 3; do
  echo "$(ts) root-fsck: repair pass $i"
  fsck.hfsplus -f -y "$IMG" 2>&1 | grep -v 'Illegal name' | tail -3
  if fsck.hfsplus -f -n "$IMG" >/dev/null 2>&1; then echo "$(ts) root-fsck: volume clean"; exit 0; fi
done
v=$(fsck.hfsplus -f -n "$IMG" 2>&1)
others=$(printf '%s\n' "$v" | grep -E 'needs|invalid|Invalid|incorrect|Incorrect|error|Error|missing|Missing|overlap' |
  grep -v 'Volume header needs minor repair' | grep -v 'needs to be repaired')
if printf '%s\n' "$v" | grep -q 'Volume header needs minor repair' && [ -z "$others" ]; then
  echo "$(ts) root-fsck: note: only 'Volume header needs minor repair' remains (Linux fsck_hfs); accepted"
  exit 0
fi
echo "root-fsck: FAILED: volume not clean after 3 repairs" >&2
printf '%s\n' "$v" | tail -8 >&2
exit 1
