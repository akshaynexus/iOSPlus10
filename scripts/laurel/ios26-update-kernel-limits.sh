#!/bin/sh
# Mi A3 iOS 26: the jetsam limits on the phone, then the newest boot image, under the phone lock (standing order in CLAUDE.md). scripts/bg.sh NAME scripts/laurel/ios26-update-kernel-limits.sh
set -eu
cd "$(dirname "$0")/../.."
exec sh scripts/laurel/phone-lock.sh flash sh -c 'ONLY_JETSAM=1 sh scripts/laurel/ios26-live-update.sh && LAUREL_PANIC_SECS=0 EXTRA_ARGS=${EXTRA_ARGS:-ufsqueue=0} sh scripts/laurel/ios26-fast-flash.sh rw'
