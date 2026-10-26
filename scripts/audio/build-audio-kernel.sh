#!/bin/bash
# Full kernel + out/ios16-audio for the audio stages (patches 0240-0243), under the shared kernel
# lock out/kernel/.lock (held across the kernel and the image build). Optional TREE: a patched tree
# whose bsd/dev/negroni_{adsp,audio}.c are syntax-checked first (scripts/kernel/compile-one.sh).
#   scripts/bg.sh audio-kernel scripts/audio/build-audio-kernel.sh [TREE]
#   SKIP_KERNEL=1 ...: only out/ios16-audio from the linked kernel (its patch report is still checked)
set -euo pipefail
. "$(dirname "$0")/../lib/env.sh"
cd "$REPO"
until mkdir "$OUT/kernel/.lock" 2>/dev/null; do echo "waiting for out/kernel/.lock"; sleep 30; done
trap 'rmdir "$OUT/kernel/.lock" 2>/dev/null || true' EXIT
if [ -n "${1:-}" ]; then
  while [ -d "$OUT/kernel/local.lock" ]; do echo "waiting for a running build-local"; sleep 30; done
  scripts/kernel/compile-one.sh "$1" bsd/dev/negroni_adsp.c
  scripts/kernel/compile-one.sh "$1" bsd/dev/negroni_audio.c
fi
[ "${SKIP_KERNEL:-0}" = 1 ] || scripts/kernel/build-local.sh      # SKIP_KERNEL=1: image only, from out/kernel/kernel.macho
D=$OUT/kernel/$(dirname "$(readlink "$OUT/kernel/kernel.macho")")
# the audio patches must apply; other agents' skipped patches are reported, not fatal
grep -E "^Skipping 024[0-3]-" "$D/patch-report.txt" && { echo "ERROR: an audio patch (0240-0243) did not apply" >&2; exit 1; }
grep -E "^Skipping 0[2-9]" "$D/patch-report.txt" | sed 's/^/WARNING (not audio): /' || true
for p in 0242 0243; do
  grep -q "^Applying $p-" "$D/patch-report.txt" || { echo "ERROR: patch $p is not in $D/patch-report.txt" >&2; exit 1; }
done
grep -E "^Applying 024[23]-" "$D/patch-report.txt"
O=$OUT/ios16-audio
mkdir -p "$O"
cp "$OUT/ios16/negroni.adt" "$OUT/ios16/vendor_boot_a.img" "$O/"
IOS16_OUT=$O BOOTARGS_ADD="negroniadsp=1 negroniadsp_step=15 negronipanic=30 negronipanicreason=2" scripts/ios16/build.sh payload
IOS16_OUT=$O BOOTARGS_ADD="negroniadsp=1 negroniadsp_step=15 negronipanic=30 negronipanicreason=2" scripts/ios16/build.sh boot
cat "$D/SHA256SUMS" "$O/SHA256SUMS"
cat "$O/cmdline.txt"
