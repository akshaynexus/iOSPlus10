#!/bin/bash
# Full kernel + the display-performance images (patches 0267 vsync after the frame / clock shift
# inside the copy, 0286 GPU DCVS UI floor), under the shared kernel lock out/kernel/.lock (held
# across the kernel and the image builds). Optional TREE: a patched tree (scripts/kernel/patched-tree.sh)
# whose bsd/dev/negroni_adreno.c is syntax-checked first.
#   scripts/bg.sh perf-kernel scripts/display/build-perf.sh [TREE]
# Images (config args + the args below + the args of the image the phone ran on 2026-10-26):
#   out/ios16-perf          clock shift 100 (config), notify late, clock shift inside the copy, UI floor 9
#   out/ios16-perf-noshift  the same without negronifb_clockshift (the A/B for the top-left strip)
# The vendor_boot and the ADT come from out/ios16 (unchanged by these patches).
set -euo pipefail
. "$(dirname "$0")/../lib/env.sh"
cd "$REPO"
ADD="negronifb_notifylate=1 negronifb_clockcopy=1 negronigpu_uifloor=9 negronibatt=5 negronipanic=30 negronipanicreason=2"
until mkdir "$OUT/kernel/.lock" 2>/dev/null; do echo "waiting for out/kernel/.lock"; sleep 30; done
trap 'rmdir "$OUT/kernel/.lock" 2>/dev/null || true' EXIT
if [ -n "${1:-}" ]; then
  while [ -d "$OUT/kernel/local.lock" ]; do echo "waiting for a running build-local"; sleep 30; done
  scripts/kernel/compile-one.sh "$1" bsd/dev/negroni_adreno.c
fi
scripts/kernel/build-local.sh
D=$OUT/kernel/$(dirname "$(readlink "$OUT/kernel/kernel.macho")")
for p in 0256 0259 0267 0286; do
  grep -q "^Applying $p-" "$D/patch-report.txt" || { echo "ERROR: patch $p is not applied ($D/patch-report.txt)" >&2; exit 1; }
done
grep -E "^Skipping" "$D/patch-report.txt" || true
for v in perf perf-noshift; do
  O=$OUT/ios16-$v
  mkdir -p "$O"
  cp "$OUT/ios16/negroni.adt" "$OUT/ios16/vendor_boot_a.img" "$O/"
  drop=""
  [ "$v" = perf-noshift ] && drop="negronifb_clockshift="
  IOS16_OUT=$O BOOTARGS_DROP="$drop" BOOTARGS_ADD="$ADD" scripts/ios16/build.sh payload
  IOS16_OUT=$O BOOTARGS_DROP="$drop" BOOTARGS_ADD="$ADD" scripts/ios16/build.sh boot
  echo "== $O"; cat "$O/cmdline.txt"; cat "$O/SHA256SUMS"
done
echo "== kernel $D"; cat "$D/SHA256SUMS" 2>/dev/null || shasum -a 256 "$D/kernel.development.negroni"
