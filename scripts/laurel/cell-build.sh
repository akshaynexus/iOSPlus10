#!/bin/bash
# Build the Mi A3 cellular bridge for SpringBoard on Linux (no Mac): liblaurel-cellbar.dylib. Docs: docs/laurel_sprout/cellular.md section 9.
#   scripts/bg.sh celln-bar scripts/laurel/cell-build.sh       (a few seconds; needs the GPU user space toolchain: scripts/laurel/gpu-env.sh)
# Sources: userland/laurel/cell/{laurel_cellbar.c,cellbar_state.h,laurel_celld.c,celld_net.h}. Output also: out/laurel/cell/root/usr/local/libexec/laurel-celld. liblaurel-cellbar: out/laurel/cell/root/usr/local/lib/liblaurel-cellbar.dylib (root-cell.sh installs it).
set -euo pipefail
. "$(dirname "$0")/gpu-env.sh"
gpu_need_toolchain
gpu_fetch_sdk
S=$REPO/userland/laurel/cell
N=$OUT/laurel/cell
R=$N/root
DSYM=$N/dsym                      # (gpu_dsym writes here)
rm -rf "$R" "$N/obj"
mkdir -p "$R/usr/local/lib" "$R/usr/local/libexec" "$N/obj"
F=$R/usr/local/lib/liblaurel-cellbar.dylib
gpu_cc "$F" -dynamiclib -install_name /usr/local/lib/liblaurel-cellbar.dylib -Wextra -Wno-unused-parameter -I"$S" -lobjc "$S/laurel_cellbar.c" 2> "$N/obj/cellbar.log" ||
  { cat "$N/obj/cellbar.log"; gpu_die "liblaurel-cellbar did not build"; }
[ -s "$N/obj/cellbar.log" ] && { cat "$N/obj/cellbar.log"; gpu_die "compiler warnings in liblaurel-cellbar"; }
gpu_dsym "$F"
"$LDID" -S "$F"                   # ad-hoc signature (the kernel's AMFI stand-in accepts it)
gpu_check_v80 "$F" || gpu_die "liblaurel-cellbar has ARMv8.1+ instructions"
# every library it loads is in the iOS shared cache (the dylib's own LC_ID_DYLIB line is listed too)
llvm-objdump --macho --dylibs-used "$F" | tail -n +2 | grep -vE '^\s+(/usr/lib/|/usr/local/lib/liblaurel-cellbar.dylib )' &&
  gpu_die "liblaurel-cellbar links a library that is not in /usr/lib"
# laurel-celld: the data session in configd. Root job, SCDynamicStore write access
D=$R/usr/local/libexec/laurel-celld
gpu_cc "$D" -Wextra -Wno-unused-parameter -I"$S" -framework CoreFoundation "$S/laurel_celld.c" 2> "$N/obj/celld.log" ||
  { cat "$N/obj/celld.log"; gpu_die "laurel-celld did not build"; }
[ -s "$N/obj/celld.log" ] && { cat "$N/obj/celld.log"; gpu_die "compiler warnings in laurel-celld"; }
gpu_dsym "$D"
"$LDID" -S"$S/celld.ents" "$D"
gpu_check_v80 "$D" || gpu_die "laurel-celld has ARMv8.1+ instructions"
(cd "$R" && find . -type f | sort | { while read -r f; do gpu_sha256_files "$f"; done; } > "$N/root.SHA256SUMS")
cat "$N/root.SHA256SUMS"
echo "cell-build: $F (root-cell.sh installs it)"
