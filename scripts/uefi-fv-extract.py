import sys, struct, lzma, uuid, os
data = open(sys.argv[1],'rb').read(); out = sys.argv[2]
LZMA = uuid.UUID('EE4E5898-3914-4259-9D6E-DC7BD79403CF').bytes_le
found = {}
GZ = uuid.UUID('1d301fe9-be79-4353-91c2-d23bc959ae0c').bytes_le
def sections(buf, name=None):
    i = 0
    while i + 4 <= len(buf):
        sz = int.from_bytes(buf[i:i+3],'little'); t = buf[i+3]
        hdr = 4
        if sz == 0xffffff: sz = int.from_bytes(buf[i+4:i+8],'little'); hdr = 8
        if sz < hdr: break
        body = buf[i+hdr:i+sz]
        yield t, body
        i = (i + sz + 3) & ~3
def walk_fv(fv, depth=0):
    if fv[40:44] != b'_FVH': return
    hlen = struct.unpack_from('<H', fv, 48)[0]; flen = struct.unpack_from('<Q', fv, 32)[0]
    i = hlen
    while i + 24 <= min(flen, len(fv)):
        if fv[i+18] == 0xff and fv[i+20:i+23] == b'\xff'*3: break
        sz = int.from_bytes(fv[i+20:i+23],'little'); ftype = fv[i+18]
        if sz < 24: break
        handle_file(fv[i+24:i+sz], depth)
        i = (i + sz + 7) & ~7
def handle_file(body, depth):
    name=None; pe=None
    for t, s in sections(body):
        if t == 0x15: name = s.decode('utf-16le','ignore').rstrip('\0')
        elif t == 0x10: pe = s
        elif t == 0x17: walk_fv(s, depth+1)
        elif t == 0x02 and s[:16] == GZ:
            import gzip
            dec = gzip.decompress(s[20:])
            for t2, s2 in sections(dec):
                if t2 == 0x17: walk_fv(s2, depth+1)
        elif t == 0x02 and s[:16] == LZMA:
            off = struct.unpack_from('<H', s, 16)[0]
            raw = s[off-4:] if False else s[20-4+4:]
            try: dec = lzma.decompress(s[20:], format=lzma.FORMAT_ALONE)
            except Exception as e:
                try: dec = lzma.decompress(s[off-4:], format=lzma.FORMAT_ALONE)
                except Exception as e2: print('lzma fail', e2); continue
            for t2, s2 in sections(dec):
                if t2 == 0x17: walk_fv(s2, depth+1)
                elif t2 == 0x15: name = s2.decode('utf-16le','ignore').rstrip('\0')
                elif t2 == 0x10: pe = s2
    if name and pe:
        open(os.path.join(out, name + '.efi'),'wb').write(pe); found[name]=len(pe)
i = data.find(b'_FVH')
while i != -1:
    walk_fv(data[i-40:]); i = data.find(b'_FVH', i+4)
print(len(found)); print(' '.join(sorted(found)))
