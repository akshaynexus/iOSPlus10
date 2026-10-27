#!/usr/bin/env python3
"""Pack the SLPI firmware into one file of the ADSP firmware area (kernel patch 0376, negroni_slpi.c).

  mkslpipak.py OUT.pak [DIR]      DIR default: out/firmware/slpi (scripts/sensors/extract-slpi-fw.sh)

The ADSP area table has 64 entries and the ADSP + camera files use 44 of them; the SLPI needs 26
more. So the SLPI files go into one area entry "slpi.pak" with its own table:
  bytes 0..4095 = "NEGRSLPI" | u32 1 | u32 count | 32 x {name[48], u32 offset, u32 size, sha256[32]}
  files from 4 KiB on, each 4 KiB aligned; offsets are relative to the pack start.
Content: slpi.mdt, slpi.bNN (non-empty), slpir.jsn, slpius.jsn. scripts/audio/mkadsparea.py adds
DIR/slpi.pak (out/firmware/adsp) to the area when it exists. Never commit OUT.pak (vendor firmware).
"""
import glob
import hashlib
import os
import struct
import sys

HEADER, BLOCK, MAX, LIMIT = 4096, 4096, 32, 12 << 20


def mdt_info(data):
    if data[:6] != b'\x7fELF\x01\x01':
        sys.exit('slpi.mdt: not an ELF32 LE header')
    phoff, = struct.unpack_from('<I', data, 28)
    phnum, = struct.unpack_from('<H', data, 44)
    low, high, reloc = None, 0, False
    for i in range(phnum):
        ptype, off, va, pa, filesz, memsz, flags = struct.unpack_from('<IIIIIII', data, phoff + 32 * i)
        if ptype == 1 and memsz and (flags >> 24) & 7 != 2:
            low = pa if low is None else min(low, pa)
            high = max(high, pa + memsz)
            reloc |= bool(flags >> 27 & 1)
    return phnum, low, high, reloc


def main():
    if len(sys.argv) not in (2, 3):
        sys.exit(__doc__)
    out = sys.argv[1]
    d = sys.argv[2] if len(sys.argv) == 3 else os.path.join(
        os.path.dirname(os.path.abspath(__file__)), '..', '..', 'out', 'firmware', 'slpi')
    files = sorted(glob.glob(os.path.join(d, 'slpi.mdt')) +
                   [f for f in glob.glob(os.path.join(d, 'slpi.b[0-9][0-9]')) if os.path.getsize(f) > 0] +
                   glob.glob(os.path.join(d, 'slpir.jsn')) + glob.glob(os.path.join(d, 'slpius.jsn')))
    if not any(f.endswith('slpi.mdt') for f in files):
        sys.exit(f'no slpi.mdt in {d} (run scripts/sensors/extract-slpi-fw.sh)')
    if len(files) > MAX:
        sys.exit(f'{len(files)} files, the pack holds {MAX}')
    pak, entries, at = bytearray(HEADER), [], HEADER
    for path in files:
        data = open(path, 'rb').read()
        name = os.path.basename(path).encode()
        if len(name) > 47:
            sys.exit(f'{path}: name too long')
        if path.endswith('slpi.mdt'):
            n, low, high, reloc = mdt_info(data)
            print(f'slpi.mdt: {n} program headers, load {low:#x}..{high:#x} ({(high - low) >> 10} KiB), '
                  f'relocatable {reloc}')
        pak += b'\0' * (at - len(pak)) + data
        entries.append(struct.pack('<48sII32s', name, at, len(data), hashlib.sha256(data).digest()))
        at = (at + len(data) + BLOCK - 1) & ~(BLOCK - 1)
    pak += b'\0' * (at - len(pak))
    if len(pak) > LIMIT:
        sys.exit(f'pack {len(pak)} bytes > {LIMIT} (kernel SLPI_PAK_MAX)')
    header = b'NEGRSLPI' + struct.pack('<II', 1, len(entries)) + b''.join(entries)
    assert len(header) <= HEADER
    pak[:len(header)] = header
    with open(out, 'wb') as o:
        o.write(pak)
    print(f'{out}: {len(entries)} files, {len(pak)} bytes, sha256 {hashlib.sha256(pak).hexdigest()}')


if __name__ == '__main__':
    main()
