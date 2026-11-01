#!/bin/bash
# Host test of the IOSurface format decoders (userland/laurel/gpu/surface_formats.c). macOS + Linux, a few seconds, no phone.
set -euo pipefail
here=$(cd "$(dirname "$0")/../.." && pwd)
s=$here/userland/laurel/gpu
mkdir -p "$here/out/rend"
${CC:-cc} -std=c11 -Wall -Wextra -O1 -fsanitize=address,undefined -I"$s" "$s/tests/surface_formats_test.c" "$s/surface_formats.c" -lm -o "$here/out/rend/surface-formats-test"
"$here/out/rend/surface-formats-test"
