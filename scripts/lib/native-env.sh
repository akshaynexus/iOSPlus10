#!/bin/sh
# Run a command with the native build tools first in PATH (no container):
#   scripts/lib/native-env.sh <command...>
# The port's scripts call aarch64-linux-gnu-{gcc,objcopy,readelf,nm}, awk with strtonum and
# mkbootimg. On macOS this maps them to Homebrew aarch64-elf-* and gawk (out/tools/bin links);
# on Linux the real cross tools are used. mkbootimg = AOSP Python script; python3 = out/venv.
set -eu
. "$(dirname "$0")/env.sh"
B=$OUT/tools/bin
mkdir -p "$B"
if [ "$(uname -s)" = Darwin ]; then
  for t in gcc objcopy readelf nm objdump ld; do
    ln -sf "$(command -v aarch64-elf-$t)" "$B/aarch64-linux-gnu-$t"
  done
  ln -sf "$(command -v gawk)" "$B/awk"
fi
ln -sf "$OUT/tools/mkbootimg/mkbootimg.py" "$B/mkbootimg"
ln -sf "$OUT/tools/mkbootimg/unpack_bootimg.py" "$B/unpack_bootimg"
ln -sf "$OUT/bin/op10tool" "$B/op10tool"
PATH=$B:$OUT/venv/bin:$PATH
export PATH
exec "$@"
