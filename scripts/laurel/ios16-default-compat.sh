#!/bin/bash
# Show that a default iOS 16 build did not change: what each default-built product hashes to at the base commit and now.
#   scripts/laurel/ios16-default-compat.sh save FILE     hashes of out/metal/stage, Turnip, and the wrapper + gate compiled the default way
#   scripts/laurel/ios16-default-compat.sh compare FILE  the same, compared; exit 1 on a difference
# SRC=DIR takes the C sources from DIR (a `git archive` of the base commit), WRAP_ONLY=1 hashes only the wrapper and the gate.
# The wrapper and the gate go through gpu_cc here (scripts/laurel/gpu-userland.sh steps 4 and 5), without the GL stack, so this needs no Mesa.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
[ -n "${SDK:-}" ] || { [ ! -d "$HERE/../../out/laurel-metal/sdk/iPhoneOS16.5.sdk" ] || export SDK=$(cd "$HERE/../.." && pwd)/out/laurel-metal/sdk/iPhoneOS16.5.sdk; }
. "$HERE/gpu-env.sh"
T=$OUT/ios16-compat
now() {
  rm -rf "$T"; mkdir -p "$T/src"
  # (one path for both runs: SRC=DIR is another checkout's tree, the base commit's)
  cp "${SRC:-$REPO}/userland/laurel/gpu/bbd_wrap.c" "${SRC:-$REPO}/userland/laurel/metal/metal_gate.c" "$T/src/"
  gpu_cc "$T/backboardd.wrap" "$T/src/bbd_wrap.c"
  gpu_cc "$T/laurel-metal-gate" -framework CoreFoundation -framework IOKit "$T/src/metal_gate.c"
  for f in "$T/backboardd.wrap" "$T/laurel-metal-gate"; do DSYM=$T/dsym gpu_dsym "$f"; "$LDID" -S "$f"; done
  [ "${WRAP_ONLY:-0}" = 1 ] || { ( cd "$OUT/metal/stage" && find . -type f | sort | xargs sha256sum )
    sha256sum "$OUT/gpu/turnip/libvulkan_freedreno.dylib" | sed "s#$OUT/##"; }
  ( cd "$T" && sha256sum backboardd.wrap laurel-metal-gate )
}
case "${1:-}" in
save) now > "$2"; wc -l "$2" ;;
compare)
  now > "$T.now"
  if diff "$2" "$T.now"; then echo "ios16-default-compat: $(wc -l < "$2") files: all the same bytes"; else echo "ios16-default-compat: DIFFERENT"; exit 1; fi ;;
*) sed -n 2,5p "$0"; exit 1 ;;
esac
