#!/bin/bash
# Mi A3 iOS 26 donor files: the device tree of one IPSW (range read, im4p unpack). Apple files stay out of git.
#   scripts/bg.sh ios26-donor scripts/laurel/ios26-donor.sh
# Owner decision 2026-11-02: donor = iPhone 11, iPhone12,1, N104AP, A13, iOS 26.5.2 23F84.
# Parameters (env): DONOR_DEV (n104ap), DONOR_URL (the IPSW), DONOR_KC (kernelcache member), APPLE (~/op10-apple).
# Output: $APPLE/ios26/<build>-<dev>/DeviceTree.<dev>.im4p + <dev>.adt, + BuildManifest.plist, SHA256SUMS.
set -euo pipefail
. "$(dirname "$0")/../lib/env.sh"
DONOR_DEV=${DONOR_DEV:-n104ap}
DONOR_BUILD=${DONOR_BUILD:-23F84}
DONOR_URL=${DONOR_URL:-https://updates.cdn-apple.com/2026SpringFCS/fullrestores/140-26331/A86BA9CA-4666-4AD9-BF0D-14700375EF03/iPhone12,1_26.5.2_23F84_Restore.ipsw}
APPLE=${APPLE:-$HOME/op10-apple}
TOOL=$OUT/bin/op10tool
if [ ! -x "$TOOL" ]; then   # a worktree without its own tools: the main checkout's binary
  main=$(git -C "$REPO" worktree list --porcelain | sed -n '1s/^worktree //p')
  TOOL=$main/out/bin/op10tool
fi
[ -x "$TOOL" ] || { echo "ios26-donor: no op10tool: scripts/setup/build-op10tool.sh" >&2; exit 1; }
D=$APPLE/ios26/$DONOR_BUILD-$DONOR_DEV
mkdir -p "$D"
"$TOOL" ipsw-get -j 4 "$DONOR_URL" "$D" "Firmware/all_flash/DeviceTree.$DONOR_DEV.im4p" BuildManifest.plist
"$TOOL" im4p "$D/DeviceTree.$DONOR_DEV.im4p" "$D/$DONOR_DEV.adt"
(cd "$D" && sha256sum DeviceTree.$DONOR_DEV.im4p "$DONOR_DEV.adt" BuildManifest.plist > SHA256SUMS)
ls -l "$D"; cat "$D/SHA256SUMS"
