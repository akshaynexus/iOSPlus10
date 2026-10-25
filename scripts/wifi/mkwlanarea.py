#!/usr/bin/env python3
"""Build the negroni WLAN firmware area (kernel bsd/dev/negroni_wlan.c, patch 0261).

  mkwlanarea.py OUT.bin [DIR]      DIR default: out/firmware/wlan (scripts/wifi/extract-fw.sh)

32 MiB: bytes 0..32767 = "NEGRWLAN" | u32 1 | u32 count | 256 x {name[48], u32 offset, u32 size,
sha256[32]}; files from 32 KiB on, each 4 KiB aligned, named by their basename. Content: every
regular file of DIR except LISTING.txt and SHA256SUMS (amss.bin, amss20.bin, m3.bin, regdb.bin and
the ~194 bdwlan.* board files, ~12 MiB). The kernel reads amss*.bin and m3.bin in stage 1; the
board files and regdb are for the stage 2 QMI BDF download.

Place on the phone (4096-byte blocks of the userdata partition, N = partition size in blocks):
  persistent log   N-1025 .. N-1          (negroni_ufs.c NEGRONI_LOG_BLOCKS = 1025)
  GPU fw area      N-3073 .. N-1026        (mkfwarea.py, 2048 blocks)
  ADSP fw area     N-11265 .. N-3074       (mkadsparea.py, 8192 blocks)
  WLAN fw area     N-19457 .. N-11266      (this file, 8192 blocks)
  -> dd if=OUT.bin of=/dev/block/by-name/userdata bs=4096 seek=$((N-19457)) conv=notrunc,fsync
Ask the owner before the write. `fastboot flash userdata` erases the area. Never commit OUT.bin.
"""
import hashlib
import os
import struct
import sys

SIZE, HEADER, BLOCK, MAX = 32 << 20, 32768, 4096, 256
SKIP = {'LISTING.txt', 'SHA256SUMS'}


def main():
    if len(sys.argv) not in (2, 3):
        sys.exit(__doc__)
    out = sys.argv[1]
    d = sys.argv[2] if len(sys.argv) == 3 else os.path.join(
        os.path.dirname(os.path.abspath(__file__)), '..', '..', 'out', 'firmware', 'wlan')
    files = sorted(e.path for e in os.scandir(d) if e.is_file() and e.name not in SKIP)
    if not any(os.path.basename(f) in ('amss.bin', 'amss20.bin') for f in files):
        sys.exit(f'no amss*.bin in {d} (run scripts/wifi/extract-fw.sh)')
    if len(files) > MAX:
        sys.exit(f'{len(files)} files, the area holds {MAX}')
    area = bytearray(SIZE)
    entries, at = [], HEADER
    for path in files:
        data = open(path, 'rb').read()
        name = os.path.basename(path).encode()
        if len(name) > 47 or at + len(data) > SIZE:
            sys.exit(f'{path}: name too long or area full')
        area[at:at + len(data)] = data
        entries.append(struct.pack('<48sII32s', name, at, len(data), hashlib.sha256(data).digest()))
        at = (at + len(data) + BLOCK - 1) & ~(BLOCK - 1)
    header = b'NEGRWLAN' + struct.pack('<II', 1, len(entries)) + b''.join(entries)
    assert len(header) <= HEADER
    area[:len(header)] = header
    with open(out, 'wb') as o:
        o.write(area)
    print(f'{out}: {len(entries)} files, {at} of {SIZE} bytes used, sha256 {hashlib.sha256(area).hexdigest()}')


if __name__ == '__main__':
    main()
