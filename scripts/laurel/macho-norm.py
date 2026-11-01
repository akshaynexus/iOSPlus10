#!/usr/bin/env python3
"""macho-norm.py FILE: SHA-256 of a thin Mach-O with its LC_UUID zeroed and its code signature (and the size words that name it) out: two links of the same code that differ only by link metadata compare equal.
Prints "RAW NORM NAME". Run with python3 -I."""
import hashlib
import struct
import sys


def main():
    for p in sys.argv[1:]:
        d = bytearray(open(p, "rb").read())
        raw = hashlib.sha256(d).hexdigest()
        if d[:4] == b"\xcf\xfa\xed\xfe":
            ncmds = struct.unpack_from("<I", d, 16)[0]
            off, cut = 32, len(d)
            for _ in range(ncmds):
                cmd, size = struct.unpack_from("<II", d, off)
                if cmd == 0x1b:                                    # LC_UUID
                    d[off + 8:off + 24] = bytes(16)
                elif cmd == 0x1d:                                  # LC_CODE_SIGNATURE
                    cut = struct.unpack_from("<I", d, off + 8)[0]
                    d[off + 8:off + 16] = bytes(8)
                elif cmd == 0x19 and d[off + 8:off + 24].split(b"\0")[0] == b"__LINKEDIT":
                    d[off + 32:off + 64] = bytes(32)               # vmsize, fileoff, filesize depend on the signature
                off += size
            d = d[:cut]
        print(raw[:16], hashlib.sha256(d).hexdigest()[:16], p)


if __name__ == "__main__":
    main()
