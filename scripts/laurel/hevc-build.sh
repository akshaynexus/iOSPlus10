#!/bin/bash
# Build the HEVC decoder plug-in of the Mi A3 iOS 16 root + the host test of the same code. docs/laurel_sprout/hevc.md.
#   scripts/bg.sh heic-build scripts/laurel/hevc-build.sh
# Linux x86_64: stock clang + the theos ld64 + iPhoneOS16.5.sdk (scripts/laurel/gpu-env.sh; SDK= and THEOS= may point at another checkout).
# 1. FFmpeg source: git tag at a pinned commit in out/laurel/hevc/src, never changed (LGPL: no --enable-gpl, THIRD_PARTY_NOTICES.md).
# 2. libavcodec + libavutil with only the hevc decoder, twice: arm64-apple-ios (ARMv8.0: NEON yes, dotprod/i8mm/sve no) and host (C code).
# 3. out/laurel/hevc/HEVCH8.videodecoder: Mach-O dylib, one export (_HEVCH8Register), ad hoc signed, stripped, dSYM kept.
# 4. scripts/laurel/armv80-check.py (no instruction newer than ARMv8.0) + hevc-check-imports.py (every import is in the 20H392 cache): each fails the build.
# 5. out/laurel/hevc/host/hevc-test (scripts/laurel/hevc-test.py runs it).
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/gpu-env.sh"
FF_VERSION=7.1.1
FF_COMMIT=db69d06eeeab4f46da15030a80d539efb4503ca8     # tag n7.1.1 of FFmpeg/FFmpeg
FF_URL=https://github.com/FFmpeg/FFmpeg.git
H=$OUT/laurel/hevc
S=$H/src/ffmpeg-$FF_VERSION
SRC=$REPO/userland/laurel/hevc
gpu_need_toolchain
gpu_fetch_sdk
mkdir -p "$H/src" "$H/host"
if [ ! -f "$S/configure" ] || [ "$(git -C "$S" rev-parse HEAD 2>/dev/null)" != "$FF_COMMIT" ]; then
  rm -rf "$S"
  git init -q "$S"
  git -C "$S" remote add origin "$FF_URL"
  git -C "$S" fetch -q --depth 1 origin "$FF_COMMIT"
  git -C "$S" checkout -q FETCH_HEAD
  [ "$(git -C "$S" rev-parse HEAD)" = "$FF_COMMIT" ] || gpu_die "ffmpeg: wrong commit"
fi
# Only what the hevc decoder needs. No GPL part, no network, no device, no autodetected library. --disable-all removes every component.
COMMON="--disable-all --disable-autodetect --disable-programs --disable-doc --disable-debug --disable-iconv --disable-zlib --enable-static --disable-shared \
 --enable-avcodec --enable-avutil --enable-decoder=hevc --enable-pthreads --disable-network --pkg-config-flags=--static"
ff_build() {   # NAME EXTRA-CONFIGURE-ARGS...
  local name=$1 p=$H/$1 stamp; shift
  stamp=$(printf '%s %s %s %s\n' "$FF_VERSION" "$COMMON" "$*" "$CPU_FLAGS" | gpu_sha256)
  [ "$(cat "$p/.built-from" 2>/dev/null)" = "$stamp" ] && [ -s "$p/lib/libavcodec.a" ] && return 0
  rm -rf "$p"; mkdir -p "$p/b"
  (cd "$p/b" && "$S/configure" --prefix="$p" $COMMON "$@" > configure.log 2>&1) || { tail -30 "$p/b/configure.log" 2>/dev/null; tail -30 "$p/b/ffbuild/config.log"; gpu_die "$name: configure failed"; }
  make -C "$p/b" -j"$NPROC" install > "$p/make.log" 2>&1 || { tail -30 "$p/make.log"; gpu_die "$name: make failed"; }
  echo "$stamp" > "$p/.built-from"
}
IOSCC="$CLANG -target arm64-apple-ios$IOS_MIN -isysroot $SDK $CPU_FLAGS"
ff_build ff-ios --enable-cross-compile --arch=aarch64 --cpu=generic --target-os=darwin --cc="$IOSCC" --as="$IOSCC" \
  --ar="$AR" --ranlib="$RANLIB" --nm="$NM" --strip="$STRIP" --enable-pic --disable-dotprod --disable-i8mm \
  --extra-cflags="-g -fno-stack-check -fvisibility=hidden -Wno-unused-command-line-argument" --extra-ldflags="--ld-path=$LD64"
ff_build ff-host --cc="$CLANG" --ar="$AR" --ranlib="$RANLIB" --nm="$NM" --strip="$STRIP" --disable-x86asm --disable-inline-asm --disable-asm
# the plug-in
OUTF=$H/HEVCH8.videodecoder
gpu_cc "$OUTF" -dynamiclib -std=gnu11 -Wextra -Wno-unused-parameter -Wno-multichar -Wno-four-char-constants -Wno-deprecated-declarations \
  -fvisibility=hidden -install_name /System/Library/VideoDecoders/HEVCH8.videodecoder -Wl,-exported_symbol,_HEVCH8Register \
  -I"$H/ff-ios/include" -I"$SRC" "$SRC/vt_plugin.c" "$SRC/hevc_core.c" "$H/ff-ios/lib/libavcodec.a" "$H/ff-ios/lib/libavutil.a" \
  -framework CoreFoundation -framework CoreMedia -framework CoreVideo
STRIP="$TC/strip" gpu_dsym "$OUTF"   # llvm-strip refuses ld64's LC_SEGMENT_SPLIT_INFO
"$LDID" -S "$OUTF"
gpu_check_v80 "$OUTF"
# imports against the real 20H392 cache: a missing one would make VideoToolbox skip this file without a word
APPLE=${APPLE:-$HOME/op10-apple}
CACHE=${CACHE:-$OUT/heic/re/dsc}
if [ ! -d "$CACHE" ] && [ -s "$APPLE/20H392/087-86593-047.dmg" ]; then
  mkdir -p "$OUT/heic/re/sys"
  ln -sf "$APPLE/20H392/087-86593-047.dmg" "$OUT/heic/re/sys.dmg"
  mountpoint -q "$OUT/heic/re/sys" || apfs-fuse -o ro "$OUT/heic/re/sys.dmg" "$OUT/heic/re/sys"
  CACHE=$OUT/heic/re/sys/root/System/Library/Caches/com.apple.dyld
fi
if [ -d "$CACHE" ]; then
  python3 -I "$REPO/scripts/laurel/hevc-check-imports.py" "$CACHE" "$OUTF"
else
  echo "hevc-build: note: no 20H392 cache here: imports not checked"
fi
exports=$("$NM" -gU "$OUTF" | awk '{print $3}' | paste -sd, -)
[ "$exports" = _HEVCH8Register ] || gpu_die "exports: $exports (wanted _HEVCH8Register only)"
# the host test: same core, C paths of FFmpeg
"$CLANG" -O2 -g -std=gnu11 -Wall -Wextra -Wno-unused-parameter -I"$H/ff-host/include" -I"$SRC" "$SRC/hevc-test.c" "$SRC/hevc_core.c" \
  "$H/ff-host/lib/libavcodec.a" "$H/ff-host/lib/libavutil.a" -lpthread -lm -o "$H/host/hevc-test"
(cd "$H" && gpu_sha256_files HEVCH8.videodecoder > SHA256SUMS)
ls -l "$OUTF"
echo "hevc-build: done: FFmpeg $FF_VERSION, $(cat "$H/SHA256SUMS" | cut -c1-16)..."
