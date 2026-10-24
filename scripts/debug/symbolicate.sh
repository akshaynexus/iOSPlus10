#!/bin/bash
# Symbolicate the kernel's CRASH lines from a live USB log (make usblog) against the iOS 16 dyld
# shared cache (macOS and Linux; needs blacktop/ipsw: brew install blacktop/tap/ipsw).
#   scripts/debug/symbolicate.sh LOG [PROCESS] [N]
#     LOG      logs/usblog-*.txt
#     PROCESS  only this process (default: every process that crashed)
#     N        how many crashes per process (default 1: the first one; same-pc repeats are skipped)
# Cache: $DSC, else the root image ~/op10-apple/ios16-root.img attached read-only (macOS), else a
# mounted root at $IOSROOT. Addresses inside the shared cache are unslid with the logged slide;
# others (the main binary) are printed as "image + offset" from the logged mach header (mh).
set -euo pipefail
LOG=${1:?usage: $0 LOG [PROCESS] [N]}; P=${2:-}; N=${3:-1}
command -v ipsw >/dev/null || { echo "needs ipsw (brew install blacktop/tap/ipsw)" >&2; exit 1; }
if [ -z "${DSC:-}" ]; then
  R=${IOSROOT:-}
  if [ -z "$R" ]; then
    R=$(mount | awk '/iOSRoot|iosroot/ {print $3; exit}')
  fi
  if [ -z "$R" ] && [ "$(uname -s)" = Darwin ]; then
    dev=$(diskutil image attach --readOnly --noMount "$HOME/op10-apple/ios16-root.img" | awk '/^\/dev/{print $1; exit}')
    R=/tmp/iosroot-ro; mkdir -p "$R"; diskutil mount readOnly -mountPoint "$R" "$dev" >/dev/null
  fi
  DSC=$R/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64
fi
[ -f "$DSC" ] || { echo "no shared cache at $DSC (set DSC or IOSROOT)" >&2; exit 1; }

a2s() { ipsw dyld a2s "$DSC" "$1" 2>/dev/null | grep -v -E '^\s*$|INFO|WARN' | tail -1; }
procs=$P
[ -n "$procs" ] || procs=$(grep -oE 'CRASH [A-Za-z0-9_.]+\[[0-9]+\] sig' "$LOG" | awk '{sub(/\[.*/,"",$2); print $2}' | sort -u)
for p in $procs; do
  seen=""; n=0
  # one crash = the "sig" line + pc/bt/reason lines of the same process that follow it
  while IFS= read -r head; do
    [ "$n" -lt "$N" ] || break
    slide=$(sed -E 's/.*slide (0x[0-9a-f]+).*/\1/' <<<"$head"); mh=$(sed -E 's/.* mh (0x[0-9a-f]+).*/\1/' <<<"$head")
    t=$(cut -d' ' -f1 <<<"$head")
    regs=$(grep -A3 -F "$head" "$LOG" | grep -m1 "CRASH $p pc ")
    bt=$(grep -A3 -F "$head" "$LOG" | grep -m1 "CRASH $p bt " | sed 's/.* bt //')
    why=$(grep -A4 -F "$head" "$LOG" | grep -m1 "CRASH $p reason" | sed 's/.*reason //')
    pc=$(sed -E 's/.* pc (0x[0-9a-f]+).*/\1/' <<<"$regs"); lr=$(sed -E 's/.* lr (0x[0-9a-f]+).*/\1/' <<<"$regs")
    key="$pc/$lr"; case " $seen " in *" $key "*) continue ;; esac; seen="$seen $key"; n=$((n + 1))
    echo "== $p at $t: ${head#*CRASH }"; echo "   reason: $why"
    for kv in "pc $pc" "lr $lr" $(for a in $bt; do echo "bt:$a"; done); do
      name=${kv%% *}; a=${kv##* }; [ "$name" = "$kv" ] && { name=bt; a=${kv#bt:}; }
      [ "$a" = 0x0 ] && { printf '   %-3s 0x0 (NULL)\n' "$name"; continue; }
      if [ $((a)) -ge $((0x180000000 + slide)) ]; then
        u=$(printf '0x%x' $((a - slide))); printf '   %-3s %s  %s\n' "$name" "$u" "$(a2s "$u" | sed 's/^0x[0-9a-f]*: //')"
      else
        printf '   %-3s %s  main image + 0x%x\n' "$name" "$a" $((a - mh))
      fi
    done
  done < <(grep -E "CRASH $p\[[0-9]+\] sig" "$LOG")
done
