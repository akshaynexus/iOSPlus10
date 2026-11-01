#!/bin/bash
# Build the Mi A3 waterdrop pieces for SpringBoard on Linux (no Mac): liblaurel-notch.dylib + the SpringBoard start
# program laurel-springboard. Docs: docs/laurel_sprout/rtc-statusbar.md "C".
#   scripts/bg.sh sb2-build scripts/laurel/notch-build.sh       (a few seconds; needs the GPU user space toolchain)
# Toolchain = scripts/laurel/gpu-env.sh (stock clang + theos cctools ld64/ldid + iPhoneOS16.5.sdk); another checkout's
# copies can be used with THEOS=... SDK=... (both are read-only inputs).
# Sources: userland/laurel/notch/{laurel_notch.c,sb_wrap.c}.
# Output: out/laurel/notch/root/ = the files scripts/laurel/root-statusbar.py installs, laid out as on the phone:
#   usr/local/lib/liblaurel-notch.dylib  usr/local/libexec/laurel-springboard   (+ out/laurel/notch/root.SHA256SUMS)
set -euo pipefail
. "$(dirname "$0")/gpu-env.sh"
gpu_need_toolchain
gpu_fetch_sdk
S=$REPO/userland/laurel/notch
N=$OUT/laurel/notch
R=$N/root
DSYM=$N/dsym                      # (gpu_dsym writes here)
rm -rf "$R" "$N/obj"
mkdir -p "$R/usr/local/lib" "$R/usr/local/libexec" "$N/obj"

gpu_cc "$R/usr/local/lib/liblaurel-notch.dylib" -dynamiclib -install_name /usr/local/lib/liblaurel-notch.dylib \
  -Wextra -Wno-unused-parameter -lobjc "$S/laurel_notch.c" 2> "$N/obj/notch.log" ||
  { cat "$N/obj/notch.log"; gpu_die "liblaurel-notch did not build"; }
gpu_cc "$R/usr/local/libexec/laurel-springboard" -Wextra "$S/sb_wrap.c" 2> "$N/obj/wrap.log" ||
  { cat "$N/obj/wrap.log"; gpu_die "laurel-springboard did not build"; }
for l in "$N/obj/notch.log" "$N/obj/wrap.log"; do
  [ -s "$l" ] && { cat "$l"; gpu_die "compiler warnings in $(basename "$l" .log)"; }
done

for f in "$R/usr/local/lib/liblaurel-notch.dylib" "$R/usr/local/libexec/laurel-springboard"; do
  gpu_dsym "$f"
  "$LDID" -S "$f"                 # ad-hoc signature (the kernel's AMFI stand-in accepts it)
  gpu_check_v80 "$f" || gpu_die "$(basename "$f") has ARMv8.1+ instructions"
done
# every library they load is in the iOS shared cache (the dylib's own LC_ID_DYLIB line is listed too)
for f in "$R/usr/local/lib/liblaurel-notch.dylib" "$R/usr/local/libexec/laurel-springboard"; do
  llvm-objdump --macho --dylibs-used "$f" | tail -n +2 | grep -vE '^\s+(/usr/lib/|/usr/local/lib/liblaurel-notch.dylib )' &&
    gpu_die "$(basename "$f") links a library that is not in /usr/lib"
done
(cd "$R" && find . -type f | sort | { while read -r f; do gpu_sha256_files "$f"; done; } > "$N/root.SHA256SUMS")
cat "$N/root.SHA256SUMS"
echo "notch-build: $R (root-statusbar.py installs it)"
