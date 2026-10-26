#!/usr/bin/env python3
"""Build the QCA6490 Bluetooth firmware pack (kernel bsd/dev/negroni_bt_hci.c, patch 0331).

  mkbtpack.py OUT.bin [DIR]      DIR default: out/bt/firmware (scripts/bt/fetch-firmware.sh)

The pack is ONE file of the WLAN firmware area (scripts/wifi/mkwlanarea.py), named negroni-bt.bin; the kernel
finds it by that name in the area header, then reads the files inside it. Layout (little endian):
  bytes 0..16383   "NEGRBTFW" | u32 1 | u32 count | count x {name[48], u32 offset, u32 size, sha256[32]}
                   (at most 160 entries; offset is relative to the pack start)
  from 16384 on    the files, each 64-byte aligned
Content: every hp* file at the top of DIR (hpbtfw20/21.tlv rampatches, hpbtfw20.ver, ~102 hpnv* NVM files,
~1.1 MiB). The kernel loads hpbtfwNN.tlv and hpnvNN[g].bNN / .bin by the controller's ROM version and board id
and stops on a SHA-256 mismatch. Qualcomm proprietary firmware: never commit OUT.bin.
"""
import hashlib
import os
import struct
import sys

HEADER, ALIGN, MAX = 16384, 64, 160


def main():
    if len(sys.argv) not in (2, 3):
        sys.exit(__doc__)
    out = sys.argv[1]
    d = sys.argv[2] if len(sys.argv) == 3 else os.path.join(
        os.path.dirname(os.path.abspath(__file__)), '..', '..', 'out', 'bt', 'firmware')
    files = sorted(e.path for e in os.scandir(d) if e.is_file() and e.name.startswith('hp'))
    names = {os.path.basename(f) for f in files}
    if not {'hpbtfw21.tlv', 'hpnv21.bin'} <= names:
        sys.exit(f'no hpbtfw21.tlv or hpnv21.bin in {d} (run scripts/bt/fetch-firmware.sh)')
    if len(files) > MAX:
        sys.exit(f'{len(files)} files, the pack holds {MAX}')
    body, entries, at = bytearray(), [], HEADER
    for path in files:
        data = open(path, 'rb').read()
        name = os.path.basename(path).encode()
        if len(name) > 47:
            sys.exit(f'{path}: name too long')
        pad = (-at) % ALIGN
        body += b'\0' * pad
        at += pad
        entries.append(struct.pack('<48sII32s', name, at, len(data), hashlib.sha256(data).digest()))
        body += data
        at += len(data)
    header = b'NEGRBTFW' + struct.pack('<II', 1, len(entries)) + b''.join(entries)
    assert len(header) <= HEADER
    pack = header + b'\0' * (HEADER - len(header)) + body
    with open(out, 'wb') as o:
        o.write(pack)
    print(f'{out}: {len(entries)} files, {len(pack)} bytes, sha256 {hashlib.sha256(pack).hexdigest()}')


if __name__ == '__main__':
    main()
