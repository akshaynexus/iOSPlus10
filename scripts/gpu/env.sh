# Shared settings of the GPU user-space build (negronigl.dylib), sourced by scripts/gpu/*.sh.
# Pins: docs/gpu-userland.md "Versions". Change them only together with that table.
. "$(cd "$(dirname "$0")/../lib" && pwd)/env.sh"

MESA_VERSION=25.0.7
MESA_SHA256=592272df3cf01e85e7db300c449df5061092574d099da275d19e97ef0510f8a6
MESA_URL=https://archive.mesa3d.org/mesa-$MESA_VERSION.tar.xz
# freedreno-on-Darwin patch set (MIT): oosexgang/hackios-xnu-userland, the commit that
# external/slop/.github/workflows/gpu-mesa.yml pins. Read from the submodule's git objects with
# `git show COMMIT:PATH`, so the submodule checkout can be at any later commit.
HACKIOS=$EXT/hackios-xnu-userland
HACKIOS_COMMIT=b4c5513e2df93689895d21fd3b93b723a7bcfdd3
HACKIOS_PATCHES="freedreno-darwin ir3-round-default ir3-shift-split ir3-ssbo-subdword"

IOS_MIN=${IOS_MIN:-16.0}
NGL=$REPO/userland/negronigl            # our sources
# The one Turnip-on-Darwin patch (userland/turnip owns it; scripts/gpu/turnip-build.sh applies every patch of that
# directory). The GL tree gets this one too, so both trees carry the same Darwin changes (meson.build, tu_knl.cc).
TURNIP_DARWIN_PATCH=$REPO/userland/turnip/mesa-patches/0001-turnip-darwin.patch
G=$OUT/gpu                               # all build products
DL=$G/dl                                 # downloaded archive (untrusted until the hash matches)
MESA_SRC=$G/mesa-$MESA_VERSION           # patched Mesa tree
MESA_BUILD=$G/mesa-build-ios             # meson build directory (iOS arm64)
VENV=$G/venv                             # meson + mako + pyyaml + packaging (uv)

case "$(uname -s)" in
Darwin)
  SDK=${SDK:-$(xcrun --sdk iphoneos --show-sdk-path)}
  CLANG=${CLANG:-$(xcrun --sdk iphoneos -f clang)}
  CLANGXX=${CLANGXX:-$(xcrun --sdk iphoneos -f clang++)}
  AR=${AR:-$(xcrun --sdk iphoneos -f ar)}
  RANLIB=${RANLIB:-$(xcrun --sdk iphoneos -f ranlib)}
  STRIP=${STRIP:-$(xcrun --sdk iphoneos -f strip)}
  BISON_DIR=$(brew --prefix bison 2>/dev/null)/bin   # macOS bison 2.3 is too old for ir3's grammar
  [ -x "$BISON_DIR/bison" ] && PATH=$BISON_DIR:$PATH
  ;;
*)
  # Linux: clang + lld + llvm tools and an iPhoneOS SDK copied from a Mac (docs/gpu-userland.md)
  SDK=${SDK:?set SDK to an iPhoneOS.sdk directory}
  CLANG=${CLANG:-clang}
  CLANGXX=${CLANGXX:-clang++}
  AR=${AR:-llvm-ar}
  RANLIB=${RANLIB:-llvm-ranlib}
  STRIP=${STRIP:-llvm-strip}
  ;;
esac
TARGET="-target arm64-apple-ios$IOS_MIN"
export PATH="$VENV/bin:$PATH"
