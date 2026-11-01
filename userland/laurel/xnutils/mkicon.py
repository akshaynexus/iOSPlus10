#!/usr/bin/env python3
"""The home screen icon of XNUtils: a 120 x 120 PNG (60 pt at scale 2), drawn here so that the repo holds no image and needs no tool.
    mkicon.py OUT.png
Dark ground, four bars like a stats screen. SpringBoard adds the round corners. No alpha channel: an icon must have none."""
import struct
import sys
import zlib

SIZE = 120
BARS = [(24, 28, 62, (0x34, 0xc7, 0x59)), (42, 46, 40, (0x0a, 0x84, 0xff)), (60, 64, 76, (0xff, 0x9f, 0x0a)), (78, 82, 28, (0xff, 0x45, 0x3a))]


def pixel(x, y):
    for left, _, height, colour in BARS:
        if left <= x < left + 14 and SIZE - 22 - height <= y < SIZE - 22:
            return colour
    # ground: a dark vertical fade
    v = 0x16 + y * 0x14 // SIZE
    return v, v, v + 6


def chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)


rows = b''.join(b'\0' + b''.join(bytes(pixel(x, y)) for x in range(SIZE)) for y in range(SIZE))
png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', SIZE, SIZE, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(rows, 9)) + chunk(b'IEND', b'')
with open(sys.argv[1], 'wb') as f:
    f.write(png)
