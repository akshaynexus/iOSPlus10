#!/bin/bash
# The Rust toolchain of laurel-awdld, in out/laurel/awdl/rust. Rust's own release, pinned by sha256 (a distribution's rustc cannot use the official std of another target).
#   scripts/bg.sh awdl-rust scripts/laurel/awdl-rust.sh        (a few minutes; only the first time)
# Nothing runs from the archives while they unpack: tar, then the checked files are copied. macOS and Linux hosts differ only in the host triple (Linux x86_64 is what the iOS linker here needs).
set -euo pipefail
. "$(cd "$(dirname "$0")/../lib" && pwd)/env.sh"
V=1.99.1
HOST=x86_64-unknown-linux-gnu
HOST_SHA=231fcae47ee950621374725b5fc3b5441d2fbda2955ac45dd7dc816d8876cfe7
STD=rust-std-$V-aarch64-apple-ios
STD_SHA=d62c2e84717c6fa56ef0d8e5a11821850fb717c40879075a8e465a1e15af247c
A=$OUT/laurel/awdl
R=$A/rust
[ -x "$R/bin/rustc" ] && [ -d "$R/lib/rustlib/aarch64-apple-ios" ] && [ "$(cat "$R/.version" 2>/dev/null)" = "$V" ] && { echo "awdl-rust: have $V"; exit 0; }
mkdir -p "$A/dl"
fetch() {  # file sha
  [ "$(sha256sum "$A/dl/$1" 2>/dev/null | cut -d' ' -f1)" = "$2" ] && return 0
  curl -fsSL --retry 3 -o "$A/dl/$1" "https://static.rust-lang.org/dist/$1"
  [ "$(sha256sum "$A/dl/$1" | cut -d' ' -f1)" = "$2" ] || { echo "awdl-rust: $1: wrong sha256" >&2; exit 1; }
}
fetch "rust-$V-$HOST.tar.xz" "$HOST_SHA" &
fetch "$STD.tar.xz" "$STD_SHA" &
wait
T=$A/unpack
rm -rf "$T" "$R"
mkdir -p "$T" "$R"
tar -xJf "$A/dl/rust-$V-$HOST.tar.xz" -C "$T" &
tar -xJf "$A/dl/$STD.tar.xz" -C "$T" &
wait
H=$T/rust-$V-$HOST
cp -a "$H/rustc/." "$R/"
cp -a "$H/cargo/." "$R/"
cp -a "$H/rust-std-$HOST/." "$R/"
cp -a "$T/$STD/rust-std-aarch64-apple-ios/." "$R/"
rm -rf "$T" "$R"/manifest.in
echo "$V" > "$R/.version"
"$R/bin/rustc" --version
du -sh "$R"
