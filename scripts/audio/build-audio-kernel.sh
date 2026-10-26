#!/bin/bash
# Full kernel + an audio test image for the audio stages (patches 0240-0248), under the shared kernel
# lock out/kernel/.lock (held across the kernel and the image build). Optional TREE: a patched tree
# whose audio files are syntax-checked first (scripts/kernel/compile-one.sh).
#   scripts/bg.sh audio-kernel scripts/audio/build-audio-kernel.sh [TREE]
#   Default: the kernel only (owner rule). IMAGE=1: also the test image below.
#   SKIP_KERNEL=1 ...: only the image, from the linked kernel (its patch report is still checked)
#   AUDIO_OUT=out/ios16-audio2 (default) and AUDIO_ARGS (the boot-args added to the cmdline):
#     default "negroniadsp=1 negroniadsp_step=15 negroniaudio_amp=1 negroniaudio_tone=1
#              negronipanic=30 negronipanicreason=2"
#   The image needs the ADSP firmware area with tfa-init.bin on the phone (docs/audio-plan.md 0244).
set -euo pipefail
. "$(dirname "$0")/../lib/env.sh"
cd "$REPO"
O=${AUDIO_OUT:-$OUT/ios16-audio2}
case "$O" in /*) ;; *) O=$REPO/$O ;; esac
ARGS=${AUDIO_ARGS:-negroniadsp=1 negroniadsp_step=15 negroniaudio_amp=1 negroniaudio_tone=1 negronipanic=30 negronipanicreason=2}
until mkdir "$OUT/kernel/.lock" 2>/dev/null; do echo "waiting for out/kernel/.lock"; sleep 30; done
trap 'rmdir "$OUT/kernel/.lock" 2>/dev/null || true' EXIT
if [ -n "${1:-}" ]; then
  while [ -d "$OUT/kernel/local.lock" ]; do echo "waiting for a running build-local"; sleep 30; done
  for f in negroni_adsp.c negroni_audio.c negroni_audio_guard.c negroni_tfa.c; do
    scripts/kernel/compile-one.sh "$1" "bsd/dev/$f"
  done
fi
[ "${SKIP_KERNEL:-0}" = 1 ] || scripts/kernel/build-local.sh      # SKIP_KERNEL=1: image only, from out/kernel/kernel.macho
D=$OUT/kernel/$(dirname "$(readlink "$OUT/kernel/kernel.macho")")
# the audio patches must apply; other agents' skipped patches are reported, not fatal
grep -E "^Skipping 024[0-8]-" "$D/patch-report.txt" && { echo "ERROR: an audio patch (0240-0248) did not apply" >&2; exit 1; }
grep -E "^Skipping 0[2-9]" "$D/patch-report.txt" | sed 's/^/WARNING (not audio): /' || true
for p in 0242 0243 0244 0245 0246 0247 0248; do
  grep -q "^Applying $p-" "$D/patch-report.txt" || { echo "ERROR: patch $p is not in $D/patch-report.txt" >&2; exit 1; }
done
grep -E "^Applying 024[2-8]-" "$D/patch-report.txt"
cat "$D/SHA256SUMS"
# Owner rule (2026-10-26): agents build the kernel only; the main session makes one combined image.
[ "${IMAGE:-0}" = 1 ] || { echo "kernel only (IMAGE=1 also builds $O)"; exit 0; }
mkdir -p "$O"
cp "$OUT/ios16/negroni.adt" "$OUT/ios16/vendor_boot_a.img" "$O/"
IOS16_OUT=$O BOOTARGS_ADD="$ARGS" scripts/ios16/build.sh payload
IOS16_OUT=$O BOOTARGS_ADD="$ARGS" scripts/ios16/build.sh boot
cat "$D/SHA256SUMS" "$O/SHA256SUMS"
cat "$O/cmdline.txt"
