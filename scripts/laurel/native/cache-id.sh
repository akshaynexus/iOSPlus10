#!/bin/sh
# The name of the native stack's disk cache: a hash of what its compile path is made from. A new value starts an empty cache on the phone. Prints 16 hex digits.
#   scripts/laurel/native/cache-id.sh REPO METAL2VULKAN_DIR MESA_DIR
# In the hash: the SPIR-V to ir3 pass, the bridge's compile path, the translator's sources, Mesa's ir3 and NIR sources, by name, size and time.
set -eu
R=$1; M=$2; S=$3
{
  sha256sum "$R/userland/laurel/metal-native/shader/nmn_shader.c" "$R/userland/laurel/metal-native/shader/nmn_shader.h" "$R/userland/laurel/metal-native/bridge/src/compile.rs" | cut -d' ' -f1
  find "$M/crates/metal2vulkan/src" -type f -printf '%P %s\n' | LC_ALL=C sort
  find "$S/src/freedreno/ir3" "$S/src/compiler/nir" -type f -printf '%P %s\n' | LC_ALL=C sort
} | sha256sum | cut -c1-16
