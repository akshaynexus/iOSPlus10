#!/bin/bash
# Host test of the EL0 emulator of the iOS 26 kernel (tools/laurel-a64emu, the same files as osfmk/arm64/). Nothing runs on the phone.
#   scripts/bg.sh a64emu-test scripts/laurel/test-a64emu.sh          (long: in tmux)
#   CASES=200000 scripts/laurel/test-a64emu.sh fp16 lse              some classes, fewer cases
#   scripts/laurel/test-a64emu.sh build                              build only; out/a64emu-test/harness
# Truth: one static AArch64 program, no libc, runs the same random and edge-case stream twice. `-cpu max`: the real word (qemu's implementation of
# the architecture). `-cpu cortex-a53`: the word traps (SIGILL), and the kernel's C and asm run it on the saved registers, as sleh.c does. Both runs
# hash x0-x30, SP, NZCV, V0-V31, FPSR, the memory window and the outcome (ok, undefined, SIGSEGV, SIGBUS). So this also proves that the emulator
# itself uses nothing above ARMv8.0. PAC: on -cpu max a real sign before the word, a real check in it; here plain pointers: same effect.
# "rules": fault paths, read-only and lazy pages, kernel addresses, tags, single step, kill bits. "threads": real threads, emulated words against user LL/SC.
set -euo pipefail
. "$(dirname "$0")/../lib/env.sh"
T=$REPO/tools/laurel-a64emu
O=$OUT/a64emu-test
mkdir -p "$O"
H=$O/harness
CC=(clang --target=aarch64-linux-gnu -mcpu=cortex-a53 -O2 -g -ffreestanding -fno-stack-protector -fno-builtin -Wall -Wno-unused-function -I "$T")
"${CC[@]}" -x assembler-with-cpp -c "$T/test/harness_asm.S" -o "$O/harness_asm.o"
# the same FP rule as the kernel: the emulator itself uses no FP or NEON register
"${CC[@]}" -mgeneral-regs-only -c "$T/laurel_a64emu.c" -o "$O/laurel_a64emu.o"
"${CC[@]}" -mgeneral-regs-only -c "$T/test/harness.c" -o "$O/harness.o"
ld.lld -static -z max-page-size=4096 --no-rosegment -z noexecstack "$O/harness.o" "$O/laurel_a64emu.o" "$O/harness_asm.o" -o "$H"
[ "${1:-}" = build ] && { ls -l "$H"; exit 0; }
# not -cpu max: it also has words newer than an A13 (FPRCVT, FAMINMAX, FP8), which share these opcode spaces. neoverse-v1 is ARMv8.4 with all our classes
QMAX=(qemu-aarch64 -cpu neoverse-v1)
QA53=(qemu-aarch64 -cpu cortex-a53)
ALL="pac lse casp rcpc fp16 fcma dotprod jscvt fhm sha3 rdm sysreg"
CLASSES=${*:-$ALL}
SEED=${SEED:-1}
cases_for() {
  [ -n "${CASES:-}" ] && { echo "$CASES"; return; }
  case "$1" in fp16) echo 6000000 ;; lse|fcma|fhm) echo 2000000 ;; casp|rcpc|jscvt|pac|rdm) echo 1000000 ;; dotprod|sha3) echo 500000 ;; *) echo 200000 ;; esac
}
"${QA53[@]}" "$H" rules
"${QA53[@]}" "$H" threads "${THREAD_ITER:-200000}"
rc=0
# SB and DIT: neoverse-v1 has no SB; -cpu max has both, and these words have no newer neighbours in this stream
native_cpu() { case "$1" in sysreg) echo max ;; *) echo neoverse-v1 ;; esac; }
# each class in pieces (each piece its own seed), all at the same time
run_piece() { # CLASS PIECE N
  local c=$1 p=$2 n=$3 s=$((SEED * 1000 + p))
  qemu-aarch64 -cpu "$(native_cpu "$c")" "$H" native "$c" "$n" "$s" "$O/$c.$p.native" > "$O/$c.$p.native.log" 2>&1 &
  local a=$!
  "${QA53[@]}" "$H" emu "$c" "$n" "$s" "$O/$c.$p.emu" > "$O/$c.$p.emu.log" 2>&1 &
  local b=$!
  wait $a || { echo "$c.$p native run: exit $?"; tail -2 "$O/$c.$p.native.log"; return 1; }
  wait $b || { echo "$c.$p emu run: exit $?"; tail -2 "$O/$c.$p.emu.log"; return 1; }
}
total=0; totalbad=0
for c in $CLASSES; do
  n=$(cases_for "$c")
  pieces=$(( NPROC / 2 > 1 ? NPROC / 2 : 1 ))
  each=$(( n / pieces + 1 ))
  pids=()
  for p in $(seq 1 "$pieces"); do run_piece "$c" "$p" "$each" & pids+=($!); done
  for pid in "${pids[@]}"; do wait "$pid" || { echo "$c: a run failed"; rc=1; }; done
  for p in $(seq 1 "$pieces"); do
    if out=$(python3 -I "$T/test/compare.py" "$c.$p" "$O/$c.$p.native" "$O/$c.$p.emu"); then echo "$out"; else echo "$out"; rc=1; echo "  dump: qemu-aarch64 -cpu neoverse-v1 $H dump native $c CASE $((SEED * 1000 + p)); qemu-aarch64 -cpu cortex-a53 $H dump emu $c CASE $((SEED * 1000 + p))"; fi
    rm -f "$O/$c.$p.native" "$O/$c.$p.emu"
  done
done
if [ -z "${*:-}" ] || [ "${EXH:-1}" = 1 ]; then
  # exhaustive: all 65,536 half values through each one-input word, 4 rounding modes x FZ16 off and on
  "${QMAX[@]}" "$H" exh native "$O/x.native" > "$O/x.native.log" 2>&1 &
  a=$!
  "${QA53[@]}" "$H" exh emu "$O/x.emu" > "$O/x.emu.log" 2>&1 &
  b=$!
  wait $a; wait $b
  python3 -I "$T/test/compare.py" fp16-exhaustive "$O/x.native" "$O/x.emu" || rc=1
  rm -f "$O/x.native" "$O/x.emu"
fi
[ "$rc" = 0 ] && echo "test-a64emu: PASS" || echo "test-a64emu: FAILED"
exit "$rc"
