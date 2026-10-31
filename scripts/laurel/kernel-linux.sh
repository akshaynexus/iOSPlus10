#!/bin/bash
# Build the Mi A3 (laurel_sprout) XNU kernel natively on Linux (no macOS, no Xcode).
#   scripts/bg.sh laurel-kernel scripts/laurel/kernel-linux.sh     (always in tmux)
#   PAGES=4k (default)  4 KiB pages, all 8 cores: Gold A73 = P cluster, Silver A53 = E cluster
#                       (topaz 0140/0141/0142, TOPAZ_4K=1; the Silver cores have no 16K granule)
#   PAGES=16k           16 KiB pages, the 4 Gold cores only (topaz CI default, fallback kernel)
#   AUDIT=1 ...   apply every patch and list the ones that fail (no build)
#   CLEAN=1 ...   also drop the cached toolchain, SDK and host tools
#
# Recipe: external/ios-sweet-linux (myh120405) builds the ios-sweet SWEET kernel on Ubuntu with
# stock clang + the theos cctools ld64 + MacOSX13.3.sdk + generated DriverKit (iig) stubs. topaz
# (external/ios-topaz) is the same xnu tag (xnu-8796.141.3, MACOS_VERSION=13.5) and the same
# MACHINE_CONFIG=SWEET, so its scripts run unchanged with another patch directory:
#   patches = external/ios-topaz/xnu/patches/*  +  patches/laurel/xnu/*.patch (our Mi A3 deltas, 2000-*)
# Linux-only compiler fixes: the generic ones of ios-sweet-linux (0001 kalloc, 0003 sha256 asm)
# + patches/laurel/xnu-linux-fixes/*.patch. Patches that dxb also skips: patches/laurel/known-skips.txt.
# Work tree: out/laurel-kernel/ (git-ignored). Output: out/laurel-kernel/out/kernel.development.sweet.
# Host needs: clang lld llvm flex bison m4 perl python3 autoconf automake libtool curl xz git
#             libxml2 uuid headers (util-linux), pkg-config, jq, file.
set -euo pipefail
. "$(dirname "$0")/../lib/env.sh"
W=$OUT/laurel-kernel
SRC=$EXT/ios-sweet-linux
TOPAZ=$EXT/ios-topaz
THEOS_SHA=6e7b8c40e0f5f9f5b2377800dc1e42cd2560d24a
# theos' own installer (bin/install-theos) takes this toolchain from L1ghtmann/llvm-project; the release has
# no checksum, so ours is pinned (first download 2026-10-31; tar list checked: only linux/iphone/..., no
# absolute or ../ paths, no device files). A changed file stops the build.
TOOLCHAIN_URL=https://github.com/L1ghtmann/llvm-project/releases/download/test-210562a/iOSToolchain-x86_64.tar.xz
TOOLCHAIN_SHA256=a72a7a577e2fbe2838b6b5e9c72034fa7d114af96f0e1d4b016f18730ce4056e

for d in "$SRC/linux" "$TOPAZ/xnu/patches"; do
  [ -d "$d" ] || { echo "kernel-linux: missing $d: scripts/setup/get-references.sh ios-sweet-linux ios-topaz" >&2; exit 1; }
done
[ "$(uname -s)" = Linux ] || { echo "kernel-linux: Linux only (macOS: scripts/kernel/build-local.sh recipe)" >&2; exit 1; }
[ "$(uname -m)" = x86_64 ] || { echo "kernel-linux: the pinned theos toolchain is x86_64" >&2; exit 1; }
for t in clang flex bison m4 perl python3 autoreconf automake curl xz git jq file make; do
  command -v $t >/dev/null || { echo "kernel-linux: missing host tool $t" >&2; exit 1; }
done

[ "${CLEAN:-0}" = 1 ] && rm -rf "${W:?}"
mkdir -p "$W"
# the scripts find everything relative to TOP=$W: a fresh copy of linux/ every run,
# deps/ theos/ (toolchain, SDK, host tools) are kept between runs
rm -rf "$W/linux" "$W/patches"
cp -R "$SRC/linux" "$W/linux"
rm -f "$W/linux/fixes/"*.patch
cp "$SRC/linux/fixes/0001-kalloc-stock-clang-void-ptr.patch" "$SRC/linux/fixes/0003-corecrypto-sha256-asm-operands.patch" "$W/linux/fixes/"
cp "$REPO"/patches/laurel/xnu-linux-fixes/*.patch "$W/linux/fixes/" 2>/dev/null || true
cp "$REPO/patches/laurel/known-skips.txt" "$W/linux/known-skips.txt"
# ARMv8.0: libfirehose_kernel.a (kernel os_log buffer) must be built for cortex-a53 like the kernel
# (topaz xnu.yml:60-62). ios-sweet-linux builds it with clang's default, which emits LSE atomics
# and LDAPR; the Kryo 260 traps on them at the first kernel log write.
sed -i 's|xnu-clang -arch arm64 -c -Os -mkernel -nostdinc -fno-builtin|xnu-clang -arch arm64 -mcpu=cortex-a53 -c -Os -mkernel -nostdinc -fno-builtin|' "$W/linux/setup-deps.sh"
grep -q 'mcpu=cortex-a53 -c -Os -mkernel' "$W/linux/setup-deps.sh" || { echo "kernel-linux: cannot set -mcpu for libfirehose" >&2; exit 1; }
fh=$W/deps/sdk/MacOSX13.3.xnu.sdk/usr/local/lib/kernel/libfirehose_kernel.a
[ -f "$fh.a53" ] || rm -f "$fh"   # a library from before this fix: build it again

mkdir -p "$W/patches"
cp "$TOPAZ"/xnu/patches/*.patch "$TOPAZ"/xnu/patches/*.sh "$W/patches/"
cp "$REPO"/patches/laurel/xnu/*.patch "$W/patches/" 2>/dev/null || true
echo "kernel-linux: topaz $(git -C "$TOPAZ" rev-parse --short HEAD), $(ls "$W"/patches/*.patch | wc -l) patches, $(ls "$REPO"/patches/laurel/xnu/*.patch 2>/dev/null | wc -l) of them laurel"

export TOP=$W PATCHES_DIR=$W/patches THEOS=$W/theos MACHINE_CONFIG=SWEET KERNEL_CONFIG=DEVELOPMENT JOBS=$NPROC
PAGES=${PAGES:-4k}
case "$PAGES" in
4k)  export TOPAZ_4K=1 ;;   # makedefs/MakeInc.def (0140) adds -DTOPAZ_4K=1 for SWEET
16k) unset TOPAZ_4K ;;
*)   echo "kernel-linux: PAGES must be 4k or 16k" >&2; exit 1 ;;
esac
echo "kernel-linux: PAGES=$PAGES ($([ "$PAGES" = 4k ] && echo '8 cores, P+E clusters' || echo '4 Gold cores'))"
XNU_TAG=xnu-8796.141.3
LOGD=$W/logs; mkdir -p "$LOGD"
T0=$(date +%s)
# step NAME CMD...: run, print wall time, CPU time and how many cores were busy on average
step() {
  local name=$1; shift
  local t=$(date +%s.%N) c0 c1
  c0=$(awk '{print $14+$15+$16+$17}' /proc/$$/stat)
  "$@"
  local rc=$?
  c1=$(awk '{print $14+$15+$16+$17}' /proc/$$/stat)
  awk -v n="$name" -v t="$t" -v now="$(date +%s.%N)" -v c="$((c1 - c0))" -v hz="$(getconf CLK_TCK)" -v cores="$NPROC" -v rc=$rc \
    'BEGIN{w=now-t; u=c/hz; printf "kernel-linux: step %-10s %6.1f s wall, %7.1f s cpu, %4.1f of %d cores busy%s\n", n, w, u, (w>0?u/w:0), cores, (rc?" FAILED rc=" rc:"")}'
  return $rc
}
# tolog LOG CMD...: run CMD with its output in LOG (step's own line stays on the console)
tolog() { local l=$1; shift; "$@" > "$l" 2>&1; }
# run PIDs: wait for every background job, fail if one failed
waitall() { local rc=0 p; for p in "$@"; do wait "$p" || rc=1; done; return $rc; }

get_theos() {
  [ -x "$THEOS/toolchain/linux/iphone/bin/ld" ] && return 0
  rm -rf "$THEOS"
  git init -q "$THEOS"
  git -C "$THEOS" fetch -q --depth 1 https://github.com/theos/theos.git "$THEOS_SHA"
  git -C "$THEOS" checkout -q FETCH_HEAD
  mkdir -p "$THEOS/toolchain" "$W/dl"
  local tc=$W/dl/iOSToolchain-x86_64.tar.xz
  [ -f "$tc" ] || curl -fsSL --retry 5 -o "$tc" "$TOOLCHAIN_URL"
  echo "$TOOLCHAIN_SHA256  $tc" | sha256sum -c - || { echo "kernel-linux: toolchain checksum changed" >&2; return 1; }
  tar -xJf "$tc" -C "$THEOS/toolchain/"
}
# local mirror of the one xnu tag: apply-xnu clones from it (no GitHub round trip per build)
get_xnu() {
  local m=$W/cache/xnu.git
  if ! git -C "$m" rev-parse -q --verify "refs/tags/$XNU_TAG" >/dev/null 2>&1; then
    rm -rf "$m"; git init -q --bare "$m"
    git -C "$m" fetch -q --depth 1 https://github.com/apple-oss-distributions/xnu.git "refs/tags/$XNU_TAG:refs/tags/$XNU_TAG"
  fi
}
cd "$W"
export XNU_REPO=file://$W/cache/xnu.git

# phase 1 (parallel): toolchain, macOS SDK, xnu source
fetch_all() {
  get_theos > "$LOGD/theos.log" 2>&1 & local a=$!
  bash linux/setup-sdk.sh > "$LOGD/sdk.log" 2>&1 & local b=$!
  get_xnu > "$LOGD/xnu-fetch.log" 2>&1 & local c=$!
  waitall $a $b $c || { tail -5 "$LOGD/theos.log" "$LOGD/sdk.log" "$LOGD/xnu-fetch.log" >&2; return 1; }
}
step fetch fetch_all || exit 1

if [ "${AUDIT:-0}" = 1 ]; then
  STRICT_PATCHES=1 bash linux/apply-xnu.sh 2>&1 | tee "$W/apply-audit.log"
  exit "${PIPESTATUS[0]}"
fi

# phase 2 (parallel): patch the xnu tree | build the host tools and the SDK overlay (stage 1 does
# not read the xnu tree; apply-xnu picks its SDK once at start, so the overlay cannot race it)
apply_and_deps() {
  bash linux/apply-xnu.sh > "$W/apply-xnu.log" 2>&1 & local a=$!
  bash linux/setup-deps.sh --stage1 > "$LOGD/stage1.log" 2>&1 & local b=$!
  local rc=0
  wait $a || { rc=1; grep -E "ERROR|does not apply" "$W/apply-xnu.log" | head -20 >&2; }
  wait $b || { rc=1; tail -20 "$LOGD/stage1.log" >&2; }
  grep -E "applied=" "$W/apply-xnu.log"
  return $rc
}
step patch+deps apply_and_deps || exit 1

# compiler cache: a second build with the same sources only links. ccache is optional.
if command -v ccache >/dev/null; then
  mkdir -p "$W/ccache-bin"
  for c in xnu-clang xnu-clang++; do
    printf '#!/bin/sh\nexec ccache "%s" "$@"\n' "$W/linux/bin/$c" > "$W/ccache-bin/$c"; chmod +x "$W/ccache-bin/$c"
  done
  export PATH=$W/ccache-bin:$PATH CCACHE_DIR=${CCACHE_DIR:-$W/ccache} CCACHE_BASEDIR=$W CCACHE_NOHASHDIR=1 \
    CCACHE_SLOPPINESS=include_file_mtime,include_file_ctime,time_macros,file_macro,pch_defines \
    CCACHE_COMPILERCHECK="string:$(clang --version | head -1)-$(cat "$W/linux/bin/xnu-clang" | sha256sum | cut -c1-16)"
  ccache -M 8G >/dev/null; ccache -z >/dev/null
  echo "kernel-linux: ccache on ($CCACHE_DIR)"
else
  echo "kernel-linux: ccache not installed: full compile every build (install ccache for fast rebuilds)"
fi
# stage 2 exports the headers itself (only when libfirehose is missing); the kernel build exports
# them again as its first target, so no separate exporthdrs step
step firehose tolog "$LOGD/stage2.log" bash linux/setup-deps.sh --stage2 || { tail -20 "$LOGD/stage2.log"; exit 1; }
touch "$fh.a53"
rm -f "$W/build.log"
step kernel tolog "$LOGD/kernel-make.log" bash linux/build-with-iig.sh || true
command -v ccache >/dev/null && ccache -s | grep -iE "hits|misses" | head -3
echo "kernel-linux: total $(( $(date +%s) - T0 )) s"

K=$W/xnu-src/xnu-8796.141.3/BUILD/obj/DEVELOPMENT_ARM64_SWEET/kernel.development.sweet
if [ ! -s "$K" ]; then
  echo "kernel-linux: no kernel; first errors:" >&2
  grep -n -m 40 -E "error:|Undefined symbols|symbol\(s\) not found" "$W/build.log" >&2 || true
  exit 1
fi
# the variant must be the one asked for: 0142 (sweet_early_map_final, sweet_early_fb_mapped) exists only with TOPAZ_4K
has4k=0
# (no grep -q: with pipefail its early exit SIGPIPEs llvm-nm and the test fails)
llvm-nm "$K.unstripped" 2>/dev/null | grep -E ' _sweet_early_(map_final|fb_mapped)$' >/dev/null && has4k=1
if { [ "$PAGES" = 4k ] && [ $has4k = 0 ]; } || { [ "$PAGES" = 16k ] && [ $has4k = 1 ]; }; then
  echo "kernel-linux: built kernel is not the PAGES=$PAGES variant (TOPAZ_4K symbol: $has4k)" >&2; exit 1
fi
mkdir -p "$W/out"
O=$W/out/kernel.development.sweet.$PAGES
cp "$K" "$O"
[ -s "$K.unstripped" ] && cp "$K.unstripped" "$O.unstripped"
ln -sfn "$(basename "$O")" "$W/out/kernel.development.sweet"
(cd "$W/out" && sha256sum kernel.development.sweet.4k* kernel.development.sweet.16k* 2>/dev/null > SHA256SUMS || true)
file "$O"
# ARMv8.0 check (topaz README): no LSE / RCpc left except the K256 SHA table
if command -v llvm-objdump >/dev/null; then
  pat='\t(cas\w*|ldadd\w*|ldset\w*|ldclr\w*|ldeor\w*|swp\w*|ldapr\w*)\s'
  n=$(llvm-objdump -d --mattr=+v8.5a "$O" | grep -cP "$pat" || true)
  echo "kernel-linux: LSE/RCpc instructions in the kernel: $n (must be 0: Kryo 260 is ARMv8.0)"
  if [ "$n" != 0 ]; then
    llvm-objdump -d --mattr=+v8.5a "$O.unstripped" |
      grep -P "^[0-9a-f]+ <|$pat" | grep -B1 -P "$pat" | grep -P '^[0-9a-f]+ <' | sort -u >&2 || true
    echo "kernel-linux: kernel has ARMv8.1+ instructions (functions above); not usable on the Mi A3" >&2
    mv "$O" "$O.has-lse"; rm -f "$W/out/kernel.development.sweet"
    exit 1
  fi
else
  echo "kernel-linux: llvm-objdump missing: cannot check for LSE instructions" >&2; exit 1
fi
echo "kernel-linux: $O"
