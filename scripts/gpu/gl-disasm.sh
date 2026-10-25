#!/bin/sh
# Disassemble the iOS 16 (20H392) OpenGL ES images of the shared cache for the "GL driver loading"
# research (docs/notes.md). Needs `ipsw` (brew install blacktop/tap/ipsw) and a mounted root.
#   scripts/bg.sh gl-disasm scripts/gpu/gl-disasm.sh [ROOT] [IMAGE...]
# -> out/gpu/re/IMAGE.s (+ IMAGE.strings.txt, IMAGE.symbols.txt). The root can be read-only:
# the address-to-symbol cache is written to out/gpu/re/dsc.a2s.
set -eu
. "$(cd "$(dirname "$0")" && pwd)/env.sh"
ROOT=${1:-/tmp/iosroot-ro}
[ "$#" -gt 0 ] && shift
DSC=$ROOT/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64
[ -f "$DSC" ] || { echo "no shared cache at $DSC" >&2; exit 1; }
RE=$G/re
mkdir -p "$RE"
[ -f "$RE/dsc.a2s" ] || { [ -f "$OUT/metal/dsc.a2s" ] && cp "$OUT/metal/dsc.a2s" "$RE/dsc.a2s"; } || true
[ "$#" -gt 0 ] || set -- libGFXShared.dylib OpenGLES GLEngine AppleMetalGLRenderer libGLImage.dylib \
	libCoreVMClient.dylib libGPUSupportMercury.dylib
one() {
	ipsw dyld macho "$DSC" "$1" --strings > "$RE/$1.strings.txt" 2>&1 || true
	ipsw dyld macho "$DSC" "$1" --symbols > "$RE/$1.symbols.txt" 2>&1 || true
	ipsw dyld disass "$DSC" --image "$1" --cache "$RE/dsc.a2s" --demangle > "$RE/$1.s" 2>&1
	echo "$1: $(wc -l < "$RE/$1.s") lines"
}
# the first run builds dsc.a2s; the others run in parallel after it
first=$1; shift
one "$first"
for i in "$@"; do one "$i" & done
wait
