#!/usr/bin/env python3
"""metallib-air.py IN OUT: write the portable AIR library (MTLB) of an iOS 26 system metallib.

iOS 26 ships three forms [V 23F84]: plain MTLB; a fat Mach-O with one AIR slice (cputype 0x01000017) and one AGX slice (QuartzCore default.metallib);
a GPU Mach-O (cputype 0x01000013) with the AIR library inside a section (zeta: Mercury Space) or with AGX code only (a binary archive).
Exit 0: OUT written. Exit 3: no AIR in the file (AGX code only: nothing metal2vulkan can read). Prints one line. Python 3, no modules beyond the standard ones.
"""
import struct
import sys


def mtlb_size(d, o):
    # header: 'MTLB', target u16, version u16 u16, type u8, os u8, os version u16 u16, file size u64
    if d[o:o + 4] != b"MTLB" or o + 88 > len(d):
        return 0
    size = struct.unpack_from("<Q", d, o + 16)[0]
    return size if 88 <= size <= len(d) - o else 0


def bitcode_size(d, o):
    # offset table after the header: function list, public metadata, private metadata, bitcode (offset, size pairs). A kind 0x80 container has no bitcode: AGX only.
    return struct.unpack_from("<Q", d, o + 24 + 7 * 8)[0]


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    d = open(sys.argv[1], "rb").read()
    found = []
    if d[:4] == b"\xca\xfe\xba\xbe":
        n = struct.unpack(">I", d[4:8])[0]
        for i in range(n):
            c, _, o, z, _ = struct.unpack_from(">iiIII", d, 8 + 20 * i)
            if mtlb_size(d, o):
                found.append((o, mtlb_size(d, o), f"fat slice {c & 0xffffffff:#x}"))
    elif d[:4] == b"MTLB":
        found.append((0, mtlb_size(d, 0), "plain MTLB"))
    if not found:
        p = d.find(b"MTLB")
        while p >= 0:
            z = mtlb_size(d, p)
            if z:
                found.append((p, z, f"embedded at {p:#x}"))
                p = d.find(b"MTLB", p + z)
            else:
                p = d.find(b"MTLB", p + 4)
    if not found:
        print(f"{sys.argv[1]}: no AIR (AGX code only, {len(d)} bytes)")
        sys.exit(3)
    found = [f for f in found if bitcode_size(d, f[0]) > 0]
    if not found:
        print(f"{sys.argv[1]}: no AIR bitcode (AGX code and a function table only, {len(d)} bytes)")
        sys.exit(3)
    o, z, how = max(found, key=lambda x: bitcode_size(d, x[0]))
    open(sys.argv[2], "wb").write(d[o:o + z])
    print(f"{sys.argv[1]}: AIR {z} bytes, {how} ({len(found)} found)")


if __name__ == "__main__":
    main()
