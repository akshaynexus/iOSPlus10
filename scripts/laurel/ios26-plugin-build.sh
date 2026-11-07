#!/bin/bash
# Mi A3 iOS 26: the default stack's plug-in (metal2vulkan 219f013 + m2v-ios26 + flame-ios26, class NegroniMTLDeviceImpl, tree out/ios26/metal-impl) built and kept as one file for the bench: out/ios26/snap/NAME (+ NAME.dSYM). ios26-default-bench.sh PLUGIN=out/ios26/snap/NAME puts it as options/default for one run.
#   scripts/bg.sh plugin-NAME scripts/laurel/build-lock.sh plugin-NAME scripts/laurel/ios26-plugin-build.sh NAME [all|fetch|bridge|plugin|snap]
# fetch re-exports the sources and applies every patch (a patch that does not apply stops here); bridge is the iOS Rust build (fat LTO: about 12 min); plugin the bundle; snap the copy. Default all. Turnip is not rebuilt (scripts/laurel/ios26-metal-build.sh turnip).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
name=${1:?usage: $0 NAME [all|fetch|bridge|plugin|snap]}; what=${2:-all}
O=$REPO/out/ios26
export METAL_OUT=$O/metal-impl PLUGIN_CLASS=NegroniMTLDeviceImpl
step() { echo "$(date +%H:%M:%S) plugin-build $name: $*"; }
case "$what" in all|fetch) step fetch; "$HERE/ios26-metal-build.sh" fetch ;; esac
case "$what" in all|bridge) step bridge; "$HERE/ios26-metal-build.sh" bridge ;; esac
case "$what" in all|plugin) step plugin; "$HERE/ios26-metal-build.sh" plugin ;; esac
case "$what" in all|snap)
  B=$METAL_OUT/stage/System/Library/Extensions/NegroniMetal.bundle/NegroniMetal
  mkdir -p "$O/snap"
  cp "$B" "$O/snap/$name"
  rm -rf "$O/snap/$name.dSYM"; [ -d "$METAL_OUT/NegroniMetal.dSYM" ] && cp -a "$METAL_OUT/NegroniMetal.dSYM" "$O/snap/$name.dSYM"
  step "snap out/ios26/snap/$name $(sha256sum "$O/snap/$name" | cut -c1-16) $(stat -c %s "$O/snap/$name") bytes; LAUREL lines: $(strings "$O/snap/$name" | grep -o 'LAUREL [A-Z ]*:' | sort -u | tr '\n' ' ')" ;;
esac
