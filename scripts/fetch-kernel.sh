#!/bin/sh
# Download the negroni iOS 16 kernel (xnu-8796 + slop patches) from the slop CI.
#   scripts/fetch-kernel.sh [RUN_ID]     (default: kernel.run in config/negroni-ne2211.toml)
# Needs gh (any logged-in account; the artifact is public). Output: out/kernel/<run>/ and the
# link out/kernel/kernel.macho.
set -eu
. "$(dirname "$0")/env.sh"
C="python3 $REPO/scripts/conf.py"
RUN=${1:-$($C kernel.run)}
D=$OUT/kernel/$RUN
MACHO=$($C kernel.macho)
if [ ! -f "$D/$MACHO" ]; then
  gh run download "$RUN" -R "$($C kernel.repo)" -n "$($C kernel.artifact)" -D "$D"
fi
if [ -f "$D/SHA256SUMS" ]; then
  (cd "$D" && { sha256sum -c SHA256SUMS 2>/dev/null || shasum -a 256 -c SHA256SUMS; })
fi
ln -sf "$RUN/$MACHO" "$OUT/kernel/kernel.macho"
ls -l "$OUT/kernel/kernel.macho" "$D"
