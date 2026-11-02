#!/bin/sh
# Lower the iOS 26 donor userland for the Mi A3 CPU (ARMv8.0, no PAC, no LSE), check it on the host, and count what is left.
#   scripts/bg.sh ios26-lower env DEV=n104ap scripts/ios26/lower-userland.sh
# Needs: scripts/ios26/fetch-os.sh + sysos-tree.sh output, out/bin/op10tool, llvm-mc, qemu-aarch64.
# Output (never in git): $APPLE/ios26/$BUILD-$DEV/lowered/ (link out/ios26/lowered-$DEV), logs in the job log.
# Steps: a64-lower (cache + root Mach-O, 4 KiB signatures), a64-selftest on the real LSE words, a64-verify, a64-census of
# the result, then a second a64-lower of the cache to prove the output is the same bytes. Host results only.
# a64-verify replays the checks of dyld and the kernel on each cache file (also alone: op10tool a64-preflight --cache FILE).
# DEAD images: their __text becomes trampoline space for WebCore and WebKit (subcaches .09 and .11 have too little slack).
# dyld maps a dead image when a daemon's dependents reach it, so it must have no load-time code; a64-lower refuses one that has.
set -eu
. "$(dirname "$0")/../lib/env.sh"
. "$(dirname "$0")/donor.sh"
T=$APPLE/ios26/$BUILD-$DEV/tree
L=${LOWERED:-$APPLE/ios26/$BUILD-$DEV/lowered}  # LOWERED=DIR: a scratch output; the shared folder and its link stay
C=$T/cache/dyld_shared_cache_arm64e
# Code in it never runs on this phone [I]: the Image Playground frameworks need an A17 Pro or newer. 2.7 MiB of __text, all 47,899 sites in reach.
# Not ANECompiler: most daemons load it through Espresso and it has 2 initializers (docs/laurel_sprout/ios26-entry.md).
DEAD=${DEAD:-VisualGeneration.framework/VisualGeneration}
dead_args=; for d in $DEAD; do dead_args="$dead_args --dead-image $d"; done
TOOL=$OUT/bin/op10tool
rm -rf "$L" "$L.again" "$OUT/ios26/census-$DEV-lowered"
"$TOOL" a64-lower --cache "$C" --macho "$T/root" --out "$L" --page-shift 12 $dead_args
mkdir -p "$OUT/ios26"
[ -n "${LOWERED:-}" ] || ln -sfn "$L" "$OUT/ios26/lowered-$DEV"
"$TOOL" a64-selftest --words "$L/lse-words.txt" --out "$OUT/ios26/selftest"
"$TOOL" a64-verify --orig "$C" --lowered "$L" $dead_args --macho-orig "$T/root"
"$TOOL" a64-census --cache "$L/dyld_shared_cache_arm64e" --root "$L/macho" --all-slices --out "$OUT/ios26/census-$DEV-lowered"
"$TOOL" a64-lower --cache "$C" --out "$L.again" --page-shift 12 $dead_args > /dev/null
( cd "$L" && sha256_list dyld_shared_cache_arm64e* ) > "$OUT/ios26/lowered-$DEV.sha256"
( cd "$L.again" && sha256_list dyld_shared_cache_arm64e* ) > "$OUT/ios26/lowered-$DEV.again.sha256"
if cmp "$OUT/ios26/lowered-$DEV.sha256" "$OUT/ios26/lowered-$DEV.again.sha256"; then echo "deterministic: same SHA-256 for every cache file in both runs"; else echo "NOT deterministic"; exit 1; fi
rm -rf "$L.again"
du -sh "$L"
