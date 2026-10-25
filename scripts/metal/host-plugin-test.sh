#!/bin/bash
# Host test of the NegroniMetal plugin logic on a Mac (no phone): userland/metal/tests/host-plugin-test.mm says what it
# checks. Builds the plugin + frontend + harness for macOS arm64 against the host bridge
# (scripts/metal/build-bridge.sh host) and runs each case with MoltenVK (brew install molten-vk) in place of Turnip.
#   scripts/metal/host-plugin-test.sh            output: logs/ (via bg.sh) or stdout; work dir out/metal/hosttest
# Run in tmux: scripts/bg.sh metal-hosttest scripts/metal/host-plugin-test.sh
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/env.sh"
[ "$(uname -s)" = Darwin ] || { echo "macOS only (Metal.framework + MoltenVK)" >&2; exit 1; }
BR=$MOUT/bridge/host/libnative_metal_bridge.a
[ -f "$BR" ] || { echo "no $BR: scripts/metal/build-bridge.sh host" >&2; exit 1; }
MVK=${MVK:-$(brew --prefix 2>/dev/null || echo /opt/homebrew)/lib/libMoltenVK.dylib}
[ -f "$MVK" ] || { echo "no MoltenVK at $MVK (brew install molten-vk)" >&2; exit 1; }
FRONT=$FLAME_SRC/phone/metal2
W=$MOUT/hosttest
rm -rf "$W" && mkdir -p "$W/nmtl"
SDKM=$(xcrun --sdk macosx --show-sdk-path)
xcrun --sdk macosx clang++ -arch arm64 -mmacosx-version-min=14.0 -isysroot "$SDKM" -std=c++17 -fobjc-arc -O1 -g \
  -Wall -Wno-deprecated-declarations -Wno-unused-function -DNMTL_HOST_TEST=1 -DNMTL_DIR="\"$W/nmtl\"" -I"$FRONT" \
  "$METAL/plugin/NegroniMetal.mm" "$FRONT/NativeBridgeMetalFrontend.mm" "$METAL/tests/host-plugin-test.mm" "$BR" \
  -framework Foundation -framework Metal -framework IOSurface -framework IOKit -framework CoreFoundation \
  -framework Security -framework QuartzCore -lc++ -o "$W/host-plugin-test"
N=$W/nmtl
T=$W/host-plugin-test
fails=0
run() { # case: setup is done by the caller
  echo "== $1"
  if ! NEGRONI_TURNIP=$MVK "$T" "$1"; then fails=$((fails + 1)); fi
}
# the bundle's control files (off, clients, clients.local) live in their own directory here
B=$W/bundle
mkdir -p "$B"
export NMTL_HOST_BUNDLE=$B
: > "$N/metal.log"
rm -f "$N/clients"; run unlisted
echo "*" > "$N/clients"; touch "$N/off"; run off; rm -f "$N/off"
touch "$B/off"; run bundleoff; rm -f "$B/off"
# a bundle directory the process cannot search: BUNDLE/off cannot be checked, so no device (fail closed)
mkdir -p "$W/locked"; chmod 000 "$W/locked"; NMTL_HOST_BUNDLE=$W/locked run blocked; chmod 755 "$W/locked"
NMTL_HOST_NO_GPU=1 run nogpu
echo "NEGRONIMETAL_OPEN_MS=1" > "$N/env"; run timeout; run timeout; rm -f "$N/env"
echo "strikes after two timeouts: $(cat "$N/strikes/host-plugin-test" 2>/dev/null || echo none)"
run deadman
# listed only in BUNDLE/clients.local (the file a sandboxed app reads), not in NMTL_DIR/clients
rm -rf "$N/strikes"; rm -f "$N/clients"; echo "host-plugin-test" > "$B/clients.local"; run device
# GPU watchdog: a command buffer that never completes marks the GPU lost; the next process gets no device
rm -rf "$N/strikes"
NEGRONIMETAL_WATCHDOG=1 NEGRONIMETAL_WATCHDOG_S=1 NMTL_HOST_MARKER=$N/strikes/gpu-lost run watchdog
echo "gpu-lost marker: $(cat "$N/strikes/gpu-lost" 2>/dev/null || echo none)"
run lost; rm -f "$N/strikes/gpu-lost"
echo "== plugin log"; cat "$N/metal.log"
echo "host-plugin-test: $fails failed"
[ $fails = 0 ]
