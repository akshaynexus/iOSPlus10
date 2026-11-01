#!/bin/bash
# Symbolize the kernel's "CRASH <proc>[pid] ... slide S mh M" + "CRASH <proc> pc .. lr .. bt .." lines of a USB log against
# the iOS 16 dyld shared cache (macOS + Linux; needs blacktop/ipsw; same cache and a2s cache rules as smp-symbolize.sh).
#   scripts/debug/crash-symbolize.sh LOG [PROCESS]
# Addresses inside the cache come with image!symbol; addresses in the main binary as main+offset; addresses inside
# NegroniMetal or Turnip (from the "NMTL[pid name]: images ..." line of that pid, printed before the crash) as
# NegroniMetal+offset / turnip+offset, for llvm-symbolizer with out/metal/NegroniMetal.dSYM.
set -euo pipefail
here=$(cd "$(dirname "$0")/../.." && pwd)
LOG=${1:?usage: $0 LOG [PROCESS]}; P=${2:-}
IPSW=${IPSW:-$(command -v ipsw || echo "$here/out/laurel-metal/ipsw/ipsw")}
[ -x "$IPSW" ] || { echo "needs ipsw (scripts/laurel/metal-build.sh fetch)" >&2; exit 1; }
if [ -z "${DSC:-}" ]; then
  mnt=$here/out/mnt-cryptex
  [ -d "$mnt/root/System" ] || { mkdir -p "$mnt"; apfs-fuse -o ro "$HOME/op10-apple/20H392/087-86593-047.dmg" "$mnt"; }
  DSC=$mnt/root/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64
fi
[ -f "$DSC" ] || { echo "no shared cache at $DSC (set DSC)" >&2; exit 1; }
work=$here/out/smp-symbolize; mkdir -p "$work"
NPROC=${NPROC:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu)}
sel=${P:-[A-Za-z0-9_.-]+}
lines=$(grep -a -E "CRASH $sel(\[[0-9]+\] sig| pc | bt )|NMTL\[[0-9]+ $sel\]: images " "$LOG" || true)
[ -n "$lines" ] || { echo "no CRASH lines${P:+ of $P}" >&2; exit 1; }
python3 -I "$here/scripts/debug/crash-symbolize.py" addrs <<<"$lines" | sort -u > "$work/addrs"
if [ ! -s "$work/a2s.cache" ] && [ -s "$work/addrs" ]; then
  "$IPSW" dyld a2s --cache "$work/a2s.cache" "$DSC" "$(head -1 "$work/addrs")" >/dev/null 2>&1 || true
fi
touch "$work/syms"
todo=$(grep -v -x -F -f <(cut -d' ' -f1 "$work/syms") "$work/addrs" || true)
if [ -n "$todo" ]; then
  # shellcheck disable=SC2016
  xargs -P "$NPROC" -I{} sh -c '
    r=$("$0" dyld a2s --cache "$1" -i "$2" {} 2>/dev/null | grep -v -E "^\s*$|INFO|WARN|IMAGE|^-+$")
    img=$(printf "%s\n" "$r" | sed -n "s/.*> \([^ ]*\).*/\1/p" | head -1); sym=$(printf "%s\n" "$r" | tail -1 | sed "s/^0x[0-9a-f]*: //")
    echo "{} ${img##*/}!$sym"' "$IPSW" "$work/a2s.cache" "$DSC" <<<"$todo" >> "$work/syms"
fi
python3 -I "$here/scripts/debug/crash-symbolize.py" print "$work/syms" <<<"$lines"
