#!/usr/bin/env python3
"""Check a negroni firmware area image against the kernel reader rules.

  checkarea.py gpu|adsp|wlan AREA.bin

Kernel readers (out/kernel/wt-wlan4/bsd/dev): negroni_ufs.c negroni_fw_load (gpu), negroni_adsp.c
(adsp, patch 0240), negroni_wlan.c (wlan, patch 0261). Every area: magic | u32 version 1 |
u32 count | count x {char name[48], u32 offset, u32 size, u8 sha256[32]} (88 bytes, little endian).
Checks: image size, magic, version, 0 < count <= max, header fits, offset >= header size, the file
inside the area, no overlap, SHA-256 of every file, the files the kernel asks for by name.
Exit 0 when all checks pass.
"""
import hashlib
import struct
import sys

KINDS = {  # size, header bytes (first file offset), max entries, magic, names the kernel needs
    'gpu': (8 << 20, 4096, 16, b'NEGRONFW',
            ('a730_zap.mdt', 'a730_zap.b00', 'a730_zap.b01', 'a730_zap.b02', 'a730_sqe.fw', 'gmu_gen70000.bin')),
    'adsp': (32 << 20, 8192, 64, b'NEGRADSP', ('adsp.mdt',)),
    'wlan': (32 << 20, 32768, 256, b'NEGRWLAN', ('m3.bin',)),
}


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in KINDS:
        sys.exit(__doc__)
    kind, path = sys.argv[1], sys.argv[2]
    size, header, cap, magic, need = KINDS[kind]
    a = open(path, 'rb').read()
    errs = []
    if len(a) != size:
        errs.append(f'size {len(a)} != {size}')
    if a[:8] != magic:
        sys.exit(f'{path}: magic {a[:8]!r} != {magic!r}')
    version, count = struct.unpack_from('<II', a, 8)
    if version != 1 or not 0 < count <= cap:
        sys.exit(f'{path}: version {version}, count {count} (max {cap})')
    if 16 + 88 * count > header:
        errs.append('header does not fit')
    names, spans = [], []
    for i in range(count):
        raw, off, n, digest = struct.unpack_from('<48sII32s', a, 16 + 88 * i)
        name = raw.split(b'\0')[0].decode()
        names.append(name)
        if off < header or off > size or n > size - off or n == 0:
            errs.append(f'{name}: offset {off:#x} size {n} out of range')
            continue
        if off % 4096:
            errs.append(f'{name}: offset {off:#x} not 4 KiB aligned')
        if hashlib.sha256(a[off:off + n]).digest() != digest:
            errs.append(f'{name}: SHA-256 mismatch')
        spans.append((off, off + n, name))
    spans.sort()
    for (_, e0, n0), (s1, _, n1) in zip(spans, spans[1:]):
        if s1 < e0:
            errs.append(f'{n0} overlaps {n1}')
    if kind == 'wlan' and not {'amss.bin', 'amss20.bin'} & set(names):
        errs.append('no amss.bin or amss20.bin')
    errs += [f'missing {n}' for n in need if n not in names]
    used = max(e for _, e, _ in spans) if spans else 0
    print(f'{path}: {kind} {count} files, {used} of {size} bytes used, sha256 {hashlib.sha256(a).hexdigest()}')
    for e in errs:
        print(f'  ERROR {e}')
    sys.exit(1 if errs else 0)


if __name__ == '__main__':
    main()
