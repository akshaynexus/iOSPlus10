#!/bin/bash
# Mi A3 iOS 26: build and measure the render lowering thread (flame-ios26/0007 + m2v-ios26/0006): sources with every patch, the host encode bench on and off (NEGRONIMETAL_LOWERING=0), then the phone's plug-in as out/ios26/snap/NAME.
#   scripts/bg.sh lowering scripts/laurel/build-lock.sh lowering scripts/laurel/ios26-lowering-build.sh NAME
# Results: logs/encode-bench-NAME-on.txt, logs/encode-bench-NAME-off.txt, out/ios26/snap/NAME. Docs: docs/laurel_sprout/ios26-default-speed.md section 10.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
name=${1:?usage: $0 NAME}
"$HERE/ios26-plugin-build.sh" "$name" fetch
BENCH_NAME=$name-on "$HERE/ios26-encode-bench.sh" all 200,1800
BENCH_NAME=$name-off NEGRONIMETAL_LOWERING=0 "$HERE/ios26-encode-bench.sh" run 200,1800
"$HERE/ios26-plugin-build.sh" "$name" bridge
"$HERE/ios26-plugin-build.sh" "$name" plugin
"$HERE/ios26-plugin-build.sh" "$name" snap
