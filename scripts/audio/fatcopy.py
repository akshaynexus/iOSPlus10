#!/usr/bin/env python3
"""Copy files out of a FAT12/16/32 image (read-only, no mtools needed).

  fatcopy.py IMAGE list [DIR]                 list DIR (default: the root), one entry per line
  fatcopy.py IMAGE get DIR PATTERN OUTDIR     copy the files in DIR that match the glob PATTERN
                                              (case-insensitive) to OUTDIR, print name + size

Used for the Qualcomm NON-HLOS (modem) image: `image/adsp.mdt`, `image/adsp.b00` ...
Long file names (VFAT) are supported; the 8.3 name is used when there is none.
Run with `python3 -I` (the image is untrusted input).
"""
import fnmatch
import os
import struct
import sys


class Fat:
    def __init__(self, path):
        self.f = open(path, 'rb')
        bs = self.f.read(512)
        if bs[510:512] != b'\x55\xaa':
            sys.exit(f'{path}: no FAT boot sector (missing 55 AA)')
        (self.bps, self.spc, reserved, nfats, root_entries, total16, _media, fat16_size,
         ) = struct.unpack_from('<HBHBHHBH', bs, 11)
        total32, fat32_size, _flags, _ver, self.root_cluster = struct.unpack_from('<IIHHI', bs, 32)
        if self.bps not in (512, 1024, 2048, 4096) or self.spc == 0:
            sys.exit(f'{path}: bad BPB (bytes/sector {self.bps}, sectors/cluster {self.spc})')
        fat_size = fat16_size or fat32_size
        total = total16 or total32
        self.fat_off = reserved * self.bps
        root_sectors = (root_entries * 32 + self.bps - 1) // self.bps
        self.root_off = (reserved + nfats * fat_size) * self.bps
        self.data_off = self.root_off + root_sectors * self.bps
        self.csize = self.spc * self.bps
        clusters = (total - (self.data_off // self.bps)) // self.spc
        self.bits = 12 if clusters < 4085 else 16 if clusters < 65525 else 32
        self.root_bytes = root_entries * 32
        self.f.seek(self.fat_off)
        self.fat = self.f.read(fat_size * self.bps)

    def next(self, c):
        if self.bits == 32:
            return struct.unpack_from('<I', self.fat, c * 4)[0] & 0x0FFFFFFF
        if self.bits == 16:
            return struct.unpack_from('<H', self.fat, c * 2)[0]
        v = struct.unpack_from('<H', self.fat, c * 3 // 2)[0]
        return v >> 4 if c & 1 else v & 0xFFF

    def end(self, c):
        return c < 2 or c >= {12: 0xFF8, 16: 0xFFF8, 32: 0x0FFFFFF8}[self.bits]

    def chain(self, c):
        seen = set()
        while not self.end(c):
            if c in seen:
                sys.exit('FAT loop')
            seen.add(c)
            yield c
            c = self.next(c)

    def read_chain(self, first, size=None):
        out = bytearray()
        for c in self.chain(first):
            self.f.seek(self.data_off + (c - 2) * self.csize)
            out += self.f.read(self.csize)
            if size is not None and len(out) >= size:
                break
        return bytes(out if size is None else out[:size])

    def entries(self, cluster):
        if cluster == 0 and self.bits != 32:
            self.f.seek(self.root_off)
            raw = self.f.read(self.root_bytes)
        else:
            raw = self.read_chain(cluster or self.root_cluster)
        lfn = {}
        for i in range(0, len(raw), 32):
            e = raw[i:i + 32]
            if e[0] == 0:
                break
            if e[0] == 0xE5:
                lfn = {}
                continue
            if e[11] == 0x0F:
                seq = e[0] & 0x1F
                lfn[seq] = (e[1:11] + e[14:26] + e[28:32]).decode('utf-16-le', 'replace')
                continue
            if e[11] & 0x08:      # volume label
                lfn = {}
                continue
            if lfn:
                name = ''.join(lfn[k] for k in sorted(lfn)).split('\0')[0].rstrip('￿')
            else:
                base, ext = e[0:8].decode('latin-1').rstrip(), e[8:11].decode('latin-1').rstrip()
                name = base + ('.' + ext if ext else '')
            lfn = {}
            hi, lo = struct.unpack_from('<H', e, 20)[0], struct.unpack_from('<H', e, 26)[0]
            first = (hi << 16 | lo) if self.bits == 32 else lo
            size = struct.unpack_from('<I', e, 28)[0]
            if name in ('.', '..'):
                continue
            yield name, bool(e[11] & 0x10), first, size

    def find_dir(self, path):
        cluster = 0
        for part in [p for p in path.strip('/').split('/') if p]:
            for name, is_dir, first, _ in self.entries(cluster):
                if is_dir and name.lower() == part.lower():
                    cluster = first
                    break
            else:
                sys.exit(f'no directory {path}')
        return cluster


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    fat, cmd = Fat(sys.argv[1]), sys.argv[2]
    if cmd == 'list':
        for name, is_dir, _, size in fat.entries(fat.find_dir(sys.argv[3] if len(sys.argv) > 3 else '/')):
            print(f'{"d" if is_dir else "-"} {size:10} {name}')
    elif cmd == 'get' and len(sys.argv) == 6:
        d, pattern, outdir = sys.argv[3], sys.argv[4].lower(), sys.argv[5]
        os.makedirs(outdir, exist_ok=True)
        n = 0
        for name, is_dir, first, size in fat.entries(fat.find_dir(d)):
            if is_dir or not fnmatch.fnmatch(name.lower(), pattern) or '/' in name or name.startswith('.'):
                continue
            data = fat.read_chain(first, size) if size else b''
            if len(data) != size:
                sys.exit(f'{name}: short read ({len(data)} of {size})')
            with open(os.path.join(outdir, name), 'wb') as o:
                o.write(data)
            print(f'{name:24} {size:10}')
            n += 1
        if n == 0:
            sys.exit(f'no file matches {d}/{pattern}')
    else:
        sys.exit(__doc__)


if __name__ == '__main__':
    main()
