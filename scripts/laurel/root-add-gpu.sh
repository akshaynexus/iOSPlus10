#!/bin/bash
# Install the Mi A3 GPU user space into a mounted, writable iOS 16 root (scripts/laurel/root.sh calls it; idempotent).
#   sudo scripts/laurel/root-add-gpu.sh MOUNTED_ROOT
# Input: out/laurel/gpu/root/ from scripts/laurel/gpu-userland.sh (+ gpu-firmware.sh for the firmware). Without it: a note, exit 0
# (the root still boots; the kernel logs 'LAUREL GPU: off: zap shader failed: no zap shader ...').
# What it does:
#   /topaz/lib/{libOSMesa.8.dylib,libtopaz-gl.dylib,libtopaz-inject.dylib}   (root:wheel 755)
#   /usr/share/firmware/laurel/{a610_zap.mdt,a610_zap.bNN,a630_sqe.fw}     (root:wheel 644; the kernel reads them)
#   /usr/libexec/real/backboardd = Apple's backboardd (moved once), /usr/libexec/backboardd = bbd_wrap (topaz): it adds
#   /topaz/lib/libtopaz-inject.dylib to DYLD_INSERT_LIBRARIES when the file is there and execs the real one (same pid,
#   same Mach services). libtopaz-inject waits up to 5 s for RedwoodGPU and loads libtopaz-gl only then; without the GPU
#   CoreAnimation keeps its software renderer. Kill switches: boot-arg gl=0 (no GL in backboardd), gpu=0 (no GPU).
# Undo: mv usr/libexec/real/backboardd usr/libexec/backboardd; rm -rf topaz usr/share/firmware/laurel.
set -euo pipefail
R=${1:?usage: $0 MOUNTED_ROOT}
REPO=$(cd "$(dirname "$0")/../.." && pwd)
S=$REPO/out/laurel/gpu/root
R=$(cd "$R" && pwd -P)
[ "$R" != / ] || { echo "root-add-gpu: refusing to install into /" >&2; exit 1; }
[ -d "$R/System/Library/xpc" ] && [ -x "$R/usr/libexec/backboardd" ] || { echo "root-add-gpu: $R is not an iOS root" >&2; exit 1; }
if [ ! -s "$S/topaz/lib/libtopaz-gl.dylib" ]; then
  echo "root-add-gpu: skipped: no $S (scripts/laurel/gpu-firmware.sh + gpu-userland.sh); the root has no GPU user space"
  exit 0
fi
own() { [ "$(id -u)" != 0 ] || chown -R 0:0 "$@"; }

mkdir -p "$R/topaz/lib"
for f in libOSMesa.8.dylib libtopaz-gl.dylib libtopaz-inject.dylib; do
  install -m 755 "$S/topaz/lib/$f" "$R/topaz/lib/$f"
done
own "$R/topaz"; chmod 755 "$R/topaz" "$R/topaz/lib"

if [ -d "$S/usr/share/firmware/laurel" ]; then
  mkdir -p "$R/usr/share/firmware/laurel"
  rm -f "$R/usr/share/firmware/laurel/"*
  install -m 644 "$S/usr/share/firmware/laurel/"* "$R/usr/share/firmware/laurel/"
  own "$R/usr/share/firmware/laurel"
  fw="$(ls "$R/usr/share/firmware/laurel" | tr '\n' ' ')"
else
  fw="none (the kernel will report 'LAUREL GPU: off')"
fi

# backboardd: Apple's binary moves once; a Mach-O that is our wrapper is never moved over the real one
real=$R/usr/libexec/real/backboardd
if [ ! -e "$real" ]; then
  if strings "$R/usr/libexec/backboardd" | grep -q '/usr/libexec/real/backboardd'; then
    echo "root-add-gpu: /usr/libexec/backboardd is the wrapper but real/backboardd is missing" >&2; exit 1
  fi
  mkdir -p "$R/usr/libexec/real"
  mv "$R/usr/libexec/backboardd" "$real"
fi
install -m 755 "$S/usr/libexec/backboardd.wrap" "$R/usr/libexec/backboardd"
own "$R/usr/libexec/backboardd" "$R/usr/libexec/real"

echo "root-add-gpu: /topaz/lib (Mesa + libtopaz-gl + libtopaz-inject), backboardd wrapper (real: /usr/libexec/real/backboardd), firmware: $fw"
