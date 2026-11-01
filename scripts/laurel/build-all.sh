#!/bin/sh
# Mi A3: build every stage that root.sh needs, in parallel, then the boot image. Logs: logs/stage-*.log.
#   scripts/bg.sh laurel-full sh -c 'scripts/laurel/build-all.sh && scripts/laurel/root-flash-test.sh'
# Exit 0 only when each wanted part is built and proven (root-manifest.py preflight; docs/laurel_sprout/build-honest.md). A part stays out only by its own
# switch: GPU=0 METAL=0 HEVC=0 AUDIO=0 BT=0 CAMERA=0 STATUSBAR=0 NOTCH=0 TORCH=0 BRIGHTNESS=0 XNUTILS=0 SSH=0. No half-built root after a 10 minute flash.
set -u
. "$(dirname "$0")/../lib/env.sh"
# main(): sh reads a function whole, so an edit of this file during the run cannot change what runs
main() {
cd "$(dirname "$0")/../.." || exit 1
mkdir -p logs out/laurel
L=scripts/laurel
M=$L/root-manifest.py
on() { eval "[ \"\${$1:-1}\" != 0 ]"; }
FD=${FD:-out/laurel/mu/SILICIUM_UEFI-DEBUG.fd}
[ -s "$FD" ] || { echo "build-all: FAILED: no $FD (scripts/laurel/mu-build.sh): the boot image needs it" >&2; exit 1; }
START=out/laurel/build-all.sources
sources_hash > "$START"
echo "build-all: commit $(git rev-parse --short=10 HEAD), sources $(wc -l < "$START") files, hash $(sha256_of "$START" | cut -c1-16)"
"$L/camera-inventory.sh" > logs/stage-inv.log 2>&1 || { echo "build-all: FAILED: camera-inventory (logs/stage-inv.log)" >&2; exit 1; }
# A clean machine has no toolchain: the kernel build fetches it, and the others need it
if [ ! -x out/laurel-kernel/theos/toolchain/linux/iphone/bin/ld ]; then
  "$L/kernel-linux.sh" > logs/stage-kernel.log 2>&1; k=$?
  [ "$k" = 0 ] || { echo "build-all: FAILED: kernel (logs/stage-kernel.log)" >&2; exit 1; }
  k=
else
  "$L/kernel-linux.sh" > logs/stage-kernel.log 2>&1 & k=$!
fi
g=; m=; n=; e=; c=; h=; a=; b=; f=; x=; s=
if on GPU; then
  { [ -s out/laurel/gpu/firmware/a610_zap.mdt ] || "$L/gpu-firmware.sh"; } > logs/stage-gpufw.log 2>&1 || { echo "build-all: FAILED: gpu-firmware (logs/stage-gpufw.log)" >&2; exit 1; }
  "$L/gpu-userland.sh" > logs/stage-gpu.log 2>&1 & g=$!
fi
if on METAL; then "$L/metal-build.sh" > logs/stage-metal.log 2>&1 & m=$!; fi
if on STATUSBAR && on NOTCH; then "$L/notch-build.sh" > logs/stage-notch.log 2>&1 & n=$!; fi
if on STATUSBAR && on NOTCH && on CELL; then "$L/cell-build.sh" > logs/stage-cell.log 2>&1 & e=$!; fi
if on CAMERA; then sh userland/laurel/camera/build.sh > logs/stage-cam.log 2>&1 & c=$!; fi
if on HEVC; then "$L/hevc-build.sh" > logs/stage-hevc.log 2>&1 & h=$!; fi
if on AUDIO; then userland/laurel/audio/build.sh > logs/stage-audio.log 2>&1 & a=$!; fi
if on BT; then userland/laurel/bt/build.sh > logs/stage-bt.log 2>&1 & b=$!; fi
# the camera plug-in owns the flashlight; its own plug-in only without the camera
if on TORCH && ! on CAMERA; then userland/laurel/flashlight/build.sh > logs/stage-torch.log 2>&1 & f=$!; fi
if on XNUTILS; then "$L/xnutils-build.sh" > logs/stage-xnutils.log 2>&1 & x=$!; fi
if on SSH; then
  { userland/ssh/fetch.sh && { [ "$(uname -s)" != Linux ] || userland/ssh/fetch-sdk.sh; } && userland/ssh/build.sh; } > logs/stage-ssh.log 2>&1 & s=$!
fi
bad=
for j in kernel:$k gpu:$g metal:$m notch:$n cell:$e camera:$c hevc:$h audio:$a bt:$b flashlight:$f xnutils:$x ssh:$s; do
  [ -n "${j#*:}" ] || continue
  wait "${j#*:}" || bad="$bad ${j%%:*}"
done
[ -z "$bad" ] || { echo "build-all: FAILED:$bad (logs/stage-*.log)" >&2; exit 1; }
"$L/uefi-image.sh" > logs/stage-image.log 2>&1 || { echo "build-all: FAILED: uefi-image (logs/stage-image.log)" >&2; tail -3 logs/stage-image.log >&2; exit 1; }
# everything root.sh will ask for exists and is fresh; the same check runs again at its start
python3 -I "$M" preflight > logs/stage-preflight.log 2>&1 || { grep FAILED logs/stage-preflight.log >&2; echo "build-all: FAILED: stages not complete (logs/stage-preflight.log)" >&2; exit 1; }
# a source edited during the build: some stage may have the old one (the race of 2026-11-01)
if ! sources_hash | cmp -s - "$START"; then
  sources_hash | diff "$START" - | sed -n 's/^[<>] [0-9a-f]* */build-all: FAILED: changed during this run: /p' | sort -u >&2
  exit 1
fi
python3 -I "$L/build-stamp.py" kernel-check "out/laurel-kernel/out/kernel.development.sweet.${PAGES:-4k}" || exit 1
echo "build-all: done"
}
# every file that goes into a stage: name + hash, one per line (sorted)
sources_hash() {
  git ls-files -z --cached --others --exclude-standard -- patches/laurel scripts/laurel userland | sort -z | xargs -0 sha256sum 2>/dev/null | sed 's/  / /'
}
sha256_of() { sha256sum "$1" | cut -d' ' -f1; }
main "$@"
exit 0
