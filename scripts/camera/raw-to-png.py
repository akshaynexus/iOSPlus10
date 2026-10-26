#!/usr/bin/env python3
"""Convert a camera frame from the negroni kernel (patch 0315) into a PNG.

  raw-to-png.py IN.raw [OUT.png] [--bayer RGGB|BGGR|GRBG|GBRG|gray] [--full] [--no-wb]

IN.raw is what /dev/negronicam-tpg or /dev/negronicam-sensor gives (scripts/camera/pull-frame.sh):
a 64-byte header, then the RDI0 payload as the CSID received it.
  header: char magic[8] = "NCAMRAW1"; u32 version, width, height, stride (bytes per line), bytes,
          data_type (0x2b RAW10), bits (10), packing (1 = MIPI: 4 pixels in 5 bytes), source
          (1 TPG, 2 sensor), valid (1 = the kernel sanity check passed); 16 bytes pad. Little endian.
MIPI RAW10: bytes 0..3 = bits 9..2 of pixels 0..3, byte 4 = bits 1..0 of pixels 0..3 (pixel n at
bits 2n+1..2n).
Output: by default a half-size RGB image (one RGB pixel per 2x2 Bayer cell, no interpolation), with a
gray-world white balance and a 2.2 gamma; --full gives a full-size gray image of the raw values;
--bayer gray gives a half-size gray image. The Bayer order of the IMX789 in the FTM mode is not known
from a source [I]; the default RGGB is a guess, try the other three if the colours are wrong.
Only the Python standard library (zlib, struct). Runs on macOS and Linux. Run with python3 -I.
"""
import struct
import sys
import zlib

ORDERS = {"RGGB": "RGGB", "BGGR": "BGGR", "GRBG": "GRBG", "GBRG": "GBRG"}


def unpack_line(data, off, width):
    """One MIPI RAW10 line -> list of 10-bit values."""
    out = [0] * width
    n = width // 4
    for g in range(n):
        b = data[off + 5 * g: off + 5 * g + 5]
        low = b[4]
        out[4 * g] = b[0] << 2 | (low & 3)
        out[4 * g + 1] = b[1] << 2 | (low >> 2 & 3)
        out[4 * g + 2] = b[2] << 2 | (low >> 4 & 3)
        out[4 * g + 3] = b[3] << 2 | (low >> 6 & 3)
    return out


def png(path, w, h, rows, channels):
    """rows: list of bytes objects (one per line, w * channels bytes)."""
    raw = b"".join(b"\0" + r for r in rows)
    color = 2 if channels == 3 else 0

    def chunk(tag, payload):
        c = struct.pack(">I", len(payload)) + tag + payload
        return c + struct.pack(">I", zlib.crc32(tag + payload) & 0xffffffff)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, color, 0, 0, 0)))
        f.write(chunk(b"IDAT", zlib.compress(raw, 6)))
        f.write(chunk(b"IEND", b""))


def main():
    args, bayer, full, wb = [], "RGGB", False, True
    it = iter(sys.argv[1:])
    for a in it:
        if a == "--bayer":
            bayer = next(it, "RGGB")
        elif a == "--full":
            full = True
        elif a == "--no-wb":
            wb = False
        else:
            args.append(a)
    if not args:
        sys.exit(__doc__)
    src = args[0]
    dst = args[1] if len(args) > 1 else src.rsplit(".", 1)[0] + ".png"
    data = open(src, "rb").read()
    if len(data) < 64 or data[:8] != b"NCAMRAW1":
        sys.exit(f"{src}: no NCAMRAW1 header")
    ver, w, h, stride, nbytes, dt, bits, packing, source, valid = struct.unpack_from("<10I", data, 8)
    print(f"{src}: v{ver} {w}x{h} stride {stride} bytes {nbytes} dt {dt:#x} {bits}-bit packing {packing} "
          f"source {'TPG' if source == 1 else 'sensor' if source == 2 else source} kernel-check "
          f"{'PASS' if valid else 'FAIL'}")
    if bits != 10 or packing != 1 or w % 4:
        sys.exit("only MIPI RAW10 with a width that is a multiple of 4 is handled")
    payload = data[64:64 + nbytes]
    if len(payload) < stride * h:
        h = len(payload) // stride
        print(f"short file: {h} lines")
    if full:
        rows = [bytes(v >> 2 for v in unpack_line(payload, y * stride, w)) for y in range(h)]
        png(dst, w, h, rows, 1)
        print(f"wrote {dst} ({w}x{h} gray, raw >> 2)")
        return
    hw, hh = w // 2, h // 2
    if bayer == "gray":
        rows = []
        for y in range(hh):
            a = unpack_line(payload, 2 * y * stride, w)
            b = unpack_line(payload, (2 * y + 1) * stride, w)
            rows.append(bytes((a[2 * x] + a[2 * x + 1] + b[2 * x] + b[2 * x + 1]) >> 4 for x in range(hw)))
        png(dst, hw, hh, rows, 1)
        print(f"wrote {dst} ({hw}x{hh} gray)")
        return
    if bayer not in ORDERS:
        sys.exit(f"--bayer {bayer}: use RGGB, BGGR, GRBG, GBRG or gray")
    pos = {c: [] for c in "RGB"}
    for k, c in enumerate(bayer):
        pos[c].append((k // 2, k % 2))
    cells = []
    sums = [0, 0, 0]
    for y in range(hh):
        two = (unpack_line(payload, 2 * y * stride, w), unpack_line(payload, (2 * y + 1) * stride, w))
        line = []
        for x in range(hw):
            px = []
            for ci, c in enumerate("RGB"):
                v = sum(two[dy][2 * x + dx] for dy, dx in pos[c]) / len(pos[c])
                px.append(v)
                sums[ci] += v
            line.append(px)
        cells.append(line)
    n = max(1, hw * hh)
    means = [s / n for s in sums]
    gains = [means[1] / m if (wb and m > 0) else 1.0 for m in means]
    peak = max(max(max(p[c] * gains[c] for c in range(3)) for p in line) for line in cells) or 1.0
    lut_scale = 255.0
    rows = []
    for line in cells:
        out = bytearray()
        for p in line:
            for c in range(3):
                v = min(1.0, max(0.0, p[c] * gains[c] / peak))
                out.append(int(lut_scale * v ** (1 / 2.2) + 0.5))
        rows.append(bytes(out))
    png(dst, hw, hh, rows, 3)
    print(f"wrote {dst} ({hw}x{hh} RGB, {bayer}, white balance {'gray world' if wb else 'off'}, "
          f"gains {gains[0]:.2f} {gains[1]:.2f} {gains[2]:.2f})")


main()
