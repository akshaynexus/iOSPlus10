#!/bin/bash
# Full kernel + the display image for patches 0268 (panel wake with the full on-command + PPS) and
# 0269 (panel double buffering with a DPU base flip), under the shared kernel lock out/kernel/.lock
# (held across the kernel and the image build). Optional TREE: a patched tree
# (scripts/kernel/patched-tree.sh) whose display files are syntax-checked first.
#   scripts/bg.sh dpu-kernel scripts/display/build-dpu.sh [TREE]
#   KERNEL_ONLY=1 scripts/display/build-dpu.sh [TREE]     the kernel only (no image)
# Image (config args + the args below; negronifb_sleep=1 = DCS sleep, the 0268 wake is the default
# negronifb_wake=2):
#   out/ios16-dpu   negronifb_sleep=1 negronifb_dbuf=1 negronipanic=30 negronipanicreason=2
# Fallback args on the phone: negronifb_wake=1 (no memory DMA), negronifb_wake=0 (0258 wake),
# negronifb_sleep=0 (no DCS sleep), negronifb_dbuf=0 (one buffer).
# The vendor_boot and the ADT come from out/ios16 (unchanged by these patches).
set -euo pipefail
. "$(dirname "$0")/../lib/env.sh"
cd "$REPO"
ADD="negronifb_sleep=1 negronifb_dbuf=1 negronipanic=30 negronipanicreason=2"
DROP="negronifb_sleep= negronifb_dbuf= negronipanic= negronipanicreason="
until mkdir "$OUT/kernel/.lock" 2>/dev/null; do echo "waiting for out/kernel/.lock"; sleep 30; done
trap 'rmdir "$OUT/kernel/.lock" 2>/dev/null || true' EXIT
if [ -n "${1:-}" ]; then
  while [ -d "$OUT/kernel/local.lock" ]; do echo "waiting for a running build-local"; sleep 30; done
  for f in iokit/Kernel/arm/NegroniBacklight.cpp iokit/Kernel/arm/NegroniFramebuffer.cpp iokit/Kernel/arm/NegroniGPU.cpp; do
    scripts/kernel/compile-one.sh "$1" "$f"
  done
fi
scripts/kernel/build-local.sh
D=$OUT/kernel/$(dirname "$(readlink "$OUT/kernel/kernel.macho")")
for p in 0258 0259 0267 0268 0269 0275; do
  grep -q "^Applying $p-" "$D/patch-report.txt" || { echo "ERROR: patch $p is not applied ($D/patch-report.txt)" >&2; exit 1; }
done
grep -E "^Skipping" "$D/patch-report.txt" || true
if [ "${KERNEL_ONLY:-0}" = 1 ]; then
  echo "== kernel $D"; cat "$D/SHA256SUMS" 2>/dev/null || shasum -a 256 "$D/kernel.development.negroni"
  exit 0
fi
O=$OUT/ios16-dpu
mkdir -p "$O"
cp "$OUT/ios16/negroni.adt" "$OUT/ios16/vendor_boot_a.img" "$O/"
IOS16_OUT=$O BOOTARGS_DROP="$DROP" BOOTARGS_ADD="$ADD" scripts/ios16/build.sh payload
IOS16_OUT=$O BOOTARGS_DROP="$DROP" BOOTARGS_ADD="$ADD" scripts/ios16/build.sh boot
echo "== $O"; cat "$O/cmdline.txt"; cat "$O/SHA256SUMS"
echo "== kernel $D"; cat "$D/SHA256SUMS" 2>/dev/null || shasum -a 256 "$D/kernel.development.negroni"
