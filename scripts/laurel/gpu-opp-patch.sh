#!/bin/bash
# Writes patches/laurel/xnu/2961-laurel-gpu-opp.patch from the work tree (out/laurel-kernel-ios26/src/xnu).
# Developer step, same idea as ios26-base-refresh.py: edit in src/xnu, run this, the normal build applies the patch. Exit 0: written.
set -euo pipefail
. "$(dirname "$0")/../lib/env.sh"
. "$REPO/scripts/laurel/ios26-env.sh"
P=$REPO/patches/laurel/xnu/2961-laurel-gpu-opp.patch
F="iokit/Kernel/arm/LaurelGpuDcvs.cpp iokit/Kernel/arm/TopazAdreno.cpp iokit/Kernel/arm/laurel_gpu_clock_read.h iokit/Kernel/arm/laurel_gpu_opp.h"
DESC='laurel 2961: GPU DCVS with all stock levels to 950 MHz. PLL1 320/465, GPLL0 300/600, PLL0 745/820/900/950 (new iokit/Kernel/arm/laurel_gpu_opp.h: table, governor, order of the votes, tested on the host by scripts/laurel/test-gpu-opp.sh). Raise: CX iPeak (from 900 MHz, stock), DDR at the stock bus level, CX at the stock corner, PLL lock, RCG, clock read. Lower: the reverse. A PLL is programmed only while it is stopped: the RCG waits on GPLL0. Self-check at each level; a failed level goes out of the table, a failed fallback gives off. Thermal: Android gpu-step 95 C, gpu-cx-mon 100 C. Kill switches gpudcvs=0, gpupll=0.'
{ echo "$DESC"; echo; } > "$W/2961.new"
git -C "$XNU_SRC" add -N iokit/Kernel/arm/laurel_gpu_opp.h
# a tree made with this patch has a commit for it: the base is its parent
BASE=$(git -C "$XNU_SRC" log --grep='2961-laurel-gpu-opp' --format=%H -1)
REV=HEAD; [ -z "$BASE" ] || REV=$BASE^
git -C "$XNU_SRC" diff --no-color "$REV" -- $F >> "$W/2961.new"
mv "$W/2961.new" "$P"
echo "gpu-opp-patch: $(grep -c '^diff ' "$P") files, $(wc -l < "$P") lines"
