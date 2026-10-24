#!/bin/bash
# Fetch the sources of the Metal path into out/metal/src (git-ignored):
#   1. metal2vulkan (steelbrain/metal2vulkan, GPL-2.0-or-later OR LGPL-3.0-or-later) at the pin UniXNU and
#      ios-flame use (720ef1ce), plus the bridge patches from ios-flame (0001-0006 from UniXNU, 0100-0101 flame).
#   2. ios-flame's Metal v2 frontend + bridge (MIT; phone/metal2/{NativeBridgeMetalFrontend.*,bridge/*})
#      exported from the external/ios-flame submodule's git objects at FLAME_COMMIT (no copy in this repo),
#      then our patches from userland/metal/patches/flame/*.patch on top.
#   3. The Rust toolchain metal2vulkan needs (1.98.0 + aarch64-apple-ios), through rustup.
# Pins: docs/metal-design.md "Versions". Run in tmux: scripts/bg.sh metal-fetch scripts/metal/fetch-sources.sh
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/env.sh"

mkdir -p "$MSRC"

# 1. metal2vulkan
if [ ! -d "$M2V/.git" ]; then
  git clone --filter=blob:none "$M2V_URL" "$M2V"
fi
git -C "$M2V" fetch -q origin "$M2V_COMMIT" 2>/dev/null || git -C "$M2V" fetch -q origin
git -C "$M2V" checkout -q -f "$M2V_COMMIT"
git -C "$M2V" clean -q -fdx
echo "metal2vulkan $(git -C "$M2V" rev-parse --short HEAD)"

# 2. ios-flame frontend + bridge, exported from the submodule objects
git -C "$FLAME" cat-file -e "$FLAME_COMMIT^{commit}" || { echo "external/ios-flame lacks $FLAME_COMMIT: git -C external/ios-flame fetch" >&2; exit 1; }
rm -rf "$FLAME_SRC" && mkdir -p "$FLAME_SRC"
git -C "$FLAME" archive "$FLAME_COMMIT" phone/metal2 phone/turnip/NativeAdrenoABI.h | tar -x -C "$FLAME_SRC"
echo "ios-flame $FLAME_COMMIT -> $FLAME_SRC/phone/metal2"

# metal2vulkan patches: UniXNU's (0001-0006, as ios-flame carries them) + ios-flame's 0100/0101
for p in "$FLAME_SRC"/phone/metal2/bridge/patches/*.patch; do
  case "$(basename "$p")" in 0006-*) continue ;; esac   # UniXNU does not apply 0006 either
  git -C "$M2V" apply --whitespace=nowarn "$p" && echo "applied $(basename "$p")"
done
# our own patches (if any) on top of both trees
for p in "$METAL"/patches/m2v/*.patch; do
  [ -f "$p" ] || continue
  git -C "$M2V" apply --whitespace=nowarn "$p" && echo "applied m2v/$(basename "$p")"
done
for p in "$METAL"/patches/flame/*.patch; do
  [ -f "$p" ] || continue
  git -C "$FLAME_SRC" apply --whitespace=nowarn "$p" 2>/dev/null || (cd "$FLAME_SRC" && patch -p1 < "$p")
  echo "applied flame/$(basename "$p")"
done

# 3. Rust toolchain
if command -v rustup >/dev/null; then
  rustup toolchain install "$RUST_TOOLCHAIN" --profile minimal
  rustup target add aarch64-apple-ios --toolchain "$RUST_TOOLCHAIN"
else
  echo "rustup missing: install it (https://rustup.rs) and run this again" >&2; exit 1
fi
echo "fetch done"
