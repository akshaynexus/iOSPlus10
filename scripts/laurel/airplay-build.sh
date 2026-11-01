#!/bin/bash
# Build /usr/libexec/laurel-airplay (userland/laurel/airplay/airplay_check.c), the self-check of AirPlay on the Mi A3. Docs: docs/laurel_sprout/airplay-airdrop.md.
#   scripts/laurel/airplay-build.sh          (a few seconds; build-all.sh runs it)
# Toolchain = scripts/laurel/gpu-env.sh. Checks: no compiler warning, no instruction newer than ARMv8.0, only libraries of the phone.
# Output: out/laurel/airplay/root/usr/libexec/laurel-airplay; scripts/laurel/root-airplay.sh installs it.
set -euo pipefail
. "$(dirname "$0")/gpu-env.sh"
gpu_need_toolchain
gpu_fetch_sdk
N=$OUT/laurel/airplay
R=$N/root
DSYM=$N/dsym                      # (gpu_dsym writes here)
rm -rf "$R" "$N/obj"
mkdir -p "$R/usr/libexec" "$N/obj"
T=$R/usr/libexec/laurel-airplay
# -sdk_version: ld64 reads an SDK version from digits in the -syslibroot path otherwise (a worktree path, docs/notes.md gotcha)
gpu_cc "$T" -Wl,-sdk_version,16.5 -Wextra -framework CoreFoundation -framework IOKit "$REPO/userland/laurel/airplay/airplay_check.c" 2> "$N/obj/cc.log" ||
  { cat "$N/obj/cc.log"; gpu_die "laurel-airplay did not build"; }
[ ! -s "$N/obj/cc.log" ] || { cat "$N/obj/cc.log"; gpu_die "compiler warnings in laurel-airplay"; }
gpu_dsym "$T"
"$LDID" -S "$T"
gpu_check_v80 "$T" || gpu_die "laurel-airplay has ARMv8.1+ instructions"
llvm-objdump --macho --dylibs-used "$T" | tail -n +2 | grep -vE '^\s+(/usr/lib/|/System/Library/)' && gpu_die "laurel-airplay links a library that is not on the phone"
echo "airplay-build: $T ($(wc -c < "$T") bytes, sha256 $(sha256sum "$T" | cut -c1-16))"
