#!/bin/bash
# Build /usr/libexec/laurel-awdld (userland/laurel/awdl), the AWDL daemon of AirDrop on the Mi A3. Docs: docs/laurel_sprout/airdrop-awdl.md.
#   scripts/bg.sh awdl-build scripts/laurel/awdl-build.sh      (build-all.sh runs it)
# Needs: out/awdl-src (scripts/debug/awdl-sources.sh: owly-awdl, MIT, pinned), the toolchain of scripts/laurel/awdl-rust.sh, gpu-env.sh's SDK and linker.
# Steps: cargo test on the host (all pure code) -> cargo build for aarch64-apple-ios -> strip, ldid -> no instruction newer than ARMv8.0, only the phone's libraries.
# Output: out/laurel/awdl/root/usr/libexec/laurel-awdld.
set -euo pipefail
. "$(dirname "$0")/gpu-env.sh"
gpu_need_toolchain
gpu_fetch_sdk
A=$OUT/laurel/awdl
[ -f "$OUT/awdl-src/owly/crates/owly-awdl/Cargo.toml" ] || "$REPO/scripts/debug/awdl-sources.sh"
"$REPO/scripts/laurel/awdl-rust.sh"
R=$A/rust/bin
S=$REPO/userland/laurel/awdl
export PATH=$R:$PATH CARGO_HOME=$A/cargo-home
# the crate's workspace is its own: the build reads no other file of Owly's and takes nothing from crates.io
(cd "$S" && CARGO_TARGET_DIR=$A/host cargo test --offline 2>&1 | tail -4)
L=$A/ld-ios.sh
mkdir -p "$A"
cat > "$L.new" <<LD
#!/bin/sh
exec "$CLANG" -target arm64-apple-ios$IOS_MIN -isysroot "$SDK" --ld-path="$LD64" -Wl,-sdk_version,16.5 "\$@"
LD
chmod +x "$L.new"
mv -f "$L.new" "$L"
(cd "$S" && CARGO_TARGET_DIR=$A/ios CARGO_TARGET_AARCH64_APPLE_IOS_LINKER=$L RUSTFLAGS="-C target-cpu=cortex-a53" \
  SDKROOT=$SDK IPHONEOS_DEPLOYMENT_TARGET=$IOS_MIN cargo build --release --offline --target aarch64-apple-ios --bin laurel-awdld 2>&1 | tail -5)
B=$A/ios/aarch64-apple-ios/release/laurel-awdld
T=$A/root/usr/libexec/laurel-awdld
rm -rf "$A/root"
mkdir -p "$A/root/usr/libexec"
cp "$B" "$T"
"$STRIP" -x "$T" 2>/dev/null || true
"$LDID" -S "$T"
gpu_check_v80 "$T" || gpu_die "laurel-awdld has ARMv8.1+ instructions"
llvm-objdump --macho --dylibs-used "$T" | tail -n +2 | grep -vE '^\s+(/usr/lib/|/System/Library/)' && gpu_die "laurel-awdld links a library that is not on the phone"
echo "awdl-build: $T ($(wc -c < "$T") bytes, sha256 $(sha256sum "$T" | cut -c1-16))"
