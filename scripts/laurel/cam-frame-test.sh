#!/bin/sh
# Host test of op10tool camframe (the camera frame read of kernel patch 2771) against a mock phone on 127.0.0.1:5141
# (tools/laurel-cam-test/mock_phone.py, 5 % of the reads lost): the frame must arrive byte-equal, and the PNG must exist.
#   scripts/laurel/cam-frame-test.sh        (macOS and Linux; a few seconds; port 5141 on 127.0.0.1 must be free)
set -eu
. "$(dirname "$0")/../lib/env.sh"
D=$OUT/laurel-cam-test/frame
rm -rf "$D"; mkdir -p "$D"
OP=$OUT/bin/op10tool
[ -x "$OP" ] || "$REPO/scripts/setup/build-op10tool.sh"
# a test frame: 1280x720 RAW10 = 1152000 bytes of a repeating pattern
python3 -I -c 'import sys; open(sys.argv[1], "wb").write(bytes((i * 7 + i // 1600) & 255 for i in range(1152000)))' "$D/in.raw10"
python3 -I "$REPO/tools/laurel-cam-test/mock_phone.py" "$D/in.raw10" 5141 0.05 &
mock=$!
trap 'kill $mock 2>/dev/null || true' EXIT
sleep 0.5
"$OP" camframe --host 127.0.0.1 --out "$D"
cmp "$D/in.raw10" "$D/camframe-gen2.raw10"
[ -s "$D/camframe-gen2.png" ]
echo "cam-frame-test: OK (frame byte-equal after lost reads, PNG written)"
