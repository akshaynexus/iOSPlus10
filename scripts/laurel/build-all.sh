#!/bin/sh
# Mi A3: build every stage of the next test in parallel, then the boot image. Logs: logs/stage-*.log.
#   scripts/bg.sh laurel-full sh -c 'scripts/laurel/build-all.sh && scripts/laurel/root-flash-test.sh'
set -u
. "$(dirname "$0")/../lib/env.sh"
cd "$(dirname "$0")/../.."
scripts/laurel/camera-inventory.sh > logs/stage-inv.log 2>&1 || { echo "build-all: camera-inventory failed" >&2; exit 1; }
scripts/laurel/kernel-linux.sh > logs/stage-kernel.log 2>&1 & k=$!
scripts/laurel/gpu-userland.sh > logs/stage-gpu.log 2>&1 & g=$!
scripts/laurel/metal-build.sh > logs/stage-metal.log 2>&1 & m=$!
scripts/laurel/notch-build.sh > logs/stage-notch.log 2>&1 & n=$!
sh userland/laurel/camera/build.sh > logs/stage-cam.log 2>&1 & c=$!
r=0
wait $k || r=kernel
wait $g || r=gpu
wait $m || r=metal
wait $n || r=notch
wait $c || r=camera
[ "$r" = 0 ] || { echo "build-all: $r failed (logs/stage-*.log)" >&2; exit 1; }
scripts/laurel/uefi-image.sh > logs/stage-image.log 2>&1 || { echo "build-all: uefi-image failed" >&2; exit 1; }
echo "build-all: done"
