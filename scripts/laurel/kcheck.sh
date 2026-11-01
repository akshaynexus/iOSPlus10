#!/bin/bash
# Syntax-check one kernel source file of the patched laurel xnu tree in a few seconds,
# with the exact compiler line the kernel build uses for a file of the same layer.
#   scripts/laurel/kcheck.sh bsd/dev/laurel_bt_uart.c        (path in out/laurel-kernel/xnu-src/xnu-*)
#   scripts/laurel/kcheck.sh iokit/Kernel/arm/LaurelBluetooth.cpp
# The first call per layer (bsd or iokit) records the line: it touches a reference file
# (bsd/dev/laurel_haptic.c, iokit/Kernel/arm/LaurelVibrator.cpp) and runs one verbose
# incremental kernel build (needs a finished scripts/laurel/kernel-linux.sh build; run in tmux:
# scripts/bg.sh kcheck scripts/laurel/kcheck.sh --record). Lines: out/laurel-kernel/cc-*.line.
set -euo pipefail
. "$(dirname "$0")/../lib/env.sh"
W=$OUT/laurel-kernel
X=$W/xnu-src/xnu-8796.141.3
[ -d "$X" ] || { echo "kcheck: no patched tree $X (scripts/laurel/kernel-linux.sh first)" >&2; exit 1; }

record() {
	touch "$X/bsd/dev/laurel_haptic.c" "$X/iokit/Kernel/arm/LaurelVibrator.cpp"
	export TOP=$W THEOS=$W/theos MACHINE_CONFIG=SWEET KERNEL_CONFIG=DEVELOPMENT JOBS=$NPROC TOPAZ_4K=1
	(cd "$W" && PATH=$W/linux/bin:$PATH bash linux/build.sh VERBOSE=YES) > "$W/logs/kcheck-record.log" 2>&1 || true
	# the compile commands start with xnu-clang and end with the source path
	grep -E '^xnu-clang .*/bsd/dev/laurel_haptic\.c *$' "$W/logs/kcheck-record.log" | tail -1 > "$W/cc-bsd.line" || true
	grep -E '^xnu-clang\+\+ .*/iokit/Kernel/arm/LaurelVibrator\.cpp *$' "$W/logs/kcheck-record.log" | tail -1 > "$W/cc-iokit.line" || true
	for l in bsd iokit; do
		[ -s "$W/cc-$l.line" ] || { echo "kcheck: no $l compile line in logs/kcheck-record.log" >&2; exit 1; }
	done
	echo "kcheck: recorded $W/cc-bsd.line $W/cc-iokit.line"
}

[ "${1:-}" = --record ] && { record; exit 0; }
f=${1:?usage: kcheck.sh <path in the xnu tree> | --record}
case "$f" in
iokit/*) layer=iokit ref='[^ ]*/iokit/Kernel/arm/LaurelVibrator\.cpp' ;;
*)       layer=bsd ref='[^ ]*/bsd/dev/laurel_haptic\.c' ;;
esac
L=$W/cc-$layer.line
[ -s "$L" ] || { echo "kcheck: no $L (scripts/bg.sh kcheck scripts/laurel/kcheck.sh --record)" >&2; exit 1; }
# the recorded line runs in the object directory: drop its -o/-MD outputs, check syntax only
cmd=$(sed -E "s# $ref *\$# $X/$f#; s# -o [^ ]+##; s# -MD##g; s# -M[FT] [^ ]+##g" "$L")
dir=$X/BUILD/obj/DEVELOPMENT_ARM64_SWEET/$layer/DEVELOPMENT
cd "$dir"
PATH=$W/linux/bin:$PATH eval "$cmd -fsyntax-only"
echo "kcheck: $f: syntax OK"
