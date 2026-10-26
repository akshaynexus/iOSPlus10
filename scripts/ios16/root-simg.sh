#!/bin/sh
# Convert the raw iOS root image to an Android sparse image for `fastboot flash userdata`.
#   scripts/ios16/root-simg.sh [IN.img]        (default $APPLE/ios16-root.img -> $APPLE/ios16-root.simg)
#   AREAS=1 scripts/ios16/root-simg.sh [IN.img]
#     also puts the firmware areas (scripts/fw/build-areas.sh: out/firmware/{gpu,adsp,wlan}-area.bin) at
#     their blocks at the end of userdata, so one flash writes root + areas (`fastboot flash userdata`
#     erases the areas otherwise). The image then covers all N blocks of userdata (NE2211: 58672399,
#     getvar partition-size:userdata 0x37F450F000), with holes as DONT_CARE.
#     The boot log area (kernel 0367, N-28673 .. N-19458, 36 MiB) is reserved: the root must end below it;
#     its superblock (`op10tool bootlog --mkarea`) is written at N-28673, the slots stay DONT_CARE (the kernel
#     ignores slot headers without a valid CRC).
# Uses `op10tool img2simg` (holes -> DONT_CARE via SEEK_DATA/SEEK_HOLE, uniform blocks -> FILL); its output  (2026-10-27: a hole in an HFS+-allocated block -> FILL 0, see op10tool img2simg)
# decodes byte-identical with AOSP simg2img (tools/op10tool/tests).
set -eu
. "$(dirname "$0")/../lib/env.sh"
APPLE=${APPLE:-$HOME/op10-apple}
IN=${1:-$APPLE/ios16-root.img}
OUTS=${IN%.img}.simg
SRC=$IN
if [ "${AREAS:-0}" = 1 ]; then
  N=${USERDATA_BLOCKS:-58672399}
  sz=$(stat -f %z "$IN" 2>/dev/null || stat -c %s "$IN")
  LOW=$((N - 28673))     # lowest reserved block: the boot log area (kernel 0367), then the firmware areas
  if [ $((sz / 4096)) -gt $LOW ]; then
    # a simg2img output is partition-sized (DONT_CARE to the end): cut it at the HFS+ volume size
    "$OUT/bin/op10tool" hfs-size --trim "$IN"
    sz=$(stat -f %z "$IN" 2>/dev/null || stat -c %s "$IN")
  fi
  [ $(((sz + 4095) / 4096)) -le $LOW ] || { echo "$IN reaches the area blocks (boot log area at block $LOW): stop" >&2; exit 1; }
  for a in gpu adsp wlan; do
    [ -f "$OUT/firmware/$a-area.bin" ] || { echo "missing out/firmware/$a-area.bin (scripts/fw/build-areas.sh)" >&2; exit 1; }
  done
  SRC=${IN%.img}-full.img
  rm -f "$SRC"
  cp -c "$IN" "$SRC" 2>/dev/null || cp "$IN" "$SRC"     # APFS clone where possible (no extra space)
  python3 -c 'import os,sys; os.truncate(sys.argv[1], int(sys.argv[2]) * 4096)' "$SRC" "$N"
  # name seek(block) count: the layout of scripts/audio/mkadsparea.py and scripts/fw/write-areas.sh
  for e in "gpu $((N - 3073)) 2048" "adsp $((N - 11265)) 8192" "wlan $((N - 19457)) 8192"; do
    set -- $e
    want=$(shasum -a 256 "$OUT/firmware/$1-area.bin" | cut -d' ' -f1)
    dd if="$OUT/firmware/$1-area.bin" of="$SRC" bs=4096 seek="$2" count="$3" conv=notrunc 2>/dev/null
    got=$(dd if="$SRC" bs=4096 skip="$2" count="$3" 2>/dev/null | shasum -a 256 | cut -d' ' -f1)
    [ "$got" = "$want" ] || { echo "area $1: read-back differs" >&2; exit 1; }
    echo "area $1 at block $2 ($3 blocks): sha256 ${got%"${got#????????????????}"}... OK"
  done
  # boot log area: the superblock only (the kernel writes it too when it is missing)
  "$OUT/bin/op10tool" bootlog --mkarea "$SRC.bootlog-super"
  dd if="$SRC.bootlog-super" of="$SRC" bs=4096 seek="$LOW" count=1 conv=notrunc 2>/dev/null
  [ "$(dd if="$SRC" bs=4096 skip="$LOW" count=1 2>/dev/null | head -c 8)" = NEGRBLOG ] || { echo "boot log superblock: read-back differs" >&2; exit 1; }
  rm -f "$SRC.bootlog-super"
  echo "boot log area at block $LOW (9216 blocks): superblock NEGRBLOG OK"
fi
"$OUT/bin/op10tool" img2simg "$SRC" "$OUTS"
[ "$SRC" = "$IN" ] || rm -f "$SRC"
ls -l "$IN" "$OUTS"
shasum -a 256 "$OUTS"
