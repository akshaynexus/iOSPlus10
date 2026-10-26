#!/bin/bash
# Full kernel + out/ios16-hap2 for the UI haptics (patches 0300-0303, docs/haptics-plan.md section 8),
# under the shared kernel lock out/kernel/.lock (held across the kernel and the image build).
# Optional TREE: a patched tree whose haptic files are syntax-checked first (compile-one.sh).
#   scripts/bg.sh hap2-kernel scripts/haptics/build-haptics-kernel.sh [TREE]
#   SKIP_KERNEL=1 ...: only out/ios16-hap2 from the linked kernel (its patch report is still checked)
# Boot-args added to the config ones: negronihap=1 negronihap_ui=1 negronipanic=30 negronipanicreason=2
# (HAP_BOOTARGS replaces them).
set -euo pipefail
. "$(dirname "$0")/../lib/env.sh"
cd "$REPO"
ARGS=${HAP_BOOTARGS:-negronihap=1 negronihap_ui=1 negronipanic=30 negronipanicreason=2}
until mkdir "$OUT/kernel/.lock" 2>/dev/null; do echo "waiting for out/kernel/.lock"; sleep 30; done
trap 'rmdir "$OUT/kernel/.lock" 2>/dev/null || true' EXIT
if [ -n "${1:-}" ]; then
  while [ -d "$OUT/kernel/local.lock" ]; do echo "waiting for a running build-local"; sleep 30; done
  for f in bsd/dev/negroni_haptic.c bsd/dev/negroni_haptic_ui.c iokit/Kernel/arm/NegroniVibrator.cpp; do
    scripts/kernel/compile-one.sh "$1" "$f"
  done
fi
[ "${SKIP_KERNEL:-0}" = 1 ] || scripts/kernel/build-local.sh
D=$OUT/kernel/$(dirname "$(readlink "$OUT/kernel/kernel.macho")")
# the haptic patches must apply; other agents' skipped patches are reported, not fatal
if grep -E "^Skipping 030[0-5]-" "$D/patch-report.txt"; then echo "ERROR: a haptic patch (0300-0305) did not apply" >&2; exit 1; fi
grep -E "^Skipping 0[2-9]" "$D/patch-report.txt" | sed 's/^/WARNING (not haptics): /' || true
for p in 0300 0301 0302 0303; do
  grep -q "^Applying $p-" "$D/patch-report.txt" || { echo "ERROR: patch $p is not in $D/patch-report.txt" >&2; exit 1; }
done
grep -E "^Applying 030[0-5]-" "$D/patch-report.txt"
K=$(cd "$OUT/kernel" && pwd -P)/$(readlink "$OUT/kernel/kernel.macho")
S=$(strings -a "$K"); echo "NEGRONI HAPTIC strings in the kernel: $(printf "%s\n" "$S" | grep -c "NEGRONI HAPTIC")"
S=$(strings -a "$K"); printf "%s\n" "$S" | grep -c "NEGRONI HAPTIC UI: /dev/%s ready" >/dev/null || { echo "ERROR: the 0302 strings are not in $K" >&2; exit 1; }
printf "%s\n" "$S" | grep -c "NEGRONI HAPTIC: closed-loop brake" >/dev/null || { echo "ERROR: the 0303 strings are not in $K" >&2; exit 1; }
O=$OUT/ios16-hap2
mkdir -p "$O"
cp "$OUT/ios16/negroni.adt" "$OUT/ios16/vendor_boot_a.img" "$O/"
IOS16_OUT=$O BOOTARGS_ADD="$ARGS" scripts/ios16/build.sh payload
IOS16_OUT=$O BOOTARGS_ADD="$ARGS" scripts/ios16/build.sh boot
cat "$D/SHA256SUMS" "$O/SHA256SUMS"
cat "$O/cmdline.txt"
