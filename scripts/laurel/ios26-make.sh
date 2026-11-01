#!/bin/bash
# Incremental make of the Mi A3 iOS 26 kernel (developer loop) with -k: all compile errors in one run.
#   scripts/bg.sh ios26-make scripts/laurel/ios26-make.sh [make args]
# Log out/laurel-kernel-ios26/make.log; the error list out/laurel-kernel-ios26/make-errors.txt.
set -uo pipefail
. "$(dirname "$0")/../lib/env.sh"
. "$REPO/scripts/laurel/ios26-env.sh"
export PATCHES_DIR=$W/patches
. "$REPO/scripts/laurel/ios26-sdk-overlay.sh"
[ "${PAGES:-4k}" = 4k ] && export TOPAZ_4K=1
bash "$W/linux/build.sh" -k VERBOSE=YES "$@" > "$W/make.log" 2>&1
rc=$?
grep -aE "(error|fatal error):|Undefined symbols|No rule to make" "$W/make.log" | grep -av "^make" | sed "s#$XNU_SRC/##" | sort -u > "$W/make-errors.txt"
echo "make rc=$rc, $(wc -l < "$W/make-errors.txt") error lines"
head -"${SHOW:-60}" "$W/make-errors.txt" | cut -c1-220
exit 0
