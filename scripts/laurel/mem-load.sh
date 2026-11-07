#!/bin/sh
# Mi A3 iOS 26: fill the memory until the compressor swaps (docs/laurel_sprout/memory.md section 5): builds laurel-memhog, copies it to
# /usr/local/bin on the phone (an rw root), runs it as root under the phone lock, and reads the kernel's LAUREL SWAP lines from the USB log.
#   scripts/laurel/mem-load.sh [MIB=2500] [HOLD_S=90]
set -eu
REPO=$(cd "$(dirname "$0")/../.." && pwd); cd "$REPO"
MIB=${1:-2500}; HOLD=${2:-90}
LOG=logs/usblog.log
sh userland/laurel/memhog/build.sh >/dev/null
n0=$(wc -l < "$LOG" 2>/dev/null || echo 0)
sh scripts/laurel/phone-lock.sh mem-load sh -c "
  sh scripts/laurel/phone-ssh.sh push out/laurel/memhog/laurel-memhog /usr/local/bin/laurel-memhog >/dev/null
  sh scripts/laurel/phone-ssh.sh 'chmod 755 /usr/local/bin/laurel-memhog; /usr/local/bin/laurel-memhog $MIB $HOLD; ls -la /private/var/vm; vm_stat | grep -E \"compressor|Swap|Compressions\"'"
echo "# kernel lines during the load:"
tail -n +"$((n0 + 1))" "$LOG" | grep -a -E 'LAUREL SWAP|low swap|killing largest|CRASH .*memhog|jetsam' | cut -c1-260
