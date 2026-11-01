#!/usr/bin/env python3
"""metallib-census.py ROOT...: every *.metallib below ROOT: its form, each MTLB container in it (kind byte, function count, bitcode bytes), Mach-O cputype and LC_SEGMENT names.
Answers which system shader libraries still carry AIR bitcode (metal2vulkan's only input) on this firmware. Output: TSV on stdout. Run with python3 -I."""
import os
import struct
import sys


def mtlbs(d):
    p, out = d.find(b"MTLB"), []
    while p >= 0:
        if p + 88 <= len(d):
            kind = d[p + 10]   # library type byte (0 executable, 1 core image, 2 dynamic, 3 symbol companion; 0x80 here = stripped form) [V 23F84]
            size = struct.unpack_from("<Q", d, p + 16)[0]
            if 88 <= size <= len(d) - p:
                # offsets table: function list, public metadata, private metadata, bitcode (offset, size pairs)
                fl_o, fl_s, _, _, _, _, bc_o, bc_s = struct.unpack_from("<8Q", d, p + 24)
                n = struct.unpack_from("<I", d, p + fl_o)[0] if p + fl_o + 4 <= len(d) else -1
                out.append((p, size, kind, n, bc_s))
                p = d.find(b"MTLB", p + size)
                continue
        p = d.find(b"MTLB", p + 4)
    return out


def main():
    print("path\tbytes\tform\tcontainers(kind:functions:bitcode)\tBC-magic-words")
    for root in sys.argv[1:]:
        for dp, _, fs in os.walk(root):
            for f in sorted(fs):
                if not f.endswith(".metallib"):
                    continue
                path = os.path.join(dp, f)
                d = open(path, "rb").read()
                form = {b"\xca\xfe\xba\xbe": "fat", b"MTLB": "plain", b"\xcf\xfa\xed\xfe": "machO"}.get(d[:4], d[:4].hex())
                if form == "machO":
                    form += f" cpu {struct.unpack_from('<I', d, 4)[0]:#x}"
                conts = mtlbs(d)
                bc = d.count(b"BC\xc0\xde") + d.count(b"\xde\xc0\x17\x0b")
                print(f"{os.path.relpath(path, root)}\t{len(d)}\t{form}\t" + ",".join(f"{k:#x}:{n}:{b}" for _, _, k, n, b in conts) + f"\t{bc}")


if __name__ == "__main__":
    main()
