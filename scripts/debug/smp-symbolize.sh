#!/bin/bash
# Symbolize the periodic thread dumps of the kernel ("SMP <proc>[pid] slide S mh M" + "SMP <proc> tN pc
# .. lr .. bt ..") of a USB log against the iOS 16 dyld shared cache (macOS + Linux; needs blacktop/ipsw).
#   scripts/debug/smp-symbolize.sh LOG [PROCESS] [FROM-LINE]
#     LOG        logs/usblog-*.txt
#     PROCESS    only this process (default: backboardd)
#     FROM-LINE  start at this line of LOG (default 1); every "SMP --- sample" after it is printed
# Cache: $DSC (the dyld_shared_cache_arm64 file), else the Cryptex of ~/op10-apple/20H392 mounted
# read-only with apfs-fuse at out/mnt-cryptex. ipsw: $IPSW, else ipsw in PATH, else
# out/laurel-metal/ipsw/ipsw. Addresses inside the cache are unslid with the logged slide; addresses
# in the main binary are printed as "main + offset" (from mh); other addresses (dylibs outside the
# cache, e.g. our libtopaz-gl / Mesa) are printed as "? (not in the cache)". Plain POSIX awk (no gawk needed).
# macOS: mount the Cryptex dmg yourself (hdiutil attach -readonly) and set DSC.
# One a2s call takes ~7 s; unique addresses run in parallel ($NPROC) and an a2s cache is kept in
# out/smp-symbolize/.
set -euo pipefail
here=$(cd "$(dirname "$0")/../.." && pwd)
LOG=${1:?usage: $0 LOG [PROCESS] [FROM-LINE]}; P=${2:-backboardd}; FROM=${3:-1}
IPSW=${IPSW:-$(command -v ipsw || echo "$here/out/laurel-metal/ipsw/ipsw")}
[ -x "$IPSW" ] || { echo "needs ipsw (brew install blacktop/tap/ipsw, or scripts/laurel/metal-build.sh fetch)" >&2; exit 1; }
if [ -z "${DSC:-}" ]; then
  mnt=$here/out/mnt-cryptex
  if [ ! -d "$mnt/root/System" ]; then
    mkdir -p "$mnt"; apfs-fuse -o ro "$HOME/op10-apple/20H392/087-86593-047.dmg" "$mnt"
  fi
  DSC=$mnt/root/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64
fi
[ -f "$DSC" ] || { echo "no shared cache at $DSC (set DSC)" >&2; exit 1; }
work=$here/out/smp-symbolize; mkdir -p "$work"
NPROC=${NPROC:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu)}

lines=$(tail -n +"$FROM" "$LOG" | grep -a -E "SMP (--- sample|$P\[[0-9]+\] slide|$P t[0-9]+ )" || true)
[ -n "$lines" ] || { echo "no SMP lines of $P after line $FROM" >&2; exit 1; }
# unslid cache addresses: (address - slide); the cache of iOS 16 is 0x180000000..0x280000000 (decimal below: POSIX awk)
awk -v p="$P" '
  function hex(x,   i, v, c) { v = 0; x = tolower(x); sub(/^0x/, "", x); for (i = 1; i <= length(x); i++) { c = index("0123456789abcdef", substr(x, i, 1)); v = v * 16 + c - 1 } return v }
  /SMP .*\[[0-9]+\] slide/ { for (i = 1; i <= NF; i++) { if ($i == "slide") s = hex($(i+1)); if ($i == "mh") m = hex($(i+1)) } next }
  / pc 0x/ { for (i = 1; i <= NF; i++) if ($i ~ /^0x[0-9a-f]+$/) { a = hex($i) - s; if (a >= 6442450944 && a < 10737418240) printf "%#x\n", a } }
' <<<"$lines" | sort -u > "$work/addrs"
if [ ! -s "$work/a2s.cache" ] && [ -s "$work/addrs" ]; then   # build the a2s cache once (~35 s)
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
awk -v p="$P" 'function hex(x,   i, v, c) { v = 0; x = tolower(x); sub(/^0x/, "", x); for (i = 1; i <= length(x); i++) { c = index("0123456789abcdef", substr(x, i, 1)); v = v * 16 + c - 1 } return v }
  NR == FNR { k = $1; $1 = ""; sym[k] = substr($0, 2); next }
  /SMP --- sample/ { print; next }
  /SMP .*\[[0-9]+\] slide/ { for (i = 1; i <= NF; i++) { if ($i == "slide") s = hex($(i+1)); if ($i == "mh") m = hex($(i+1)) } print; next }
  / pc 0x/ {
    out = ""
    for (i = 1; i <= NF; i++) if ($i == "pc" || $i == "lr" || $i == "bt") break
    head = ""; for (j = 1; j < i; j++) head = head $j " "
    print head
    for (; i <= NF; i++) {
      if ($i !~ /^0x[0-9a-f]+$/) { tag = $i; continue }
      v = hex($i); a = v - s; k = sprintf("%#x", a)
      if (k in sym) d = sym[k]
      else if (v >= m && v < m + 16777216) d = sprintf("main + %#x", v - m)
      else if (v == 0) d = "-"
      else d = "? (not in the cache)"
      printf "    %-3s %s  %s\n", tag, $i, d
    }
  }' "$work/syms" <(printf '%s\n' "$lines")
