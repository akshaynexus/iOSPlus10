#!/bin/bash
# Full kernel + the image for patches 0287 (GPU hang recovery), 0288 (CPU idle states) and 0298 (KGSL
# parity from docs/audit/2026-10-26-gpu.md), under the
# shared kernel lock out/kernel/.lock (held across the kernel and the image build).
#   scripts/bg.sh gpur-kernel scripts/gpu/build-gpur.sh [TREE]
# Optional TREE: a patched tree (scripts/kernel/patched-tree.sh) whose changed files are syntax-checked
# first (the files 0287 and 0288 change).
# Image out/ios16-gpur: the config args + negronigpu_recover=1 negronicpuidle=1 negronipanic=30
# negronipanicreason=2. The kernel defaults stay negronigpu_recover=1, negronicpuidle=0.
# IMAGE=0: the kernel only (owner rule 2026-10-26 for follow-ups): scripts/bg.sh NAME env IMAGE=0 scripts/gpu/build-gpur.sh TREE
# The vendor_boot and the ADT come from out/ios16 (unchanged by these patches).
set -euo pipefail
. "$(dirname "$0")/../lib/env.sh"
cd "$REPO"
ADD="negronigpu_recover=1 negronicpuidle=1 negronipanic=30 negronipanicreason=2"
until mkdir "$OUT/kernel/.lock" 2>/dev/null; do echo "waiting for out/kernel/.lock"; sleep 30; done
trap 'rmdir "$OUT/kernel/.lock" 2>/dev/null || true' EXIT
if [ -n "${1:-}" ]; then
  while [ -d "$OUT/kernel/local.lock" ]; do echo "waiting for a running build-local"; sleep 30; done
  scripts/kernel/compile-one.sh "$1" bsd/dev/negroni_adreno.c
  scripts/kernel/compile-one.sh "$1" iokit/Kernel/arm/NegroniGPU.cpp
  scripts/kernel/compile-one.sh "$1" iokit/Kernel/arm/NegroniCPU.cpp
  for f in osfmk/arm64/negroni_cpuidle.c osfmk/arm64/cpu.c osfmk/arm64/sleh.c pexpert/arm/pe_fiq.c; do
    scripts/kernel/compile-one.sh "$1" "$f"
  done
fi
scripts/kernel/build-local.sh
D=$OUT/kernel/$(dirname "$(readlink "$OUT/kernel/kernel.macho")")
for p in 0285 0286 0287 0288 0298; do
  grep -q "^Applying $p-" "$D/patch-report.txt" || { echo "ERROR: patch $p is not applied ($D/patch-report.txt)" >&2; exit 1; }
done
grep -E "^Skipping" "$D/patch-report.txt" || true
if [ "${IMAGE:-1}" != 0 ]; then
  O=$OUT/ios16-gpur
  mkdir -p "$O"
  cp "$OUT/ios16/negroni.adt" "$OUT/ios16/vendor_boot_a.img" "$O/"
  IOS16_OUT=$O BOOTARGS_ADD="$ADD" scripts/ios16/build.sh payload
  IOS16_OUT=$O BOOTARGS_ADD="$ADD" scripts/ios16/build.sh boot
  echo "== $O"; cat "$O/cmdline.txt"; cat "$O/SHA256SUMS"
else
  echo "== no image (IMAGE=0)"
fi
echo "== kernel $D"; cat "$D/SHA256SUMS" 2>/dev/null || shasum -a 256 "$D/kernel.development.negroni"
