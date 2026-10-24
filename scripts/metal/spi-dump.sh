#!/bin/bash
# Dump the Metal driver SPI from an iOS root (read-only): ObjC headers of Metal.framework,
# the AGX plugin, IOAccelerator, IOGPU, QuartzCore, plus imports/exports and strings that show
# how Metal.framework finds its plugin. Needs `ipsw` (brew install blacktop/tap/ipsw).
#   scripts/metal/spi-dump.sh ROOT_MOUNT [OUT]     (default OUT = out/metal/spi)
# Attach the root first: hdiutil attach -readonly -nobrowse -mountpoint M ~/op10-apple/ios16-root.img
# Run in tmux: scripts/bg.sh metal-spi scripts/metal/spi-dump.sh M
set -uo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
ROOT=${1:?root mount path}
OUT=${2:-$REPO/out/metal/spi}
DSC=$ROOT/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64
mkdir -p "$OUT"
libs=(
  /System/Library/Frameworks/Metal.framework/Metal
  /System/Library/Extensions/AGXMetalA11.bundle/AGXMetalA11
  /System/Library/PrivateFrameworks/IOAccelerator.framework/IOAccelerator
  /System/Library/PrivateFrameworks/IOGPU.framework/IOGPU
  /System/Library/Frameworks/QuartzCore.framework/QuartzCore
  /System/Library/Frameworks/MetalKit.framework/MetalKit
  /System/Library/PrivateFrameworks/GPUCompiler.framework/GPUCompiler
  /System/Library/Frameworks/IOSurface.framework/IOSurface
)
dump_one() {
  local lib=$1 n
  n=$(basename "$lib")
  ipsw class-dump "$DSC" "$lib" --headers --output "$OUT/headers/$n" > "$OUT/$n.classdump.log" 2>&1
  ipsw class-dump "$DSC" "$lib" > "$OUT/$n.classdump.txt" 2>&1
  ipsw dyld macho "$DSC" "$lib" --loads > "$OUT/$n.loads.txt" 2>&1
  ipsw dyld macho "$DSC" "$lib" --exports > "$OUT/$n.exports.txt" 2>&1
  ipsw dyld macho "$DSC" "$lib" --strings > "$OUT/$n.strings.txt" 2>&1
  ipsw dyld imports "$DSC" "$lib" > "$OUT/$n.importers.txt" 2>&1
  echo "done $n: $(wc -l < "$OUT/$n.classdump.txt") classdump lines"
}
for lib in "${libs[@]}"; do dump_one "$lib" & done
wait
# Which dylibs in the cache live in /System/Library/Extensions (Metal/GL plugins)?
ipsw dyld info "$DSC" --dylibs > "$OUT/dsc-dylibs.txt" 2>&1
grep -i -E "Extensions/|Metal|IOGPU|IOAccel" "$OUT/dsc-dylibs.txt" > "$OUT/dsc-gpu-dylibs.txt"
echo "all done -> $OUT"
