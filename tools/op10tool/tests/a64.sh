#!/bin/sh
# Tests of the a64 commands: unit tests + synthetic Mach-O end to end (cargo test), real execution of every LSE form under
# qemu (a64-selftest). Needs llvm-mc, qemu-aarch64. No Apple file. Real-sample checks: scripts/ios26/lower-userland.sh.
set -eu
REPO=$(cd "$(dirname "$0")/../../.." && pwd)
. "$REPO/scripts/lib/env.sh"
cargo test --release --manifest-path "$REPO/tools/op10tool/Cargo.toml" --target-dir "$OUT/cargo" -- a64 lower
"$OUT/bin/op10tool" a64-selftest --out "$OUT/ios26/selftest"
