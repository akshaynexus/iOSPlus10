#!/bin/bash
# Host test of the EL0 LSE emulation of the iOS 16 kernel (topaz 0081 + laurel 2960). Nothing runs on the phone. Style of scripts/laurel/test-a64emu.sh, same harness.
#   AUDIT=1 scripts/laurel/kernel-linux.sh     first, or any build: the test reads the text of the patched tree, out/laurel-kernel/xnu-src/, not a copy
#   scripts/bg.sh lse0081-test scripts/laurel/test-lse0081.sh
#   scripts/bg.sh lse0081-test env CASES=200000 scripts/laurel/test-lse0081.sh     fewer cases
# Truth: the real word on qemu cortex-a76 (LSE and RCpc, no LSE2, so an unaligned atomic faults, as on the A11 of this userland). The emulator: the same case stream on
# qemu cortex-a53: the word traps (SIGILL), and sweet_emulate_lse() + _sweet_lse_* run it on the saved registers. Faults go through the kernel's table layout, with a table
# miss as a panic. Compared per case: x0-x30, SP, NZCV, V0-V31, FPSR, memory, outcome (ok, undefined, SIGSEGV, SIGBUS).
# Two builds: "after" must have 0 mismatches. "before" (2960 taken back) must show the old bugs, or the test does not see them and it fails.
set -euo pipefail
. "$(dirname "$0")/../lib/env.sh"
A=$REPO/tools/laurel-a64emu
L=$REPO/tools/laurel-lse0081
O=$OUT/lse0081-test
TREE=${XNU_TREE:-$OUT/laurel-kernel/xnu-src/xnu-8796.141.3}
FIX=$REPO/patches/laurel/xnu/2960-laurel-lse-emulation.patch
TRUTH=(qemu-aarch64 -cpu cortex-a76)
EMU=(qemu-aarch64 -cpu cortex-a53)
CASES=${CASES:-2000000}
BEFORE_CASES=${BEFORE_CASES:-200000}
SEED=${SEED:-1}
[ -f "$TREE/osfmk/arm64/sleh.c" ] || { echo "test-lse0081: no patched tree $TREE: AUDIT=1 scripts/laurel/kernel-linux.sh" >&2; exit 1; }
rm -rf "$O"; mkdir -p "$O/after" "$O/before"
python3 -I "$L/extract.py" "$TREE" "$O/after"
python3 -I "$L/extract.py" "$TREE" "$O/before" --before "$FIX"
grep -q 'cmp	\\r\\()10, \\r\\()2$' "$O/after/asm_frag.inc"
build() { # VARIANT FLAGS...
  local v=$1 d=$O/$1; shift
  local CC=(clang --target=aarch64-linux-gnu -mcpu=cortex-a53 -O2 -g -ffreestanding -fno-stack-protector -fno-builtin -Wall -Wno-unused-function -DSWEET=1 -DLSE0081=1 "$@" -I "$d" -I "$L" -I "$A")
  "${CC[@]}" -x assembler-with-cpp -c "$A/test/harness_asm.S" -o "$d/harness_asm.o"
  "${CC[@]}" -x assembler-with-cpp -c "$L/lse0081_asm.S" -o "$d/lse0081_asm.o"
  "${CC[@]}" -mgeneral-regs-only -c "$L/lse0081_shim.c" -o "$d/shim.o"
  "${CC[@]}" -mgeneral-regs-only -c "$A/test/harness.c" -o "$d/harness.o"
  ld.lld -static -z max-page-size=4096 --no-rosegment -z noexecstack "$d/harness.o" "$d/shim.o" "$d/lse0081_asm.o" "$d/harness_asm.o" -o "$d/harness"
}
build after & p1=$!
build before -DLSE0081_BEFORE=1 & p2=$!
wait $p1; wait $p2
pieces=$(( NPROC / 2 > 1 ? NPROC / 2 : 1 ))
run_stream() { # VARIANT TOTAL: mismatches on stdout, last line "total CASES BAD PANICS"
  local v=$1 d=$O/$1 n=$2 each=$(( $2 / pieces + 1 )) total=0 bad=0 pan=0 pids=() c ca
  for p in $(seq 1 "$pieces"); do
    ( s=$((SEED * 1000 + p))
      "${TRUTH[@]}" "$d/harness" native lse "$each" "$s" "$d/lse.$p.native" > "$d/lse.$p.native.log" 2>&1 &
      a=$!
      "${EMU[@]}" "$d/harness" emu lse "$each" "$s" "$d/lse.$p.emu" > "$d/lse.$p.emu.log" 2>&1 &
      b=$!
      wait $a || { echo "piece $p: native run failed: $(tail -1 "$d/lse.$p.native.log")"; exit 1; }
      wait $b || { echo "piece $p: emu run failed: $(tail -1 "$d/lse.$p.emu.log")"; exit 1; }
    ) & pids+=($!)
  done
  local rc=0
  for pid in "${pids[@]}"; do wait "$pid" || rc=1; done
  [ "$rc" = 0 ] || return 1
  for p in $(seq 1 "$pieces"); do
    out=$(python3 -I "$A/test/compare.py" "$v.$p" "$d/lse.$p.native" "$d/lse.$p.emu" || true)
    echo "$out"
    c=$(sed -n 's/.*cases \([0-9]*\), mismatches \([0-9]*\).*/\1 \2/p' <<<"$out" | head -1)
    total=$((total + ${c% *})); bad=$((bad + ${c#* }))
    pan=$((pan + $(sed -n 's/.* panics \([0-9]*\).*/\1/p' "$d/lse.$p.emu.log" | head -1)))
    tail -1 "$d/lse.$p.emu.log"
  done
  python3 -I "$L/coverage.py" "$d"/lse.*.native || rc=1
  rm -f "$d"/lse.*.native "$d"/lse.*.emu
  echo "$v: cases $total, mismatches $bad, table misses (panics in the kernel) $pan"
  eval "${v}_total=$total ${v}_bad=$bad ${v}_pan=$pan"
  return "$rc"
}
rc=0
echo "== after: the kernel's text (0081 + 2960)"
"${EMU[@]}" "$O/after/harness" rules || rc=1
"${EMU[@]}" "$O/after/harness" threads "${THREAD_ITER:-200000}" || rc=1
run_stream after "$CASES" || rc=1
[ "${after_bad:-1}" = 0 ] && [ "${after_pan:-1}" = 0 ] || rc=1
echo "== before: 0081 alone (2960 taken back). The test must see the old bugs"
set +e
"${EMU[@]}" "$O/before/harness" rules > "$O/before/rules.log" 2>&1
rb=$?
set -e
sort "$O/before/rules.log" | uniq -c | sort -rn | head -40
run_stream before "$BEFORE_CASES" > "$O/before/stream.log" 2>&1 || true
tail -1 "$O/before/stream.log"
b_bad=$(sed -n 's/.*mismatches \([0-9]*\), table.*/\1/p' "$O/before/stream.log")
b_pan=$(sed -n 's/.*(panics in the kernel) \([0-9]*\).*/\1/p' "$O/before/stream.log")
if [ "$rb" = 0 ] || [ "${b_bad:-0}" = 0 ] || [ "${b_pan:-0}" = 0 ]; then echo "test-lse0081: the test does not see the old bugs"; rc=1; fi
[ "$rc" = 0 ] && echo "test-lse0081: PASS" || echo "test-lse0081: FAILED"
exit "$rc"
