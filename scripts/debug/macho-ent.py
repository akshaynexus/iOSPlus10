#!/usr/bin/env python3
"""macho-ent.py TREE OUT PATH...: the XML entitlements of Mach-O files, one text file each. Read-only; the file's bytes are only parsed.
   TREE/{os,sys}/PATH is read. Output: OUT/<basename>.xml. For scripts/debug/air-re-26.sh. Works on macOS and Linux."""
import os
import struct
import sys

CS_MAGIC_SUPER = 0xfade0cc0
CS_MAGIC_ENT = 0xfade7171
LC_CODE_SIGNATURE = 0x1d


def slice_of(data):
    magic = struct.unpack('>I', data[:4])[0]
    if magic == 0xcafebabe:     # fat: the last slice is the arm64e one on these files
        n = struct.unpack('>I', data[4:8])[0]
        best = None
        for i in range(n):
            cpu, sub, off, size, _ = struct.unpack('>5I', data[8 + i * 20:28 + i * 20])
            if cpu == 0x0100000c:
                best = (off, size)
        if best is None:
            raise ValueError('no arm64 slice')
        return data[best[0]:best[0] + best[1]]
    return data


def entitlements(path):
    with open(path, 'rb') as f:
        data = slice_of(f.read())
    ncmds = struct.unpack('<I', data[16:20])[0]
    off = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack('<II', data[off:off + 8])
        if cmd == LC_CODE_SIGNATURE:
            cs, _ = struct.unpack('<II', data[off + 8:off + 16])
            magic, _, count = struct.unpack('>III', data[cs:cs + 12])
            if magic != CS_MAGIC_SUPER:
                return None
            for i in range(count):
                _, blob = struct.unpack('>II', data[cs + 12 + i * 8:cs + 20 + i * 8])
                m, length = struct.unpack('>II', data[cs + blob:cs + blob + 8])
                if m == CS_MAGIC_ENT:
                    return data[cs + blob + 8:cs + blob + length]
            return None
        off += size
    return None


def main():
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    tree, out = sys.argv[1:3]
    os.makedirs(out, exist_ok=True)
    for rel in sys.argv[3:]:
        for vol in ('os', 'sys'):
            p = os.path.join(tree, vol, rel)
            if os.path.exists(p):
                e = entitlements(p)
                name = os.path.basename(rel)
                if e is None:
                    print(f'{rel}: no entitlements blob')
                else:
                    with open(os.path.join(out, name + '.xml'), 'wb') as f:
                        f.write(e)
                    print(f'{rel}: {len(e)} bytes of entitlements')
                break
        else:
            print(f'{rel}: not in the tree')


if __name__ == '__main__':
    main()
