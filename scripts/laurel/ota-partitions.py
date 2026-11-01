#!/usr/bin/env python3
"""List the partitions an A/B OTA zip writes (payload.bin manifest), without unpacking it.

  python3 -I scripts/laurel/ota-partitions.py OTA.zip [STOCK_IMAGES_DIR]

Why: a sideload or an Updater install writes each listed partition on the inactive slot. Dual boot
(docs/laurel_sprout/dual-boot.md) needs to know what slot a got and what slot b kept. Read-only.
"""
import hashlib
import os
import struct
import sys
import zipfile

# partition -> file name in the Xiaomi fastboot ROM images/ folder (flash_all.sh)
STOCK = {
    'abl': 'abl.elf', 'bluetooth': 'BTFM.bin', 'cmnlib': 'cmnlib.mbn', 'cmnlib64': 'cmnlib64.mbn', 'devcfg': 'devcfg.mbn',
    'dsp': 'dspso.bin', 'dtbo': 'dtbo.img', 'hyp': 'hyp.mbn', 'imagefv': 'imagefv.elf', 'keymaster': 'km4.mbn',
    'modem': 'NON-HLOS.bin', 'qupfw': 'qupv3fw.elf', 'rpm': 'rpm.mbn', 'storsec': 'storsec.mbn', 'tz': 'tz.mbn',
    'uefisecapp': 'uefi_sec.mbn', 'vbmeta': 'vbmeta.img', 'xbl': 'xbl.elf', 'xbl_config': 'xbl_config.elf',
}


def stock_state(folder, name, size, want):
    """same / differs / no stock file. Same means: the OTA's partition hash is the stock file's hash."""
    fn = STOCK.get(name)
    if not folder or not fn or not os.path.exists(os.path.join(folder, fn)):
        return ''
    h = hashlib.sha256()
    total = 0
    with open(os.path.join(folder, fn), 'rb') as f:
        while True:
            b = f.read(1 << 20)
            if not b:
                break
            h.update(b)
            total += len(b)
    # update_engine hashes the whole partition image: a stock file shorter than it is padded with zeros to 4 KiB blocks
    pad = size - total
    if 0 <= pad < 4096:
        h.update(bytes(pad))
    if h.digest() == want:
        return f'same as stock {fn}' + (f' + {pad} bytes of padding' if pad else '')
    return f'differs from stock {fn} ({total} bytes)'


def varint(b, i):
    s = v = 0
    while True:
        c = b[i]
        i += 1
        v |= (c & 0x7f) << s
        s += 7
        if not c & 0x80:
            return v, i


def fields(b):
    i = 0
    while i < len(b):
        k, i = varint(b, i)
        fn, wt = k >> 3, k & 7
        if wt == 0:
            v, i = varint(b, i)
        elif wt == 2:
            n, i = varint(b, i)
            v = b[i:i + n]
            i += n
        elif wt == 1:
            v = b[i:i + 8]
            i += 8
        elif wt == 5:
            v = b[i:i + 4]
            i += 4
        else:
            raise ValueError(f'wire type {wt}')
        yield fn, v


def main():
    if len(sys.argv) not in (2, 3):
        sys.exit(__doc__)
    folder = sys.argv[2] if len(sys.argv) == 3 else None
    with zipfile.ZipFile(sys.argv[1]) as z, z.open('payload.bin') as f:
        magic, ver, msize, _sig = struct.unpack('>4sQQI', f.read(24))
        if magic != b'CrAU':
            sys.exit('ota-partitions: payload.bin has no CrAU magic')
        manifest = f.read(msize)
    print(f'payload version {ver}, manifest {msize} bytes')
    for fn, v in fields(manifest):
        if fn != 13:        # DeltaArchiveManifest.partitions
            continue
        name, size, want = None, None, b''
        for a, c in fields(v):
            if a == 1:      # partition_name
                name = c.decode()
            elif a == 7:    # new_partition_info
                for x, y in fields(c):
                    if x == 1:
                        size = y
                    elif x == 2:
                        want = y
        print(f'{name:16} {size:>12}  {want.hex()[:16]}  {stock_state(folder, name, size, want)}')


if __name__ == '__main__':
    main()
