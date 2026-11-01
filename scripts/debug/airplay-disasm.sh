#!/bin/bash
# Disassembly of the AirPlay images of the 20H392 dyld cache, for docs/laurel_sprout/airplay-airdrop.md. Read-only. Apple code: out/awdl-re/ only (git-ignored).
#   scripts/bg.sh awdl-dis scripts/debug/airplay-disasm.sh [IMAGE...]     (default AirPlaySender AirPlaySupport APTransport)
# Needs apfs-fuse and ipsw (same inputs as scripts/debug/air-re.sh). macOS + Linux.
set -euo pipefail
here=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
main=$(git -C "$here" worktree list --porcelain | sed -n '1s/^worktree //p')
APPLE=${APPLE:-$HOME/op10-apple}
IPSW=${IPSW:-$(command -v ipsw || echo "$main/out/laurel-metal/ipsw/ipsw")}
mnt=$here/out/mnt-cryptex
W=$here/out/awdl-re
mkdir -p "$mnt" "$W"
[ -d "$mnt/root/System" ] || apfs-fuse -o ro "$APPLE/20H392/087-86593-047.dmg" "$mnt"
DSC=$mnt/root/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64
[ $# -gt 0 ] || set -- AirPlaySender AirPlaySupport APTransport
for image in "$@"; do
  "$IPSW" dyld disass "$DSC" --image "$image" --quiet --color=false > "$W/$image.s" 2> "$W/$image.err" || { tail -3 "$W/$image.err"; }
  wc -l "$W/$image.s"
done
