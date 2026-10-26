#!/bin/sh
# Symbolise the last kernel panic in a USB log (patch 0360 sends the panic text over USB) against the
# linked kernel. macOS and Linux (needs nm and objdump/llvm-objdump).
#   scripts/debug/panic-symbolize.sh                 newest logs/usblog-*.txt, kernel = out/kernel/kernel.macho
#   scripts/debug/panic-symbolize.sh LOG [KERNEL]    a given log (or a photo transcript: any text with pc:/lr:)
#   scripts/debug/panic-symbolize.sh -a ADDR...      only resolve addresses
# Prints: the panic string, far/esr decoded, pc/lr/caller as symbol+offset, and 12 instructions before
# and after pc. Output also goes to logs/panic-<time>.txt.
set -eu
REPO=$(cd "$(dirname "$0")/../.." && pwd)
K=$REPO/out/kernel/kernel.macho
OBJDUMP=$(command -v llvm-objdump || command -v objdump || true)
if [ "${1:-}" = -a ]; then shift; ADDRS="$*"; LOG=""; else
  LOG=${1:-$(ls -t "$REPO"/logs/usblog-*.txt 2>/dev/null | head -1)}
  [ -n "${2:-}" ] && K=$2
  ADDRS=""
fi
[ -f "$K" ] || { echo "no kernel $K" >&2; exit 1; }
OUT=$REPO/logs/panic-$(date +%Y%m%d-%H%M%S).txt
SYMS=$(mktemp); trap 'rm -f "$SYMS"' EXIT
nm -n "$K" 2>/dev/null | awk '$2 ~ /^[TtDdBbSs]$/ {print $1, $3}' > "$SYMS"

resolve() { # ADDR -> "symbol+off"
  python3 - "$SYMS" "$1" <<'PY'
import sys
a=int(sys.argv[2],16); best=None
for l in open(sys.argv[1]):
    p=l.split()
    if len(p)<2: continue
    v=int(p[0],16)
    if v<=a and (best is None or v>best[0]): best=(v,p[1])
print('%s+%#x' % (best[1], a-best[0]) if best else '?')
PY
}

{
if [ -n "$LOG" ]; then
  echo "log: $LOG"; echo "kernel: $K ($(readlink "$K" 2>/dev/null || true))"
  # the last panic block: from the last "panic(cpu" line to the "far:" line after it
  BLOCK=$(grep -a -n -E 'panic\(cpu|Kernel data abort|Kernel instruction fetch abort' "$LOG" | tail -1 | cut -d: -f1)
  [ -n "$BLOCK" ] || { echo "no panic in $LOG"; exit 1; }
  sed -n "${BLOCK},\$p" "$LOG" | sed -n '1,/far:/p' > "$SYMS.block"
  echo; sed 's/^[0-9:]* //' "$SYMS.block" | head -3 | cut -c1-200
  PC=$(grep -a -o 'pc: *0x[0-9a-f]*' "$SYMS.block" | tail -1 | grep -o '0x[0-9a-f]*') || true
  LR=$(grep -a -o 'lr: *0x[0-9a-f]*' "$SYMS.block" | tail -1 | grep -o '0x[0-9a-f]*') || true
  FAR=$(grep -a -o 'far: *0x[0-9a-f]*' "$SYMS.block" | tail -1 | grep -o '0x[0-9a-f]*') || true
  ESR=$(grep -a -o 'esr: *0x[0-9a-f]*' "$SYMS.block" | tail -1 | grep -o '0x[0-9a-f]*') || true
  CALLER=$(grep -a -o 'caller 0x[0-9a-f]*' "$SYMS.block" | tail -1 | grep -o '0x[0-9a-f]*') || true
  echo
  python3 - "${ESR:-0}" "${FAR:-0}" <<'PY'
import sys
esr=int(sys.argv[1],16); far=int(sys.argv[2],16)
ec=esr>>26; iss=esr&0x1ffffff; dfsc=iss&0x3f; wnr=(iss>>6)&1
fsc={0x04:'translation fault L0',0x05:'translation fault L1',0x06:'translation fault L2',0x07:'translation fault L3',
     0x09:'access flag L1',0x0a:'access flag L2',0x0b:'access flag L3',0x0d:'permission L1',0x0e:'permission L2',0x0f:'permission L3',
     0x10:'synchronous external abort (SEA: the bus / hypervisor refused the access)',0x11:'TAG check fault',0x21:'alignment fault'}
kind={0x25:'data abort (kernel)',0x24:'data abort (user)',0x21:'instruction abort (kernel)',0x20:'instruction abort (user)',0x3c:'BRK',0x0e:'illegal execution',0x00:'unknown'}.get(ec,'EC %#x'%ec)
print('esr %#x: %s, %s, DFSC %#x = %s' % (esr, kind, 'write' if wnr else 'read', dfsc, fsc.get(dfsc,'?')))
if far==0: print('far 0: NULL pointer (a struct field read from a zeroed/NULL pointer)')
elif far < 0x1000: print('far %#x: NULL + small offset (field at offset %#x of a NULL struct)' % (far,far))
elif far>>40 == 0xfffffe: print('far %#x: kernel VA' % far)
else: print('far %#x' % far)
PY
  ADDRS="$PC $LR ${CALLER:-}"
fi
for a in $ADDRS; do
  printf '%s  %s\n' "$a" "$(resolve "$a")"
done
if [ -n "$OBJDUMP" ] && [ -n "${PC:-}" ]; then
  echo; echo "== around pc"
  S=$(printf '0x%x' $((PC - 48))); E=$(printf '0x%x' $((PC + 52)))
  "$OBJDUMP" -d --start-address="$S" --stop-address="$E" "$K" 2>/dev/null | grep -E '^ *[0-9a-f]+:' | sed "s/^ *$(printf '%x' $PC):/>>$(printf '%x' $PC):/" | cut -c1-110
fi
} | tee "$OUT"
echo "saved: $OUT" >&2
