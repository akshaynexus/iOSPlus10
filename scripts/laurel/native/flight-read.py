#!/usr/bin/env python3
"""flight-read.py FILE [--fence N] [--find HEXWORD]...: the native stack's flight recorder (bridge/src/flight.rs). Prints the ring in order; --fence: from the submission before fence N to its end; --find: the lines that hold a word. Run with python3 -I."""
import struct
import sys

HEAD = 64
args = sys.argv[2:]
data = open(sys.argv[1], "rb").read()
end = struct.unpack_from("<Q", data, 0)[0]
print(f"last finished draw id: {struct.unpack_from('<I', data, 8)[0]}")
room = len(data) - HEAD
at = end % room
text = data[HEAD + at:] + data[HEAD:HEAD + at] if end >= room else data[HEAD:HEAD + end]
lines = text.decode("latin-1").split("\n")
finds = [args[i + 1].lower() for i, a in enumerate(args) if a == "--find"]
fence = next((int(args[i + 1]) for i, a in enumerate(args) if a == "--fence"), None)
if finds:
    for i, l in enumerate(lines):
        if any(f in l for f in finds):
            print(f"{i}: {l[:600]}")
    sys.exit(0)
if fence is not None:
    marks = [i for i, l in enumerate(lines) if l.startswith("submit fence=")]
    after = [i for i in marks if int(lines[i].split("=")[1].split()[0]) >= fence]
    last = after[0] if after else len(lines) - 1
    before = [i for i in marks if i < last]
    first = before[-3] if len(before) >= 3 else 0
    lines = lines[first:last + 200]
for l in lines:
    print(l[:900])
