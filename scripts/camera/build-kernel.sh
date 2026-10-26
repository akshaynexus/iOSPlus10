#!/bin/sh
# Full kernel build (all patches/xnu) for the camera patches 0310-0318 (+ 0249), under the shared kernel lock
# out/kernel/.lock. No boot image (owner rule 2026-10-26: the main session builds one combined image;
# the camera boot-args are in patches/xnu/README-camera.md "Boot-args").
#   scripts/bg.sh cam3-build scripts/camera/build-kernel.sh
# Output: out/kernel/local-<time>/kernel.development.negroni + patch-report.txt (link out/kernel/kernel.macho).
set -eu
. "$(dirname "$0")/../lib/env.sh"
L=$OUT/kernel/.lock
until mkdir "$L" 2>/dev/null; do sleep 30; done
trap 'rmdir "$L" 2>/dev/null || true' EXIT
scripts/kernel/build-local.sh
D=$(ls -dt "$OUT"/kernel/local-2* | head -1)
echo "camera patches:"; grep -E '0249|031[0-8]' "$D/patch-report.txt" || true
shasum -a 256 "$D"/kernel.*
