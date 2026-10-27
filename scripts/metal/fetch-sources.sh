#!/bin/bash
# Fetch the sources of the Metal path into out/metal/src (git-ignored):
#   1. metal2vulkan (steelbrain/metal2vulkan, GPL-2.0-or-later OR LGPL-3.0-or-later) at the submodule's pin
#      (f6a96b7d since 2026-10-27; UniXNU and ios-flame use 720ef1ce), plus the bridge patches from ios-flame
#      (0001-0006 from UniXNU, 0100-0101 flame; rebased copies in userland/metal/patches/m2v-flame for a newer pin).
#   2. ios-flame's Metal v2 frontend + bridge (MIT; phone/metal2/{NativeBridgeMetalFrontend.*,bridge/*})
#      exported from the external/ios-flame submodule's git objects at FLAME_COMMIT (no copy in this repo),
#      then our patches from userland/metal/patches/flame/*.patch on top.
#   3. The Rust toolchain metal2vulkan needs (1.98.0 + aarch64-apple-ios), through rustup.
# Pins: docs/metal-design.md "Versions". Run in tmux: scripts/bg.sh metal-fetch scripts/metal/fetch-sources.sh
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/env.sh"

mkdir -p "$MSRC"

# 1. metal2vulkan: from the submodule's git objects (external/metal2vulkan), like ios-flame below
git -C "$M2V_SUB" cat-file -e "$M2V_COMMIT^{commit}" || { echo "external/metal2vulkan lacks $M2V_COMMIT: git submodule update --init external/metal2vulkan" >&2; exit 1; }
rm -rf "$M2V"; mkdir -p "$M2V"
git -C "$M2V_SUB" archive "$M2V_COMMIT" | tar -x -C "$M2V"
git -C "$M2V" init -q && git -C "$M2V" add -A && git -C "$M2V" -c user.name=negroni -c user.email=negroni@local commit -q -m "metal2vulkan $M2V_COMMIT" 
echo "metal2vulkan $M2V_COMMIT -> $M2V"

# 2. ios-flame frontend + bridge, exported from the submodule objects
git -C "$FLAME" cat-file -e "$FLAME_COMMIT^{commit}" || { echo "external/ios-flame lacks $FLAME_COMMIT: git -C external/ios-flame fetch" >&2; exit 1; }
rm -rf "$FLAME_SRC" && mkdir -p "$FLAME_SRC"
git -C "$FLAME" archive "$FLAME_COMMIT" phone/metal2 phone/turnip/NativeAdrenoABI.h | tar -x -C "$FLAME_SRC"
# Its own git repository, as for metal2vulkan: without it `git -C "$FLAME_SRC" apply` resolves to this repo (out/ lies
# inside it), takes the patch paths as relative to the repo root and skips every file with exit 0 ("Skipped patch").
git -C "$FLAME_SRC" init -q && git -C "$FLAME_SRC" add -A && git -C "$FLAME_SRC" -c user.name=negroni -c user.email=negroni@local commit -q -m "ios-flame $FLAME_COMMIT"
echo "ios-flame $FLAME_COMMIT -> $FLAME_SRC/phone/metal2"

# metal2vulkan patches: UniXNU's (0001-0006, as ios-flame carries them) + ios-flame's 0100/0101. ios-flame's copies are
# for metal2vulkan 720ef1ce; for a newer pin our rebased copies in userland/metal/patches/m2v-flame are used instead
# (0005 is upstream since 4348323b/cba1270d; docs/metal-widgets-2026-10-27.md section 8 has the table).
# Our own m2v patches follow the pin too: m2v/ is for the newer pin, m2v-720ef1ce/ keeps the copies for 720ef1ce (the
# rollback pin); flame patches named *-m2v-<commit>.patch need that metal2vulkan API and are left out at 720ef1ce.
OLD_PIN=
if [ "$M2V_COMMIT" = 720ef1ce9ae2a2068999a8675717418b9416283e ]; then
  OLD_PIN=1
  for p in "$FLAME_SRC"/phone/metal2/bridge/patches/*.patch; do
    case "$(basename "$p")" in 0006-*) continue ;; esac   # UniXNU does not apply 0006 either
    git -C "$M2V" apply --whitespace=nowarn "$p" && echo "applied $(basename "$p")"
  done
else
  for p in "$METAL"/patches/m2v-flame/*.patch; do
    git -C "$M2V" apply --whitespace=nowarn "$p" && echo "applied m2v-flame/$(basename "$p")"
  done
fi
# our own patches (if any) on top of both trees
M2V_OWN=$METAL/patches/m2v; [ -n "$OLD_PIN" ] && M2V_OWN=$METAL/patches/m2v-720ef1ce
for p in "$M2V_OWN"/*.patch; do
  [ -f "$p" ] || continue
  git -C "$M2V" apply --whitespace=nowarn "$p" && echo "applied $(basename "$M2V_OWN")/$(basename "$p")"
done
for p in "$METAL"/patches/flame/*.patch; do
  [ -f "$p" ] || continue
  case "$(basename "$p")" in *-m2v-*.patch) [ -n "$OLD_PIN" ] && { echo "skipped flame/$(basename "$p") (metal2vulkan 720ef1ce)"; continue; } ;; esac
  git -C "$FLAME_SRC" apply --whitespace=nowarn "$p" 2>/dev/null || (cd "$FLAME_SRC" && patch -p1 --forward < "$p")
  echo "applied flame/$(basename "$p")"
done

# 3. Rust toolchain
if command -v rustup >/dev/null; then
  if ! rustup toolchain list | grep -q "^$RUST_TOOLCHAIN"; then
    rustup toolchain install "$RUST_TOOLCHAIN" --profile minimal
  fi
  if ! rustup target list --toolchain "$RUST_TOOLCHAIN" | grep -q "aarch64-apple-ios (installed)"; then
    rustup target add aarch64-apple-ios --toolchain "$RUST_TOOLCHAIN"
  fi
else
  echo "rustup missing: install it (https://rustup.rs) and run this again" >&2; exit 1
fi
echo "fetch done"
