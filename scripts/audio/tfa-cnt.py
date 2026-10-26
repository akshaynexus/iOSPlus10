#!/usr/bin/env python3
"""Read the stock TFA98xx container (odm/firmware/tfa98xx.cnt) and make tfa-init.bin for the kernel
amp code (bsd/dev/negroni_tfa.c, patch 0244). Read-only on the input. Never commit the output.

  tfa-cnt.py dump [CNT]          list devices, profiles and items
  tfa-cnt.py bin  [CNT] [OUT]    write OUT (default out/firmware/adsp/tfa-init.bin), then
                                 scripts/audio/mkadsparea.py packs it into the ADSP firmware area

CNT default: out/audio-src/odm/firmware/tfa98xx.cnt (scripts/audio/extract-vendor-audio.sh).

Container layout (OnePlus tfa98xx-v6 driver, tfa98xx_parameters.h, packed): 46-byte header
(id "PM", version, subversion, u32 size, u32 CRC = zlib crc32 of the bytes after the CRC field
up to `size`, u16 rev, customer[8], application[8], type[8], u16 ndev, u16 nprof, u16 nlive),
then an index of u32 descriptors {offset:24, type:8}. A device list = {u8 length, bus, dev
(I2C address), func, u32 devid, desc name, desc list[length]}; a profile list = {u32 length:8,
group:8, ID:16, desc name, desc list[length-1]}. Bitfield item = {u16 value, u16 field};
register item = {u8 address, u16 value, u16 mask}.

The kernel writes what the vendor driver writes at a cold start (tfa_dsp_v6.c tfaRunStartup_v6):
the device items until the first patch/file/profile item (tfaContWriteRegsDev), then the
profile items until the "default" marker (tfaContWriteRegsProf). Only bitfield and register
items are written; this script keeps exactly those, in order.

tfa-init.bin (little endian):
  "NTFA" | u32 version 1 | u32 nprof | u32 nrec
  nprof x char name[16]                          (profile names, index = profile id below)
  nrec x {u8 i2c_addr, u8 prof (0xff = device), u8 kind (1 bitfield, 2 register), u8 reg,
          u16 field, u16 value, u16 mask, u16 0}
"""
import os
import struct
import sys
import zlib

DSC = ['Device', 'Profile', 'Register', 'String', 'File', 'Patch', 'Marker', 'Mode', 'SetInputSelect',
       'SetOutputSelect', 'SetProgramConfig', 'SetLagW', 'SetGains', 'SetvBatFactors', 'SetSensesCal',
       'SetSensesDelay', 'Bitfield', 'Default', 'LiveData', 'LiveDataString', 'Group', 'Cmd', 'SetMBDrc',
       'Filter', 'NoInit', 'Features', 'CfMem', 'SetFwkUseCase', 'SetVddpConfig']
D_PROFILE, D_REGISTER, D_STRING, D_FILE, D_PATCH, D_BITFIELD, D_DEFAULT = 1, 2, 3, 4, 5, 16, 17
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.join(HERE, '..', '..')
# TFA9874 bitfield names (tfa9874_tfafieldnames.h) for the dump; the kernel needs only the numbers
NAMES = {0x0000: 'PWDN', 0x0010: 'I2CR', 0x0030: 'AMPE', 0x0040: 'DCA', 0x0120: 'MANSCONF', 0x0203: 'AUDFS',
         0x0240: 'INPLEV', 0x0255: 'FRACTDEL', 0x20c3: 'TDMNBCK', 0x2103: 'TDMSLOTS', 0x2144: 'TDMSLLN',
         0x2224: 'TDMSSIZE', 0x2040: 'TDME', 0x2300: 'TDMSPKE', 0x2310: 'TDMDCE', 0x2330: 'TDMCSE',
         0x2340: 'TDMVSE', 0x2603: 'TDMSPKS', 0x2643: 'TDMDCS', 0x26c3: 'TDMCSS', 0x2703: 'TDMVSS',
         0x5257: 'AMPGAIN', 0x6163: 'TDMSPKG', 0x6123: 'TDMDCG', 0x7033: 'DCMCC', 0x7090: 'DCIE',
         0x7635: 'DCVOF', 0x7695: 'DCVOS', 0x5023: 'BSST', 0x50f0: 'BSSBY', 0x5150: 'HPFBYP',
         0x2073: 'TDMFSLN', 0x20b0: 'TDMFSPOL', 0x2050: 'TDMMODE', 0x2060: 'TDMCLINV', 0x21e0: 'TDMDEL',
         0x21f0: 'TDMADJ', 0x2194: 'TDMBRMG', 0x5001: 'BSSCR', 0x5061: 'BSSRL', 0x5222: 'CLIPCTRL',
         0x7444: 'DCTRIP', 0x7494: 'DCHOLD', 0x7534: 'DCTRIP2', 0x7584: 'DCTRIPT', 0x7430: 'DCTRACK',
         0x62e1: 'LNMODE', 0x64e1: 'LPM1MODE', 0x6802: 'TDMSRCMAP', 0x0140: 'MANAOOSC', 0x01d0: 'MUTETO'}


def desc(word):
    return word & 0xffffff, word >> 24


def string_at(c, off):
    end = c.index(b'\0', off)
    return c[off:end].decode('ascii', 'replace')


def parse(path):
    c = open(path, 'rb').read()
    hdr = struct.unpack_from('<2s2s2sIIH8s8s8sHHH', c, 0)
    ident, ver, sub, size, crc, rev, cust, app, typ, ndev, nprof, nlive = hdr
    if ident != b'PM':
        sys.exit(f'{path}: id {ident!r}, not a "PM" container')
    if size > len(c):
        sys.exit(f'{path}: size field {size} > file {len(c)}')
    calc = zlib.crc32(c[14:size]) & 0xffffffff
    if calc != crc:
        sys.exit(f'{path}: CRC {calc:#010x} != {crc:#010x}')
    info = dict(version=(ver + sub).decode(), size=size, crc=crc, customer=cust.rstrip(b'\0').decode(),
                application=app.rstrip(b'\0').decode(), type=typ.rstrip(b'\0').decode(), ndev=ndev, nprof=nprof)
    index = struct.unpack_from(f'<{ndev + nprof + nlive}I', c, 46)
    devs = []
    for i in range(ndev):
        off, t = desc(index[i])
        if t != 0:
            sys.exit(f'index {i}: type {t}, not a device list')
        length, bus, addr, func, devid, name = struct.unpack_from('<BBBBII', c, off)
        items = [desc(w) for w in struct.unpack_from(f'<{length}I', c, off + 12)]
        nm_off, _ = desc(name)
        devs.append(dict(addr=addr, bus=bus, func=func, devid=devid, name=string_at(c, nm_off), items=items))
    return c, info, devs


def item_text(c, off, t):
    if t == D_BITFIELD:
        value, field = struct.unpack_from('<HH', c, off)
        return f'bitfield {NAMES.get(field, "?"):9s} {field:#06x} (reg {field >> 8:#04x} bits ' \
               f'{(field >> 4) & 15}+{(field & 15) + 1}) = {value}'
    if t == D_REGISTER:
        addr, value, mask = struct.unpack_from('<BHH', c, off)
        return f'register {addr:#04x} = {value:#06x} mask {mask:#06x}'
    if t in (D_STRING, D_FILE, D_PATCH):
        return f'{DSC[t]} at {off:#x}'
    return f'{DSC[t] if t < len(DSC) else t} at {off:#x}'


def profile(c, off):
    w, name = struct.unpack_from('<II', c, off)
    length, group, pid = w & 0xff, (w >> 8) & 0xff, w >> 16
    items = [desc(x) for x in struct.unpack_from(f'<{max(length - 1, 0)}I', c, off + 8)]
    return dict(name=string_at(c, desc(name)[0]), group=group, id=pid, items=items)


def writes(c, items, stop):
    """bitfield/register items until an item type in stop (vendor ContWriteRegs order)"""
    out = []
    for off, t in items:
        if t in stop:
            break
        if t == D_BITFIELD:
            value, field = struct.unpack_from('<HH', c, off)
            out.append((1, field >> 8, field, value, 0))
        elif t == D_REGISTER:
            addr, value, mask = struct.unpack_from('<BHH', c, off)
            out.append((2, addr, 0, value, mask))
    return out


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in ('dump', 'bin'):
        sys.exit(__doc__)
    cnt = sys.argv[2] if len(sys.argv) > 2 else os.path.join(REPO, 'out', 'audio-src', 'odm', 'firmware', 'tfa98xx.cnt')
    c, info, devs = parse(cnt)
    if sys.argv[1] == 'dump':
        print(f'{cnt}: {info}')
        for d in devs:
            print(f'device "{d["name"]}" i2c {d["addr"]:#04x} bus {d["bus"]} devid {d["devid"]:#x}, {len(d["items"])} items')
            for off, t in d['items']:
                if t == D_PROFILE:
                    p = profile(c, off)
                    print(f'  profile "{p["name"]}" group {p["group"]} id {p["id"]}, {len(p["items"])} items')
                    for poff, pt in p['items']:
                        print(f'    {item_text(c, poff, pt)}')
                else:
                    print(f'  {item_text(c, off, t)}')
        return
    out = sys.argv[3] if len(sys.argv) > 3 else os.path.join(REPO, 'out', 'firmware', 'adsp', 'tfa-init.bin')
    names, recs = [], []
    for d in devs:
        if d['bus'] != 0:
            continue                          # not an I2C device (the vendor startup skips it too)
        for kind, reg, field, value, mask in writes(c, d['items'], (D_PATCH, D_FILE, D_PROFILE)):
            recs.append(struct.pack('<BBBBHHHH', d['addr'], 0xff, kind, reg, field, value, mask, 0))
        for off, t in d['items']:
            if t != D_PROFILE:
                continue
            p = profile(c, off)
            if p['name'] not in names:
                names.append(p['name'])
            pid = names.index(p['name'])
            for kind, reg, field, value, mask in writes(c, p['items'], (D_DEFAULT,)):
                recs.append(struct.pack('<BBBBHHHH', d['addr'], pid, kind, reg, field, value, mask, 0))
    if any(len(n.encode()) > 15 for n in names):
        sys.exit('a profile name is longer than 15 bytes')
    blob = b'NTFA' + struct.pack('<III', 1, len(names), len(recs)) + \
        b''.join(n.encode().ljust(16, b'\0') for n in names) + b''.join(recs)
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    with open(out, 'wb') as o:
        o.write(blob)
    print(f'{out}: {len(names)} profiles {names}, {len(recs)} writes, {len(blob)} bytes')


if __name__ == '__main__':
    main()
