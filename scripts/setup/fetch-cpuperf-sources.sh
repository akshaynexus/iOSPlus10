#!/bin/sh
# Reference sources for patch 0395 (NEGRONI CPUPERF: placement + WALT/schedutil-like governor + input boost).
# Extends the sparse checkouts made by scripts/setup/fetch-oneplus-sources.sh. Small text files only.
# Pins: out/src/op-kernel = OnePlusOSS android_kernel_oneplus_sm8450 @ e9da5922 (msm-kernel 5.10, WALT),
#       out/src/op-modules = OnePlusOSS android_kernel_modules_and_devicetree_oneplus_sm8450 @ 835109f6 (OPLUS sched).
# GPL-2.0 code. The port lives in patches/xnu/0395-negroni-cpuperf.patch (SPDX + copyright kept there).
#   scripts/bg.sh fetch-cpuperf scripts/setup/fetch-cpuperf-sources.sh
set -eu
. "$(dirname "$0")/../lib/env.sh"
K=$OUT/src/op-kernel
M=$OUT/src/op-modules
[ -d "$K/.git" ] && [ -d "$M/.git" ] || { echo "no $K or $M: run scripts/setup/fetch-oneplus-sources.sh first" >&2; exit 1; }
for p in "$K e9da5922d6d1925fa7cc3062b65d92fa2812c3aa" "$M 835109f6cf48dbae09b68ef072bfecbf48e15064"; do
  set -- $p
  h=$(git -C "$1" rev-parse HEAD)
  [ "$h" = "$2" ] || { echo "$1 is at $h, pinned $2" >&2; exit 1; }
done
git -C "$K" sparse-checkout add 'kernel/sched/walt/*' 'kernel/sched/cpufreq_schedutil.c' 'kernel/sched/sched.h' \
  'include/linux/sched/walt.h' 'include/trace/hooks/sched.h'
git -C "$K" checkout -q HEAD
git -C "$M" sparse-checkout add 'vendor/oplus/kernel/cpu/sched/frame_boost/**' \
  'vendor/oplus/kernel/cpu/sched/sched_assist/sa_common.*' 'vendor/oplus/kernel/cpu/sched/sched_assist/sa_fair.c'
git -C "$M" checkout -q HEAD
ls "$K/kernel/sched/walt" "$K/kernel/sched/cpufreq_schedutil.c" "$M/vendor/oplus/kernel/cpu/sched/frame_boost"
