#!/bin/sh
# Host tests of the Mi A3 microphone (quick, no phone, no kernel build):
#   scripts/laurel/mic-host-test.sh
# 1. RedwoodAudio.driver's input path: audio_plugin.c + mic-input.patch against a mock /dev/redwood-mic (hal_test.c):
#    what iOS sees of the "Codec" device, samples, short reads, the kernel's mic off, capture gain, playback untouched.
# 2. Patch 2920's hardware sequence and ring against a register model (seq_test.c): the values of the stock driver + DT.
# Needs cc, patch, python3 and the reference external/ios-topaz. Output in out/mic-test/ (git-ignored).
# What they do not prove: the chip, the ADSP, iOS. See docs/laurel_sprout/audio.md "Microphone".
set -eu
REPO=$(cd "$(dirname "$0")/../.." && pwd)
SRC=$REPO/external/ios-topaz/userland/audio
T=$REPO/scripts/laurel/mic-test
W=$REPO/out/mic-test
PATCH=$REPO/patches/laurel/xnu/2920-laurel-mic-wcd937x.patch
[ -f "$SRC/audio_plugin.c" ] || { echo "mic-host-test: missing $SRC (scripts/setup/get-references.sh ios-topaz)" >&2; exit 1; }
rm -rf "$W"
mkdir -p "$W/hal" "$W/inc"
CC=${CC:-cc}

cp "$SRC/audio_plugin.c" "$SRC/redwood_audio.h" "$W/hal/"
(cd "$W/hal" && patch -s -p1 < "$REPO/userland/laurel/audio/mic-input.patch")
"$CC" -O1 -g -Wall -Wno-multichar -Wno-four-char-constants -Wno-unused-function -Wno-format -I"$T/stub" -I"$W/hal" -I"$T" \
  "$T/hal_test.c" -lm -o "$W/hal_test"
"$W/hal_test"

# the new files of the patch, as the patch has them
python3 -I - "$PATCH" "$W/inc" <<'PY'
import re, sys
patch, out = sys.argv[1], sys.argv[2]
for part in re.split(r'(?m)^(?=diff --git )', open(patch).read()):
    m = re.match(r'diff --git a/iokit/Kernel/arm/(LaurelMic\w+\.inc) ', part)
    if m:
        body = part.split('\n@@ ', 1)[1].split('\n')[1:]
        open(out + '/' + m.group(1), 'w').write('\n'.join(l[1:] for l in body if l.startswith('+')) + '\n')
PY
"$CC" -O1 -g -Wall -Wno-unused-function -I"$W/inc" -I"$T" "$T/seq_test.c" -o "$W/seq_test"
"$W/seq_test"
echo "mic-host-test: PASS"
