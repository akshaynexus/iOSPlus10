#!/bin/sh
# Build the Rust CLI tools/op10tool (img2simg, ipsw-get, uefi-unpack, uefi-portpatch, im4p) and put
# the binary at out/bin/op10tool. Needs cargo (rustup). Run in tmux:
#   scripts/bg.sh op10tool scripts/setup/build-op10tool.sh      (or: make op10tool)
set -eu
. "$(dirname "$0")/../lib/env.sh"
cargo build --release --manifest-path "$REPO/tools/op10tool/Cargo.toml" --target-dir "$OUT/cargo"
mkdir -p "$OUT/bin"
cp "$OUT/cargo/release/op10tool" "$OUT/bin/op10tool"
"$OUT/bin/op10tool" --version
