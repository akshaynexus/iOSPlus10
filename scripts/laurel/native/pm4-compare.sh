#!/bin/bash
# Stage 2 + 4 test of the native stack: the same scene (userland/laurel/metal-native/tests/scene.c), through the C ABI of the bridge, on the native stack over the fake kernel. Mesa's cffdump decodes the stream; scripts/laurel/native/pm4-diff.py compares the register state at the draw with Turnip's (scripts/laurel/native/ref-capture.sh, on the same scene, TU_DEBUG=sysmem).
#   scripts/bg.sh nmn-pm4 scripts/laurel/native/pm4-compare.sh
# No GPU runs. A pass says that the registers agree with a driver that is known to draw on this GPU; it does not say that the pixels are right.
set -uo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/metal-env.sh"
export METAL_OUT=$OUT/ios26/metal
. "$REPO/scripts/metal/env.sh"
N=$REPO/userland/laurel/metal-native
H=$OUT/ios26/native/host
B=$OUT/ios26/native/mesa-host
S=$OUT/ios26/turnip-host/mesa
FLAME=$MOUT/src/flame/phone/metal2/bridge
LIB=$OUT/ios26/metallib/Frameworks_QuartzCore.framework_default.metallib
W=$OUT/ios26/native/pm4
R=$OUT/ios26/native/ref
mkdir -p "$W"
C=$(find "$B" -type f -name cffdump | head -1)
export RNN_PATH=$S/src/freedreno/registers
M="$B/src/compiler/spirv/libvtn.a $B/src/compiler/nir/libnir.a $B/src/compiler/libcompiler.a $B/src/freedreno/ir3/libfreedreno_ir3.a $B/src/freedreno/isa/libir3decode.a $B/src/freedreno/isa/libir3encode.a $B/src/compiler/isaspec/libisaspec.a $B/src/freedreno/common/libfreedreno_common.a $B/src/freedreno/fdl/libfreedreno_layout.a $B/src/util/libmesa_util.a $B/src/util/blake3/libblake3.a $B/src/c11/impl/libmesa_util_c11.a $B/src/util/libmesa_util_sse41.a"
X=$S/src/freedreno/registers/adreno/a6xx.xml
clang -std=gnu11 -O1 -g -I"$N/winsys" -I"$N/tests" -I"$S/include" -I"$S/src/freedreno/common" -c "$N/tests/fake_platform.c" -o "$W/fake_platform.o"
clang -std=gnu11 -O1 -g -I"$N/winsys" -I"$N/tests" -I"$S/include" -I"$S/src/freedreno/common" -c "$N/tests/fake_kernel.c" -o "$W/fake_kernel.o"
clang -O1 -g -Wall -I "$FLAME" "$N/tests/scene.c" "$W/fake_platform.o" "$W/fake_kernel.o" "$H/libnative_metal_native.a" "$H/libnmn_c.a" -Wl,--start-group $M -Wl,--end-group $(pkg-config --libs SPIRV-Tools-shared 2>/dev/null || echo -lSPIRV-Tools-shared) -lm -ldl -lpthread -lstdc++ -lz -o "$W/scene-native"
run() {
  name=$1; shift
  NMN_RD=$W/$name.rd "$W/scene-native" none "$W/cache" "$LIB" "$@" > "$W/$name.log" 2>&1 || { echo "$name: exit $?"; tail -5 "$W/$name.log"; return 1; }
  grep -E '^(scene|FAIL|kernel)' "$W/$name.log" | cut -c1-200
  "$C" "$W/$name.rd" > "$W/$name.txt" 2>&1 || true
  "$C" --summary "$W/$name.rd" > "$W/$name-summary.txt" 2>&1 || true
  # the host decoder: what the CP would do with each word (a second opinion: no code in common with nw_check.c). A failure here is a hang on the phone.
  python3 -I "$REPO/scripts/laurel/native/stream-check.py" "$X" "$W/$name.rd" --strict | cut -c1-200
}
rc=0
run plain || rc=1
python3 -I "$REPO/scripts/laurel/native/pm4-diff.py" "$R/plain-sysmem-1-summary.txt" "$W/plain-summary.txt" | tee "$W/plain-diff.txt" || rc=1
python3 -I "$REPO/scripts/laurel/native/pm4-actions.py" "$R" "$W/plain-summary.txt" | tee "$W/plain-actions.txt" || rc=1
run row0 "$OUT/ios26/native/plans/ca-real.txt" 0 || rc=1
python3 -I "$REPO/scripts/laurel/native/pm4-diff.py" "$R/row0-sysmem-1-summary.txt" "$W/row0-summary.txt" | tee "$W/row0-diff.txt" || rc=1
# the rules must hold on the driver that is known to draw on this GPU: if Turnip fails a rule, the rule is wrong
for f in plain-sysmem-1 plain-sysmem-2 plain-sysmem-3 row0-sysmem-1; do
  python3 -I "$REPO/scripts/laurel/native/stream-check.py" "$X" "$R/$f.rd" | cut -c1-200 || rc=1
done
exit $rc
