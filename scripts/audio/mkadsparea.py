#!/usr/bin/env python3
"""Build the negroni ADSP firmware area (kernel bsd/dev/negroni_adsp.c, patch 0240).

  mkadsparea.py OUT.bin [DIR]      DIR default: out/firmware/adsp (scripts/audio/extract-adsp-fw.sh)

32 MiB: bytes 0..8191 = "NEGRADSP" | u32 1 | u32 count | 64 x {name[48], u32 offset, u32 size,
sha256[32]}; files from 8 KiB on, each 4 KiB aligned, named by their basename. Content: adsp.mdt,
adsp.bNN, *.jsn of DIR, and tfa-init.bin if present (the TFA9874 amp table for patch 0244:
scripts/audio/tfa-cnt.py bin writes it into DIR), and CAMERA_ICP.mdt + CAMERA_ICP.bNN if present (the
camera ICP firmware for patch 0316: scripts/camera/extract-icp-fw.sh copies them into DIR), and
slpi.pak if present (the SLPI firmware pack for patch 0376: scripts/sensors/extract-slpi-fw.sh writes
it into DIR; one entry with its own table, so the 64-entry table does not overflow).

Place on the phone (4096-byte blocks of the userdata partition, N = partition size in blocks):
  persistent log   N-1025 .. N-1         (negroni_ufs.c NEGRONI_LOG_BLOCKS = 1025)
  GPU fw area      N-3073 .. N-1026      (mkfwarea.py, 2048 blocks)
  ADSP fw area     N-11265 .. N-3074     (this file, 8192 blocks)
  -> dd if=OUT.bin of=/dev/block/by-name/userdata bs=4096 seek=$((N-11265)) conv=notrunc,fsync
Ask the owner before the write. `fastboot flash userdata` erases the area. Never commit OUT.bin.
"""
import glob
import hashlib
import os
import struct
import sys

SIZE, HEADER, BLOCK, MAX = 32 << 20, 8192, 4096, 64


def main():
    if len(sys.argv) not in (2, 3):
        sys.exit(__doc__)
    out = sys.argv[1]
    d = sys.argv[2] if len(sys.argv) == 3 else os.path.join(
        os.path.dirname(os.path.abspath(__file__)), '..', '..', 'out', 'firmware', 'adsp')
    files = sorted(glob.glob(os.path.join(d, 'adsp.mdt')) + glob.glob(os.path.join(d, 'adsp.b[0-9][0-9]')) +
                   glob.glob(os.path.join(d, '*.jsn')) + glob.glob(os.path.join(d, 'tfa-init.bin')) + glob.glob(os.path.join(d, 'slpi.pak')) +
                   glob.glob(os.path.join(d, 'CAMERA_ICP.mdt')) + [f for f in glob.glob(os.path.join(d, 'CAMERA_ICP.b[0-9][0-9]'))
                      if os.path.getsize(f) > 0])   # empty segment files: nothing to load
    if not any(f.endswith('adsp.mdt') for f in files):
        sys.exit(f'no adsp.mdt in {d} (run scripts/audio/extract-adsp-fw.sh)')
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
    header = b'NEGRADSP' + struct.pack('<II', 1, len(entries)) + b''.join(entries)
    assert len(header) <= HEADER
    area[:len(header)] = header
    with open(out, 'wb') as o:
        o.write(area)
    print(f'{out}: {len(entries)} files, {at} of {SIZE} bytes used, sha256 {hashlib.sha256(area).hexdigest()}')


if __name__ == '__main__':
    main()
