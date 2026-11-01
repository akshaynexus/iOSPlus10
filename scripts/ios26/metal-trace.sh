#!/bin/sh
# Resolved listings and class dumps of the 23F84 graphics images, for the compositor trace (docs/laurel_sprout/ios26-metal.md).
# Host only, read only. Output: out/ios26/metal-spi/ (Apple text: git-ignored). In tmux: scripts/bg.sh ios26-metal-trace scripts/ios26/metal-trace.sh
set -eu
. "$(dirname "$0")/../lib/env.sh"
T=${IOS26_TREE:-$HOME/op10-apple/ios26/23F84-n104ap/tree}
S=$OUT/ios26/metal-spi
IPSW=${IPSW:-$OUT/bin/ipsw}
mkdir -p "$S"
C=$T/cache
for lib in QuartzCore Metal IOGPU IOAccelerator IOSurface IOMobileFramebuffer MTLCompiler; do
  case $lib in MTLCompiler) continue ;; esac
  ( python3 -I "$REPO/scripts/laurel/dsc-image.py" "$C" lst "$lib" > "$S/$lib.lst.part" && mv "$S/$lib.lst.part" "$S/$lib.lst"
    echo "$lib: $(wc -l < "$S/$lib.lst") lines" ) &
done
wait
for p in /System/Library/Frameworks/Metal.framework/Metal /System/Library/Frameworks/QuartzCore.framework/QuartzCore \
         /System/Library/PrivateFrameworks/IOGPU.framework/IOGPU /System/Library/Extensions/AGXMetalA13.bundle/AGXMetalA13; do
  n=${p##*/}
  "$IPSW" class-dump "$C/dyld_shared_cache_arm64e" "$n" > "$S/$n.classdump.txt" 2>"$S/$n.classdump.log" || echo "class-dump $n: failed"
  echo "$n: $(wc -l < "$S/$n.classdump.txt") class-dump lines"
done
# every selector stub of the frameworks SpringBoard and the system UI load (fast: symbols only), for scripts/ios26/selector-gap.py
for lib in RenderBox IconRendering CoreUI CoreImage MPSCore MPSImage MetalKit MetalPerformanceShaders UIKitCore VFX VectorKit SwiftUICore SpringBoard SpringBoardFoundation SpriteKit \
    MPSNeuralNetwork CMImaging FrontBoard BaseBoardUI ClockKitUI PosterKit PosterBoardServices MaterialKit WebCore; do
  ( python3 -I "$REPO/scripts/laurel/dsc-image.py" "$C" syms "$lib" 2>/dev/null | grep 'objc_msgSend\$' > "$S/$lib.sel" || true; echo "$lib: $(wc -l < "$S/$lib.sel") selector stubs" ) &
done
wait
