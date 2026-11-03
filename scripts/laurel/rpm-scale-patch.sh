#!/bin/bash
# Writes patches/laurel/xnu/2985-laurel-rpm-scale.patch from the work tree (out/laurel-kernel-ios26/src/xnu). Developer step: edit in src/xnu, run this, the normal build applies the patch. Exit 0: written.
set -euo pipefail
. "$(dirname "$0")/../lib/env.sh"
. "$REPO/scripts/laurel/ios26-env.sh"
P=$REPO/patches/laurel/xnu/2985-laurel-rpm-scale.patch
F="bsd/dev/laurel_reboot.c iokit/Kernel/arm/LaurelGpuDcvs.cpp iokit/Kernel/arm/laurel_gpu_clock_read.h iokit/Kernel/arm/laurel_rpm_scale.h"
DESC='laurel 2985: the RPM follows bus votes: the stock enable of its clock scaling (rpm_smd_clk_probe): BIMC INT_MAX, each rate clock of trinket_clks at the top vote in both sets, then clk0 2 Enab = 1, sleep set first. New iokit/Kernel/arm/laurel_rpm_scale.h, tested on the host by scripts/laurel/test-rpm-scale.sh. DDR then follows the GPU level and the stock Gold table, never below the boot clock. Self-check: the MCCC read rises; GCC reads of snoc, pnoc and bimc in one line. An IMEM word marks the first 30 s after the enable: a boot that finds it does not try. Kill switches rpmscale=0, gpupll=0, gpudcvs=0. Both kernels. docs/laurel_sprout/gpu.md "RPM scaling".'
{ echo "$DESC"; echo; } > "$W/2985.new"
git -C "$XNU_SRC" add -N iokit/Kernel/arm/laurel_rpm_scale.h
BASE=$(git -C "$XNU_SRC" log --grep='2985-laurel-rpm-scale' --format=%H -1)
REV=HEAD; [ -z "$BASE" ] || REV=$BASE^
git -C "$XNU_SRC" diff --no-color "$REV" -- $F >> "$W/2985.new"
[ "$(grep -c '^diff --git' "$W/2985.new")" = 4 ] || { echo "rpm-scale-patch: not 4 files" >&2; exit 1; }
mv "$W/2985.new" "$P"
echo "rpm-scale-patch: $(grep -c '^diff ' "$P") files, $(wc -l < "$P") lines"
