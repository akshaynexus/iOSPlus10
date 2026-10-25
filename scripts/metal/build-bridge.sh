#!/bin/bash
# Build the native Metal bridge (ios-flame phone/metal2/bridge/NativeMetalBridge.rs, UniXNU's MIT bridge over the
# metal2vulkan runtime) as a static library: out/metal/bridge/<target>/libnative_metal_bridge.a
#   scripts/metal/build-bridge.sh [ios|host]      (host: aarch64-apple-darwin, for checks on the Mac)
# First: scripts/metal/fetch-sources.sh. Recipe: ios-flame tools/build-m2v-bridge.sh (MIT, 745c434).
# Run in tmux: scripts/bg.sh metal-bridge scripts/metal/build-bridge.sh   (BRIDGE_TARGET_DIR=DIR: cargo target dir)
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/env.sh"
target=${1:-ios}
B=$MOUT/bridge
mkdir -p "$B"
[ -d "$M2V/crates" ] || { echo "no metal2vulkan in $M2V: run scripts/metal/fetch-sources.sh" >&2; exit 1; }
BR=$FLAME_SRC/phone/metal2/bridge
LLVM_AS=${LLVM_AS:-$(command -v llvm-as || echo /opt/homebrew/opt/llvm/bin/llvm-as)}
[ -x "$LLVM_AS" ] || { echo "llvm-as missing: brew install llvm (Linux: apt install llvm)" >&2; exit 1; }
# the bridge's self-test fixtures (assembled AIR) are compiled into it with include_bytes!
"$LLVM_AS" -o "$B/runtime_examples.air" "$M2V/crates/metal2vulkan-validation/fixtures/public/examples/runtime_examples.ll"
"$LLVM_AS" -o "$B/function_constant.air" "$M2V/crates/metal2vulkan-validation/fixtures/public/kernel_function_constant_gate_fold.ll"
cat > "$B/Cargo.toml" <<TOML
[package]
name = "native-metal-bridge"
version = "0.1.0"
edition = "2024"
rust-version = "1.98"
[workspace]
[lib]
crate-type = ["staticlib"]
path = "$BR/NativeMetalBridge.rs"
[dependencies]
metal2vulkan = { path = "$M2V/crates/metal2vulkan", features = ["ash"] }
metal2vulkan-runtime = { path = "$M2V/crates/metal2vulkan-runtime" }
libc = "0.2"
sha2 = { version = "0.10", features = ["asm"] }
[profile.release]
panic = "unwind"
debug = 1
TOML
case $target in
ios)  triple=aarch64-apple-ios ;;
host) triple=aarch64-apple-darwin ;;
*) echo "target: ios or host" >&2; exit 1 ;;
esac
export NMB_FIXTURE_AIR=$B/runtime_examples.air NMB_FC_AIR=$B/function_constant.air
export IPHONEOS_DEPLOYMENT_TARGET=$IOS_MIN MACOSX_DEPLOYMENT_TARGET=14.0
export CARGO_BUILD_JOBS=$NPROC
cargo "+$RUST_TOOLCHAIN" build --release --manifest-path "$B/Cargo.toml" --target $triple --target-dir "${BRIDGE_TARGET_DIR:-$B/target}"
mkdir -p "$B/$target"
cp "${BRIDGE_TARGET_DIR:-$B/target}/$triple/release/libnative_metal_bridge.a" "$B/$target/"
ls -la "$B/$target/libnative_metal_bridge.a"
