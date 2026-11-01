#!/bin/bash
# One annotated listing of a method of the 20H392 shared cache (helper of scripts/debug/cell-statusbar-re.sh; run that first for the symbol lists).
#   scripts/debug/cell-dis.sh IMAGE 'exact symbol' COUNT NAME     -> out/re-cell/NAME.s
# Quick: ~10 s. IPSW= and DSC= as in cell-statusbar-re.sh.
set -euo pipefail
here=$(cd "$(dirname "$0")/../.." && pwd)
IPSW=${IPSW:-$(command -v ipsw || echo "$here/out/laurel-metal/ipsw/ipsw")}
DSC=${DSC:-$here/out/mnt-cryptex/root/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64}
W=$here/out/re-cell
[ -f "$W/$1-syms.txt" ] || "$IPSW" dyld symaddr "$DSC" --image "$1" > "$W/$1-syms.txt" 2>/dev/null
addr=$(LC_ALL=C awk -v s="$2" -F'\t' '$3 == s { sub(":", "", $1); print $1; exit }' "$W/$1-syms.txt")
[ -n "$addr" ] || { echo "cell-dis: no symbol '$2' in $1" >&2; exit 1; }
"$IPSW" dyld disass "$DSC" --vaddr "$addr" --count "$3" --quiet 2>/dev/null | python3 -I "$here/scripts/debug/dsc-annotate.py" "$DSC" > "$W/$4.s"
echo "$4: $addr ($(wc -l < "$W/$4.s") lines)"
