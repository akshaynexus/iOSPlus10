# Shared settings of the Mi A3 (laurel_sprout) GPU user-space build, sourced by scripts/laurel/gpu-*.sh,
# mesa-linux.sh and root-add-gpu.sh. Linux x86_64 (no Mac): stock clang + the theos cctools ld64 + iPhoneOS16.5.sdk.
# Pins: docs/laurel_sprout/gpu.md "Versions". Change them only together with that table.
. "$(cd "$(dirname "$0")/../lib" && pwd)/env.sh"

TOPAZ=$EXT/ios-topaz                     # userland/gpu (eagl, gl_osmesa, topaz_inject, bbd_wrap), userland/mesa
SCION=$EXT/hackios-scion                 # userland/mkeagl.py + src/eagl_slots.txt (the EAGL table generator)
G=$OUT/laurel/gpu                        # every build product of the GPU user space
DL=$G/dl                                 # downloads (untrusted until the hash matches)
DEPS=$G/deps                             # SDK, Python venv

MESA_VERSION=25.0.7                      # = topaz userland/mesa/mk-mesa-mac.sh and hackios-scion tools/mk-mesa.sh
MESA_SHA256=592272df3cf01e85e7db300c449df5061092574d099da275d19e97ef0510f8a6
MESA_URL=https://archive.mesa3d.org/mesa-$MESA_VERSION.tar.xz

# iPhoneOS16.5.sdk from github.com/theos/sdks (hackios-scion xnu-deps/setup.sh fetches the same one, unpinned).
SDKS_URL=https://github.com/theos/sdks.git
SDKS_COMMIT=0222fd5413cf4b9af096f37b4621afa2688572f7   # HEAD on 2026-11-01
SDK_DEFAULT=$DEPS/sdks/iPhoneOS16.5.sdk
SDK=${SDK:-$SDK_DEFAULT}
IOS_MIN=16.0
# ARMv8.0 only (Kryo 260 Gold A73 + Silver A53: no LSE, no RCpc, no PAC). The kernel emulates LSE/LDAPR in
# user space (topaz 0081) but a trap per atomic is slow; -mcpu=cortex-a53 emits none.
# Tuning (measured, scripts/laurel/cpu-tune-mca.sh, llvm-mca): -mtune=cortex-a73 makes the hot blocks 1.9-2.2x slower
# on the A53 model and at most 2.4 % faster on the A73 model, so the A53 tuning of -mcpu=cortex-a53 stays.
# -mfix-cortex-a53-835769: the A53 erratum workaround (a NOP between a load/store and a 64-bit multiply-accumulate),
# as Android's arm64 toolchains do by default [I: the Kryo 260 Silver is an A53 r0p4 derivative].
CPU_FLAGS="-mcpu=cortex-a53 -mfix-cortex-a53-835769"
# Debug info: built with -g, kept as .dSYM in $G/dsym (dsymutil), the installed binaries are stripped.
DSYM=$G/dsym

# The theos cctools toolchain (ld64, ldid, install_name_tool, nm) that scripts/laurel/kernel-linux.sh fetches
# (pinned there: theos 6e7b8c4 + L1ghtmann iOSToolchain test-210562a, sha256 checked).
THEOS=${THEOS:-$OUT/laurel-kernel/theos}
TC=$THEOS/toolchain/linux/iphone/bin
LD64=$TC/ld
LDID=$TC/ldid
INSTALL_NAME_TOOL=$TC/install_name_tool

CLANG=${CLANG:-clang}
AR=${AR:-llvm-ar}
RANLIB=${RANLIB:-llvm-ranlib}
STRIP=${STRIP:-llvm-strip}
NM=${NM:-llvm-nm}

# On-phone paths (the kernel and the root use the same ones):
#   /topaz/lib/libOSMesa.8.dylib        Mesa (freedreno + softpipe), install name from the topaz recipe
#   /topaz/lib/libtopaz-gl.dylib        eagl.c + gl_osmesa.c: OpenGL ES behind EAGLContext
#   /topaz/lib/libtopaz-inject.dylib    inserted into backboardd: loads libtopaz-gl when RedwoodGPU is there
#   /usr/libexec/backboardd             bbd_wrap (adds the loader, execs /usr/libexec/real/backboardd)
#   /usr/share/firmware/laurel/         a610_zap.mdt + a610_zap.bNN + a630_sqe.fw (from the phone's own vendor)
PREFIX=/topaz
FW_DIR_ON_PHONE=/usr/share/firmware/laurel

gpu_die() { echo "$(basename "$0"): $*" >&2; exit 1; }

gpu_need_toolchain() {
  [ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ] || gpu_die "Linux x86_64 only (the pinned theos toolchain is x86_64)"
  [ -x "$LD64" ] && [ -x "$LDID" ] || gpu_die "no theos toolchain at $THEOS: run scripts/laurel/kernel-linux.sh first (it fetches it)"
  for t in "$CLANG" "$AR" "$RANLIB" "$STRIP" "$NM" git curl python3; do
    command -v "$t" >/dev/null || gpu_die "missing host tool $t"
  done
}

# iPhoneOS16.5.sdk: sparse, blob-filtered clone of theos/sdks at the pinned commit (about 220 MB)
gpu_fetch_sdk() {
  [ -d "$SDK/usr/include" ] && return 0
  # a user-given SDK (SDK=...) is used as it is: nothing is fetched or linked outside out/
  [ "$SDK" = "$SDK_DEFAULT" ] || gpu_die "SDK=$SDK has no usr/include"
  local r=$DEPS/sdks-git
  rm -rf "$r"
  mkdir -p "$DEPS/sdks"
  git init -q "$r"
  git -C "$r" remote add origin "$SDKS_URL"
  git -C "$r" config core.sparseCheckout true
  git -C "$r" sparse-checkout set --no-cone /iPhoneOS16.5.sdk/
  git -C "$r" fetch -q --depth 1 --filter=blob:none origin "$SDKS_COMMIT"
  git -C "$r" checkout -q FETCH_HEAD
  [ "$(git -C "$r" rev-parse HEAD)" = "$SDKS_COMMIT" ] || gpu_die "theos/sdks: wrong commit"
  ln -sfn "$r/iPhoneOS16.5.sdk" "$SDK_DEFAULT"
  [ -d "$SDK/usr/include" ] || gpu_die "theos/sdks: no iPhoneOS16.5.sdk/usr/include"
}

# Python venv with Mako/PyYAML/packaging for Mesa's code generators (host meson + ninja are used). Versions and
# sha256 of every PyPI file: scripts/laurel/gpu-requirements.txt (pip --require-hashes, wheels only: no build step).
REQS=$REPO/scripts/laurel/gpu-requirements.txt
gpu_venv() {
  local want
  want=$(gpu_sha256 < "$REQS")
  [ -x "$DEPS/venv/bin/python3" ] && [ "$(cat "$DEPS/venv/.laurel-reqs" 2>/dev/null)" = "$want" ] && return 0
  rm -rf "$DEPS/venv"
  python3 -m venv "$DEPS/venv"
  "$DEPS/venv/bin/pip" -q install --require-hashes --only-binary :all: --no-deps -r "$REQS"
  echo "$want" > "$DEPS/venv/.laurel-reqs"
}

# sha256 of files, "HASH  NAME" lines (Linux sha256sum, macOS shasum)
gpu_sha256_files() {
  if command -v sha256sum >/dev/null; then sha256sum -- "$@"; else shasum -a 256 -- "$@"; fi
}
# sha256 of stdin, hex only (Linux sha256sum, macOS shasum)
gpu_sha256() {
  if command -v sha256sum >/dev/null; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi
}

# compile + link one iOS arm64 Mach-O: gpu_cc OUT [clang args...]
gpu_cc() {
  local out=$1; shift
  "$CLANG" -target "arm64-apple-ios$IOS_MIN" -isysroot "$SDK" $CPU_FLAGS --ld-path="$LD64" \
    -fno-stack-check -O2 -g -Wall -Wno-unused-function -o "$out" "$@"
}

# ARMv8.0 check on a Mach-O: no instruction newer than ARMv8.0 + CRC + AES/SHA (LSE, RCpc, RDM, FP16, dot product,
# v8.3 PAC/JSCVT/FCMA, v8.4 flag ops, SHA3/SM, BF16/I8MM, MTE, SVE): scripts/laurel/armv80-check.py (fails on any)
gpu_check_v80() {
  python3 -I "$REPO/scripts/laurel/armv80-check.py" "$@"
}

# gpu_dsym FILE: the debug info of FILE (built with -g) into $DSYM/NAME.dSYM, then FILE is stripped (local symbols)
gpu_dsym() {
  mkdir -p "$DSYM"
  rm -rf "$DSYM/$(basename "$1").dSYM"
  if [ -d "$1.dSYM" ]; then
    mv "$1.dSYM" "$DSYM/"            # clang made it (compile + link in one step with -g, as on macOS)
  else
    dsymutil "$1" -o "$DSYM/$(basename "$1").dSYM" 2>/dev/null || echo "$(basename "$0"): note: no dSYM for $(basename "$1")"
  fi
  "$STRIP" -x "$1"
}
