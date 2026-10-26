#!/bin/bash
# Full kernel build for patches 0292-0296 (DSI command sets by memory DMA, DCS reads + ESD,
# tearcheck rate, TE interrupt, DPU power probe + no-transfer idle), under the shared kernel lock
# out/kernel/.lock. No boot image (owner rule 2026-10-26: the proof is the kernel build). Optional TREE: a patched tree
# (scripts/kernel/patched-tree.sh) whose changed files are syntax-checked first.
#   scripts/bg.sh dsi-kernel scripts/display/build-dsi.sh [TREE]
# Boot-args for a later image (config args +): negronifb_dsidma=1 negronifb_esd=1 negronifb_pwrprobe=1
#   (negronifb_pwrprobe=1 is read-only: the clock/GDSC state the UEFI left, README-gpu-kernel.md section 26).
# Fallback args on the phone: negronifb_dsidma=0 (0250/0268 per-packet path), negronifb_esd=0 (no reads).
# Default off, test one at a time: negronifb_teirq=1 (with negronifb_te=1), negronifb_idle=2, negronifb_vrr=2 (0294).
set -euo pipefail
. "$(dirname "$0")/../lib/env.sh"
cd "$REPO"
until mkdir "$OUT/kernel/.lock" 2>/dev/null; do echo "waiting for out/kernel/.lock"; sleep 30; done
trap 'rmdir "$OUT/kernel/.lock" 2>/dev/null || true' EXIT
if [ -n "${1:-}" ]; then
  while [ -d "$OUT/kernel/local.lock" ]; do echo "waiting for a running build-local"; sleep 30; done
  for f in bsd/dev/negroni_dsi.c bsd/dev/negroni_dpu.c iokit/Kernel/arm/NegroniBacklight.cpp \
      iokit/Kernel/arm/NegroniFramebuffer.cpp pexpert/arm/pe_fiq.c osfmk/arm64/sleh.c; do
    scripts/kernel/compile-one.sh "$1" "$f"
  done
fi
scripts/kernel/build-local.sh
D=$OUT/kernel/$(dirname "$(readlink "$OUT/kernel/kernel.macho")")
for p in 0259 0268 0292 0293 0294 0295 0296; do
  grep -q "^Applying $p-" "$D/patch-report.txt" || { echo "ERROR: patch $p is not applied ($D/patch-report.txt)" >&2; exit 1; }
done
grep -E "^Skipping" "$D/patch-report.txt" || true
echo "== kernel $D"; cat "$D/SHA256SUMS" 2>/dev/null || shasum -a 256 "$D/kernel.development.negroni"
