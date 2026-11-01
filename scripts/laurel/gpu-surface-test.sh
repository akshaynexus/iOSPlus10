#!/bin/bash
# Host test of the IOSurface format decoders (userland/laurel/gpu/surface_formats.c). macOS + Linux, a few seconds, no phone.
set -euo pipefail
here=$(cd "$(dirname "$0")/../.." && pwd)
s=$here/userland/laurel/gpu
mkdir -p "$here/out/rend"
${CC:-cc} -std=c11 -Wall -Wextra -O1 -fsanitize=address,undefined -I"$s" "$s/tests/surface_formats_test.c" "$s/surface_formats.c" -lm -o "$here/out/rend/surface-formats-test"
"$here/out/rend/surface-formats-test"

# laurel 0005: the texture -> image hash, cut out of eagl.c as it is built (topaz + userland/laurel/gpu/patches)
o=$here/out/rend/eagl-hash
rm -rf "$o"; mkdir -p "$o/userland/gpu"
cp "$here/external/ios-topaz/userland/gpu/eagl.c" "$o/userland/gpu/eagl.c"
for p in "$s"/patches/*.patch; do patch -s --no-backup-if-mismatch -d "$o" -p1 < "$p"; done
python3 -I - "$o/userland/gpu/eagl.c" > "$o/image_hash_cut.h" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
for head in ("static struct image *\nimage_of(", "static struct image *\nimage_new(", "static void\nimage_forget("):
    a = s.index(head)
    print(s[a:s.index("\n}\n", a) + 3])
PY
${CC:-cc} -std=c11 -Wall -O1 -fsanitize=address,undefined -I"$o" "$s/tests/image_hash_test.c" -o "$o/test"
"$o/test"
