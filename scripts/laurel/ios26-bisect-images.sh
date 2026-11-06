#!/bin/sh
# Mi A3 iOS 26: one rw boot image per kill switch, for a bisect of an early hang; host only, nothing written to the phone.
#   scripts/bg.sh ios26-bisect scripts/laurel/ios26-bisect-images.sh [NAME=ARGS ...]
# Default set (smallest change first), each with ufsqueue=0 and LAUREL_PANIC_SECS=0 as the test images of 2026-11-07:
#   ramtop0   laurelramtop=0                      DarwinBoot gives no RAM above the window (mu 0104, 3022)
#   lockto0   laurellockto=0                      spin-lock timeouts stay 0 as before 2994
#   motion0   laurelcpumotion=0 gpumotion=0       3020, 3021
#   ucache0   laurelucache=0                      2998 (the trap off; with 3040 the kill switch is safe)
#   alloff    all of the above + laureltcoal=0 laureltouchfast=0 laurel_audio_lead=0
# Output: out/laurel-ios26/bisect/NAME/laurel-uefi-boot.img (+ .stamp, .dualboot), the same inputs and marks as `dual-boot.sh image rw`
# (the records of out/laurel/dualboot). Flash by hand as the first command of a fresh fastboot session (ios26-fast-flash.sh does that).
set -eu
cd "$(dirname "$0")/../.."
. scripts/lib/env.sh
D=$OUT/laurel/dualboot
RESULT=$D/first-boot.result; PREWRITE=$D/pre-write-backup
_inst=$(sed -n 's/^installed .* \([0-9a-f]\{64\}\)$/\1/p' "$RESULT" 2>/dev/null | tail -1)
_fws=; [ ! -f "$PREWRITE" ] || _fws=$(sed -n 1p "$PREWRITE")/SHA256SUMS
[ $# -gt 0 ] || set -- 'ramtop0=laurelramtop=0' 'lockto0=laurellockto=0' 'motion0=laurelcpumotion=0 gpumotion=0' 'ucache0=laurelucache=0' \
  'alloff=laurelramtop=0 laurellockto=0 laurelcpumotion=0 gpumotion=0 laurelucache=0 laureltcoal=0 laureltouchfast=0 laurel_audio_lead=0'
for v in "$@"; do
  n=${v%%=*}; a=${v#*=}
  w=$OUT/laurel-ios26/bisect/$n
  echo "== $n: EXTRA_ARGS=\"ufsqueue=0 $a\""
  env UEFI_W="$w" LAUREL_READONLY=0 IOSROOT_HEAD_SHA="$_inst" FW_B_SUMS="$_fws" LAUREL_PANIC_SECS=0 EXTRA_ARGS="ufsqueue=0 $a" \
    sh scripts/laurel/ios26-image.sh > "$w.log" 2>&1 || { tail -5 "$w.log"; echo "ios26-bisect: $n FAILED"; exit 1; }
  grep -q '^mode rw$' "$w/laurel-uefi-boot.img.dualboot" || { echo "ios26-bisect: $n is not rw"; exit 1; }
  scripts/laurel/android-guard.sh boot-image "$w/laurel-uefi-boot.img" > /dev/null || { echo "ios26-bisect: the guard refuses $n"; exit 1; }
  echo "   $w/laurel-uefi-boot.img  $(sha256sum "$w/laurel-uefi-boot.img" | cut -c1-16)  $(sed -n 's/^cmdline=//p' "$w/laurel-uefi-boot.img.stamp" | grep -o 'ufsqueue=0.*')"
done
echo "ios26-bisect: done"
