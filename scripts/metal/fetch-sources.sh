#!/bin/bash
# Fetch the sources of the Metal path into out/metal/src (git-ignored):
#   1. metal2vulkan (steelbrain/metal2vulkan, GPL-2.0-or-later OR LGPL-3.0-or-later) at the submodule's pin
#      (219f013 since 2026-11-01; UniXNU and ios-flame use 720ef1ce), plus the bridge patches from ios-flame
#      (0001-0006 from UniXNU, 0100-0101 flame; rebased copies in userland/metal/patches/m2v-flame* per pin, below).
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

# metal2vulkan patches by pin (docs/metal-design.md "Versions"):
#   219f013 (current, 2026-11-01): userland/metal/patches/m2v-flame + m2v (rebased; m2v/0003 dropped: upstream's
#            native-arithmetic round removed the policies it set and does by default what it did)
#   f6a96b7d (rollback): m2v-flame-f6a96b7d + m2v-f6a96b7d            720ef1ce (older rollback): ios-flame's own
#            bridge patches + m2v-720ef1ce
#   `git -C external/metal2vulkan checkout <pin>` selects one; this script follows the submodule's HEAD.
# Flame patches named *-m2v-<commit>.patch need that metal2vulkan API: applied only when the pin contains <commit>.
OLD_PIN=
case "$M2V_COMMIT" in
720ef1ce9ae2a2068999a8675717418b9416283e)
  OLD_PIN=720ef1ce
  for p in "$FLAME_SRC"/phone/metal2/bridge/patches/*.patch; do
    case "$(basename "$p")" in 0006-*) continue ;; esac   # UniXNU does not apply 0006 either
    git -C "$M2V" apply --whitespace=nowarn "$p" && echo "applied $(basename "$p")"
  done ;;
f6a96b7da82f3032e3fd7b1dc52c07bfd9b78dc8) OLD_PIN=f6a96b7d ;;
esac
M2V_FLAME=$METAL/patches/m2v-flame M2V_OWN=$METAL/patches/m2v
[ -n "$OLD_PIN" ] && M2V_FLAME=$METAL/patches/m2v-flame-$OLD_PIN M2V_OWN=$METAL/patches/m2v-$OLD_PIN
for p in "$M2V_FLAME"/*.patch "$M2V_OWN"/*.patch; do
  [ -f "$p" ] || continue
  git -C "$M2V" apply --whitespace=nowarn "$p" || { echo "$(basename "$(dirname "$p")")/$(basename "$p") does not apply" >&2; exit 1; }
  echo "applied $(basename "$(dirname "$p")")/$(basename "$p")"
done
for p in "$METAL"/patches/flame/*.patch; do
  [ -f "$p" ] || continue
  need=$(basename "$p" | sed -n 's/.*-m2v-\([0-9a-f]\{7,40\}\)\.patch$/\1/p')
  if [ -n "$need" ] && ! git -C "$M2V_SUB" merge-base --is-ancestor "$need" "$M2V_COMMIT" 2>/dev/null; then
    echo "skipped flame/$(basename "$p") (needs metal2vulkan $need, pin is ${M2V_COMMIT:0:9})"; continue
  fi
  git -C "$FLAME_SRC" apply --whitespace=nowarn "$p" 2>/dev/null || (cd "$FLAME_SRC" && patch -p1 --forward < "$p")
  echo "applied flame/$(basename "$p")"
done

# A second tree (scripts/laurel/ios26-metal-build.sh) adds its own frontend + bridge patches and metal2vulkan patches last. Unset: nothing.
for d in ${METAL_EXTRA_FLAME:-}; do
  for p in "$d"/*.patch; do
    [ -f "$p" ] || continue
    git -C "$FLAME_SRC" apply --whitespace=nowarn "$p" || { echo "$(basename "$p") does not apply" >&2; exit 1; }
    echo "applied extra $(basename "$p")"
  done
done
for p in ${METAL_EXTRA_M2V:+"$METAL_EXTRA_M2V"/*.patch}; do
  [ -f "$p" ] || continue
  git -C "$M2V" apply --whitespace=nowarn "$p" || { echo "$(basename "$p") does not apply" >&2; exit 1; }
  echo "applied extra $(basename "$p")"
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
