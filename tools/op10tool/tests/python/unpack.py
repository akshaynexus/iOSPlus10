#!/usr/bin/env python3
"""Unpack a Qualcomm uefi.img (firmware volumes with gzip/LZMA GUID-defined sections).

    uefi-unpack.py uefi.img OUTDIR

Writes OUTDIR/<FILE_GUID>/ for each FFS file with:
    name.txt   UI name (if any)        type.txt   FFS file type (hex)
    pe32.efi / te.efi / depex.bin / raw.bin    section bodies (the first of each kind)
    file.bin   the whole file body (for raw FFS files without sections)
and OUTDIR/index.tsv (guid, type, name, sections). Pure Python, no external tools.
"""
import gzip, lzma, os, struct, sys, uuid

GZIP_GUID = uuid.UUID('1d301fe9-be79-4353-91c2-d23bc959ae0c').bytes_le
LZMA_GUID = uuid.UUID('ee4e5898-3914-4259-9d6e-dc7bd79403cf').bytes_le
SEC = {0x10: 'pe32.efi', 0x12: 'te.efi', 0x13: 'depex.bin', 0x19: 'raw.bin'}
# FFS types whose body is a section stream
SECTIONED = {0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f}

files = {}


def sections(buf):
    i = 0
    while i + 4 <= len(buf):
        size = int.from_bytes(buf[i:i + 3], 'little')
        typ = buf[i + 3]
        hdr = 4
        if size == 0xffffff:
            size = struct.unpack_from('<I', buf, i + 4)[0]
            hdr = 8
        if size < hdr or i + size > len(buf):
            break
        yield typ, buf[i + hdr:i + size]
        i = (i + size + 3) & ~3


def walk_sections(buf, rec):
    for typ, body in sections(buf):
        if typ == 0x15:
            rec.setdefault('name', body.decode('utf-16le', 'ignore').rstrip('\0'))
        elif typ in SEC:
            rec.setdefault(SEC[typ], body)
        elif typ == 0x17:                       # firmware volume image
            walk_fv(body)
        elif typ == 0x02:                       # GUID-defined (compressed)
            guid, off = body[:16], struct.unpack_from('<H', body, 16)[0] - 4
            data = body[off:] if off > 0 else body[20:]
            if guid == GZIP_GUID:
                walk_sections(gzip.decompress(data), rec)
            elif guid == LZMA_GUID:
                walk_sections(lzma.decompress(data, format=lzma.FORMAT_ALONE), rec)
        elif typ == 0x01:                       # compression section, type 0 = none
            if body[4] == 0:
                walk_sections(body[5:], rec)


def walk_fv(fv):
    if fv[40:44] != b'_FVH':
        return
    flen = struct.unpack_from('<Q', fv, 32)[0]
    i = struct.unpack_from('<H', fv, 48)[0]
    ext = struct.unpack_from('<H', fv, 52)[0]       # extended header offset
    if ext:
        i = ext + struct.unpack_from('<I', fv, ext + 16)[0]
    end = min(flen, len(fv))
    while i + 24 <= end:
        i = (i + 7) & ~7
        if fv[i:i + 24] == b'\xff' * 24:
            break
        guid = str(uuid.UUID(bytes_le=bytes(fv[i:i + 16]))).upper()
        ftype, attr = fv[i + 18], fv[i + 19]
        size, hdr = int.from_bytes(fv[i + 20:i + 23], 'little'), 24
        if attr & 0x01:                             # FFS_ATTRIB_LARGE_FILE
            size, hdr = struct.unpack_from('<Q', fv, i + 24)[0], 32
        if size < hdr:
            break
        body = fv[i + hdr:i + size]
        if ftype != 0xf0:                           # skip pad files
            rec = files.setdefault(guid, {'type': ftype})
            if ftype in SECTIONED:
                walk_sections(body, rec)
            else:
                rec.setdefault('file.bin', body)
        i += size


def main():
    img, out = sys.argv[1], sys.argv[2]
    data = open(img, 'rb').read()
    i = data.find(b'_FVH')
    while i != -1:
        if i >= 40:
            walk_fv(data[i - 40:])
        i = data.find(b'_FVH', i + 4)
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, 'index.tsv'), 'w') as idx:
        for guid, rec in sorted(files.items(), key=lambda kv: kv[1].get('name', '~')):
            d = os.path.join(out, guid)
            os.makedirs(d, exist_ok=True)
            secs = []
            for k, v in rec.items():
                if k == 'type':
                    open(os.path.join(d, 'type.txt'), 'w').write(f'{v:#04x}\n')
                elif k == 'name':
                    open(os.path.join(d, 'name.txt'), 'w').write(v + '\n')
                else:
                    open(os.path.join(d, k), 'wb').write(v)
                    secs.append(k)
            idx.write(f"{guid}\t{rec['type']:#04x}\t{rec.get('name', '')}\t{','.join(secs)}\n")
    named = sum(1 for r in files.values() if 'name' in r)
    pe = sum(1 for r in files.values() if 'pe32.efi' in r or 'te.efi' in r)
    print(f'{len(files)} files, {named} named, {pe} with code -> {out}')


if __name__ == '__main__':
    main()
