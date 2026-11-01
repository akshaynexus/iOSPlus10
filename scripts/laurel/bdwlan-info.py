#!/usr/bin/env python3
"""Board data files of the Mi A3 modem image: what each one says (read-only, nothing is written).

  scripts/laurel/bdwlan-info.py [NON-HLOS.bin]   (default ~/laurel-backup/stock/images/NON-HLOS.bin)

The FAT walk is the same walk as `op10tool fatls`. After 8 bytes of file header comes the QCA board data
header (BASE_EEP_HEADER: length, checksum, eeprom and template version, MAC, 2 regulatory domains, op flags).
The check: the length field must be the file size; a file that fails is marked "layout ?".
op flags: 0x01 11a, 0x02 11g, 0x04 5G HT40, 0x08 2G HT40, 0x10 5G HT20, 0x20 2G HT20.
"""
import os
import struct
import sys


def walk(img, bs, spc, first_fat, data, root_ents, root_off):
    def fat(c):
        return struct.unpack_from("<H", img, first_fat + 2 * c)[0]

    def chain(c):
        out = bytearray()
        n = 0
        while 2 <= c < 0xFFF8 and n < 65536:
            off = data + (c - 2) * spc * bs
            out += img[off:off + spc * bs]
            c = fat(c)
            n += 1
        return bytes(out)

    def entries(buf, path, depth):
        lfn = {}
        for o in range(0, len(buf) - 31, 32):
            e = buf[o:o + 32]
            if e[0] == 0:
                return
            if e[0] == 0xE5:
                lfn = {}
                continue
            if e[11] == 0x0F:
                part = (e[1:11] + e[14:26] + e[28:32]).decode("utf-16-le", "ignore")
                lfn[e[0] & 0x1F] = part.split("\0")[0]
                continue
            if lfn:
                name = "".join(lfn[k] for k in sorted(lfn))
            else:
                name = e[:8].decode("latin1").strip()
                ext = e[8:11].decode("latin1").strip()
                name = f"{name}.{ext}" if ext else name
            lfn = {}
            if name in (".", "..") or e[11] & 8:
                continue
            c = struct.unpack_from("<H", e, 26)[0]
            size = struct.unpack_from("<I", e, 28)[0]
            p = f"{path}/{name}".lower().lstrip("/")
            if e[11] & 0x10:
                if depth < 16:
                    yield from entries(chain(c), p, depth + 1)
            else:
                yield p, c, size, chain

    yield from entries(img[root_off:root_off + root_ents * 32], "", 0)


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/laurel-backup/stock/images/NON-HLOS.bin")
    with open(path, "rb") as f:
        img = f.read()
    bs, spc, res, nfat, root_ents = struct.unpack_from("<HBHBH", img, 11)
    fatsz = struct.unpack_from("<H", img, 22)[0]
    first_fat = res * bs
    root_off = first_fat + nfat * fatsz * bs
    data = root_off + ((root_ents * 32 + bs - 1) // bs) * bs
    print(f"{'file':26} {'bytes':>7} {'MAC':17} {'reg0':>6} {'reg1':>6} {'op':>4}  check")
    for p, c, size, chain in sorted(walk(img, bs, spc, first_fat, data, root_ents, root_off), key=lambda x: x[0]):
        if "/bdwlan" not in "/" + p:
            continue
        d = chain(c)[:size]
        length = struct.unpack_from("<H", d, 8)[0]
        mac = ":".join(f"{b:02x}" for b in d[14:20])
        r0, r1 = struct.unpack_from("<HH", d, 20)
        op = d[24]
        ok = "ok" if length == size else f"layout ? (length field {length})"
        print(f"{p:26} {size:7} {mac} {r0:#6x} {r1:#6x} {op:#4x}  {ok}")


if __name__ == "__main__":
    main()
