# Shared settings of the Metal path (scripts/metal/*.sh). Pins: docs/metal-design.md "Versions".
# Change a pin only together with that table.
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../lib" && pwd)/env.sh"

METAL=$REPO/userland/metal                 # our sources
MOUT=$OUT/metal                            # all build products
MSRC=$MOUT/src                             # fetched sources

# metal2vulkan: AIR -> SPIR-V translator + Metal object model on Vulkan (Rust; GPL-2.0+ OR LGPL-3.0+)
M2V_URL=https://github.com/steelbrain/metal2vulkan.git
M2V_COMMIT=720ef1ce
M2V=$MSRC/metal2vulkan
RUST_TOOLCHAIN=1.98.0

# ios-flame (NWylynko/ios-flame, MIT): the iOS 16.7.16 20H392 Metal frontend + bridge that drew the Pixel 4
# home screen through metal2vulkan + Turnip (HANDOFF.md 2026-10-22). Read from the submodule's git objects.
FLAME=$EXT/ios-flame
FLAME_COMMIT=745c434
FLAME_SRC=$MSRC/flame

# Turnip (libvulkan_freedreno.dylib): the one staged copy, written and checked by scripts/gpu/turnip-build.sh.
# Override with TURNIP_DYLIB=... when it lives elsewhere.
TURNIP_DYLIB=${TURNIP_DYLIB:-$OUT/gpu/turnip/libvulkan_freedreno.dylib}

IOS_MIN=${IOS_MIN:-16.0}
PLUGIN_NAME=${PLUGIN_NAME:-NegroniMetal}         # bundle /System/Library/Extensions/NegroniMetal.bundle
PLUGIN_CLASS=${PLUGIN_CLASS:-NegroniMTLDevice}   # NSPrincipalClass + kernel MetalPluginClassName

case "$(uname -s)" in
Darwin)
  SDK=${SDK:-$(xcrun --sdk iphoneos --show-sdk-path)}
  ;;
*)
  SDK=${SDK:?set SDK to an iPhoneOS.sdk directory (docs/metal-design.md, Linux)}
  ;;
esac
