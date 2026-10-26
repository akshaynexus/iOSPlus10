#!/usr/bin/env python3
"""Convert a /dev/negroni-fp dump (patch 0353) into PNG files, one per interpretation.

  scripts/net/ssh-phone.sh scp root@phone:/dev/negroni-fp out/fp/capture.bin   (or cat > file on the phone)
  scripts/fp/raw-to-png.py out/fp/capture.bin [--width W --height H] [--fmt u16le|u12|u8|auto]
  scripts/fp/raw-to-png.py --self-test            (a synthetic 364x252x2 gradient dump through all 3 formats)

The node is root-only (0600). Header (32 bytes, little endian): magic 'NFPI', width 364, height 252, len, negronifp mode, wrap (1 = the
CC F2 transport answered), proto (2 = valid message pack in step 10, 0 = none), pad. Then len bytes.
Formats: u16le = 2 bytes per pixel (DELMAR_ORIGIN_BUFFER_LEN 364 x 252 x 2), u12 = the public Goodix
12-bit packing (goodix-fp-dump tool.py decode_image: 6 bytes -> 4 pixels), u8 = 1 byte per pixel.
auto = every format whose size fits; each output is min-max normalised to 8 bit. No PIL: a plain
zlib PNG writer. Prints the header, byte statistics and the files written.
"""
import argparse, struct, sys, zlib

def png_write(path, w, h, rows):
    raw = b"".join(b"\x00" + bytes(r) for r in rows)
    def chunk(t, d):
        c = t + d
        return struct.pack(">I", len(d)) + c + struct.pack(">I", zlib.crc32(c) & 0xffffffff)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 0, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))

def normalise(vals):
    lo, hi = min(vals), max(vals)
    span = hi - lo or 1
    return [((v - lo) * 255) // span for v in vals]

def decode_u12(data):
    out = []
    for i in range(0, len(data) - 5, 6):
        c = data[i:i + 6]
        out += [((c[0] & 0xf) << 8) + c[1], (c[3] << 4) + (c[0] >> 4), ((c[5] & 0xf) << 8) + c[2], (c[4] << 4) + (c[5] >> 4)]
    return out

def self_test():
    import os, tempfile
    d = tempfile.mkdtemp()
    dump = os.path.join(d, "t.bin")
    data = bytes((x * 7) % 256 for x in range(364 * 252 * 2))
    with open(dump, "wb") as f:
        f.write(struct.pack("<8I", 0x4950464e, 364, 252, len(data), 4, 0, 2, 0) + data)
    sys.argv = [sys.argv[0], dump]
    main()
    for fmt, h in (("u16le", 252), ("u12", 252), ("u8", 252)):
        png = open(f"{dump}.{fmt}.png", "rb").read()
        assert png[:8] == b"\x89PNG\r\n\x1a\n", fmt
        w, hh, depth, ctype = struct.unpack(">IIBB", png[16:26])
        assert (w, hh, depth, ctype) == (364, h, 8, 0), (fmt, w, hh, depth, ctype)
    print("self-test ok:", d)


def main():
    if "--self-test" in sys.argv:
        sys.argv.remove("--self-test")
        return self_test()
    ap = argparse.ArgumentParser()
    ap.add_argument("dump")
    ap.add_argument("--width", type=int)
    ap.add_argument("--height", type=int)
    ap.add_argument("--fmt", default="auto", choices=["auto", "u16le", "u12", "u8"])
    ap.add_argument("--out", help="output prefix (default: the dump path)")
    a = ap.parse_args()
    blob = open(a.dump, "rb").read()
    if len(blob) < 32 or blob[:4] != b"NFPI":
        sys.exit("not a negroni-fp dump (no NFPI header)")
    magic, w, h, n, mode, wrap, proto, _ = struct.unpack("<8I", blob[:32])
    data = blob[32:32 + n]
    w = a.width or w
    h = a.height or h
    print(f"header: {w}x{h}, {n} bytes, negronifp={mode}, transport={'CC F2' if wrap else 'plain'}, step-10 proto={proto}")
    if not data:
        sys.exit("no capture bytes (len 0): negronifp=4 did not run or read nothing")
    hist = [0] * 256
    for b in data:
        hist[b] += 1
    distinct = sum(1 for c in hist if c)
    print(f"bytes: 00 x{hist[0]}, ff x{hist[255]}, {distinct} distinct values; first 16: {data[:16].hex(' ')}")
    prefix = a.out or a.dump
    fmts = [a.fmt] if a.fmt != "auto" else ["u16le", "u12", "u8"]
    for fmt in fmts:
        if fmt == "u16le":
            px = [v for (v,) in struct.iter_unpack("<H", data[: len(data) // 2 * 2])]
        elif fmt == "u12":
            px = decode_u12(data)
        else:
            px = list(data)
        rows = len(px) // w
        if rows < 1:
            print(f"{fmt}: too few pixels ({len(px)}) for width {w}")
            continue
        rows = min(rows, h) if a.fmt == "auto" else rows
        vals = normalise(px[: rows * w])
        path = f"{prefix}.{fmt}.png"
        png_write(path, w, rows, [vals[r * w:(r + 1) * w] for r in range(rows)])
        print(f"{fmt}: {w}x{rows} -> {path}")

if __name__ == "__main__":
    main()
