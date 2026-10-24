#!/bin/sh
# Install the native host tools for every step except the Mu UEFI build (which stays in the container).
#   scripts/setup/native-tools.sh            (run in tmux: scripts/bg.sh tools scripts/setup/native-tools.sh)
# macOS: Homebrew aarch64-elf-gcc (+ binutils), gawk, rsync. Linux: apt cross GCC, gawk, rsync.
# Both: AOSP mkbootimg (Python) in out/tools/mkbootimg, Python venv out/venv with pyfatfs + fdt (uv).
# dtc + erofs-utils: camera inventory (scripts/camera/inventory.sh).
set -eu
. "$(dirname "$0")/../lib/env.sh"
case "$(uname -s)" in
Darwin) brew install aarch64-elf-gcc gawk rsync llvm lld acpica nasm dtc erofs-utils ;;
Linux)  sudo apt-get install -y gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu gawk rsync cpio python3-venv device-tree-compiler erofs-utils ;;
esac
mkdir -p "$OUT/tools"
[ -d "$OUT/tools/mkbootimg/.git" ] || \
  git clone -q --depth 1 https://android.googlesource.com/platform/system/tools/mkbootimg "$OUT/tools/mkbootimg"
if command -v uv >/dev/null 2>&1; then
  [ -x "$OUT/venv/bin/python3" ] || uv venv -q "$OUT/venv"
  VIRTUAL_ENV=$OUT/venv uv pip install -q pyfatfs pyyaml fdt "setuptools<81"
else
  [ -x "$OUT/venv/bin/python3" ] || python3 -m venv "$OUT/venv"
  "$OUT/venv/bin/pip" install -q pyfatfs pyyaml fdt "setuptools<81"
fi
"$REPO/scripts/lib/native-env.sh" sh -c 'aarch64-linux-gnu-gcc --version | head -1; mkbootimg --help >/dev/null && echo "mkbootimg ok"; python3 -c "import pyfatfs.PyFatFS; print(\"pyfatfs ok\")"'
