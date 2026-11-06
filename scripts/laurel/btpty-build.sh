#!/bin/bash
# Build the Mi A3 bluetoothd pieces on Linux (no Mac): liblaurel-btpty.dylib (openpty's central end non-blocking, so an
# accessory's iAP channel cannot stop bluetoothd's stack; port of Scion 2e0c90a) + the bluetoothd start program
# laurel-bluetoothd that inserts it. Docs: docs/laurel_sprout/bluetooth.md "iAP PTY".
#   scripts/laurel/btpty-build.sh       (a few seconds; needs the GPU user space toolchain, scripts/laurel/gpu-env.sh)
# Sources: userland/laurel/bt/{laurel_btpty.c,btd_wrap.c}.
# Output: out/laurel/bt/root/ = the files scripts/laurel/root-bt.sh installs, laid out as on the phone:
#   usr/local/lib/liblaurel-btpty.dylib  usr/local/libexec/laurel-bluetoothd   (+ out/laurel/bt/root.SHA256SUMS)
set -euo pipefail
. "$(dirname "$0")/gpu-env.sh"
gpu_need_toolchain
gpu_fetch_sdk
S=$REPO/userland/laurel/bt
N=$OUT/laurel/bt
R=$N/root
DSYM=$N/dsym
rm -rf "$R" "$N/obj"
mkdir -p "$R/usr/local/lib" "$R/usr/local/libexec" "$N/obj"

gpu_cc "$R/usr/local/lib/liblaurel-btpty.dylib" -dynamiclib -install_name /usr/local/lib/liblaurel-btpty.dylib \
  -Wextra "$S/laurel_btpty.c" 2> "$N/obj/btpty.log" || { cat "$N/obj/btpty.log"; gpu_die "liblaurel-btpty did not build"; }
gpu_cc "$R/usr/local/libexec/laurel-bluetoothd" -Wextra "$S/btd_wrap.c" 2> "$N/obj/wrap.log" ||
  { cat "$N/obj/wrap.log"; gpu_die "laurel-bluetoothd did not build"; }
for l in "$N/obj/btpty.log" "$N/obj/wrap.log"; do
  [ -s "$l" ] && { cat "$l"; gpu_die "compiler warnings in $(basename "$l" .log)"; }
done
for f in "$R/usr/local/lib/liblaurel-btpty.dylib" "$R/usr/local/libexec/laurel-bluetoothd"; do
  gpu_dsym "$f"
  "$LDID" -S "$f"                 # ad-hoc signature (the kernel's AMFI stand-in accepts it)
  gpu_check_v80 "$f" || gpu_die "$(basename "$f") has ARMv8.1+ instructions"
  llvm-objdump --macho --dylibs-used "$f" | tail -n +2 | grep -vE '^\s+(/usr/lib/|/usr/local/lib/liblaurel-btpty.dylib )' &&
    gpu_die "$(basename "$f") links a library that is not in /usr/lib"
done
# the interposer must name openpty
llvm-objdump --macho --section-headers "$R/usr/local/lib/liblaurel-btpty.dylib" | grep -q __interpose || gpu_die "no __interpose section"
llvm-nm -u "$R/usr/local/lib/liblaurel-btpty.dylib" | grep -q '_openpty$' || gpu_die "openpty is not imported"
(cd "$R" && find . -type f | sort | { while read -r f; do gpu_sha256_files "$f"; done; } > "$N/root.SHA256SUMS")
cat "$N/root.SHA256SUMS"
echo "btpty-build: $R (root-bt.sh installs it)"
