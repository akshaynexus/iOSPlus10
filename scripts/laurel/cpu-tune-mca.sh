#!/bin/bash
# Which -mtune for the Mi A3 GPU user space (Kryo 260: Gold = Cortex-A73, Silver = Cortex-A53, both ARMv8.0)?
# Compiles userland/laurel/gpu/tune/mca-kernels.c with each candidate -mtune (always -mcpu=cortex-a53: the ISA floor)
# and runs llvm-mca on every kernel with the A53 and the A73 model. Prints cycles per 100 iterations of each block.
# Static model numbers [llvm-mca estimate], not a phone measurement.  Usage: scripts/laurel/cpu-tune-mca.sh [TUNE...]
set -euo pipefail
. "$(dirname "$0")/../lib/env.sh"
SRC=$REPO/userland/laurel/gpu/tune/mca-kernels.c
W=$OUT/laurel/gpu/tune
mkdir -p "$W"; rm -f "$W"/*.s
for t in clang llvm-mca; do command -v $t >/dev/null || { echo "cpu-tune-mca: missing $t" >&2; exit 1; }; done
TUNES=${*:-cortex-a53 cortex-a73 generic}
KERNELS=$(grep -oE '^[a-z0-9_ *]+\bk_[a-z0-9_]+\(' "$SRC" | grep -oE 'k_[a-z0-9_]+')
printf '%-14s %-12s' kernel tune; for m in cortex-a53 cortex-a73; do printf ' %14s' "$m"; done; printf ' %8s\n' insns
for k in $KERNELS; do
  for tune in $TUNES; do
    s=$W/$tune.s
    [ -f "$s" ] || clang -target arm64-apple-ios16.0 -mcpu=cortex-a53 -mtune="$tune" -O2 -ffreestanding -fno-asynchronous-unwind-tables -S -o "$s" "$SRC"
    # the function body: from its label to the ret
    body=$(awk -v f="_$k:" '$1==f{p=1;next} p&&/^\s*ret/{print;exit} p&&!/^\s*[.;]/{print}' "$s")
    printf '%-14s %-12s' "$k" "$tune"
    for m in cortex-a53 cortex-a73; do
      c=$(printf '%s\n' "$body" | llvm-mca -mtriple=arm64-apple-ios -mcpu=$m -iterations=100 2>/dev/null | awk '/^Total Cycles:/{print $3}')
      printf ' %14s' "$c"
    done
    printf ' %8s\n' "$(printf '%s\n' "$body" | grep -c .)"
  done
done
