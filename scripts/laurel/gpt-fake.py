#!/usr/bin/env python3
# Test fixture: a table in the layout of the Mi A3's LUN 0, made here from names and numbers (no bytes of a real table: the GUIDs are made up). Host test only.
#   gpt-fake.py dumps HEAD TAIL          the two 1 MiB dumps in the format of the backup
#   gpt-fake.py disk PATH [--raw-sb]     a sparse disk file of 30119936 blocks with that table and a fake f2fs superblock block at the start of userdata
#   gpt-fake.py check PATH               an independent reader, not op10tool: as Linux block/partitions/efi.c without "gpt=": a valid primary or no table. Prints "name first last" and the state of the backup
#   gpt-fake.py slot-change PATH         what ABL SwitchPtnSlots and the HAL do to a table: attributes of the _a/_b entries, the type GUIDs of each pair swapped, both copies, CRCs right
#   gpt-fake.py entry PATH NAME          from each copy: type GUID (hex) and attributes of NAME
#   gpt-fake.py block PATH LBA FILE N    block N of FILE to block LBA of PATH; FILE = garbage: 0x5a bytes
#   gpt-fake.py tablediff H1 T1 H2 T2    an independent diff of two dumps: each changed byte range of each table block, one line each
import struct, sys, zlib
B = 4096
DISK = 30119936
NAMES = ['ssd', 'persist', 'misc', 'keystore', 'frp', 'product_a', 'product_b', 'odm_a', 'odm_b', 'oem', 'minidump', 'system_a', 'system_b', 'metadata', 'userdata']
ENDS = [7, 8199, 8455, 8583, 8711, 74247, 139783, 172551, 205319, 221703, 254471, 1040903, 1827335, 1831431, 30119930]
def table():
    e = bytearray(B * 4)
    first = 6
    for i, n in enumerate(NAMES):
        s = bytes([i + 1]) * 16 + bytes([i + 100]) * 16 + struct.pack('<QQQ', first, ENDS[i], 0x7f000000000000 if n.endswith('_a') else 0)
        s += n.encode('utf-16-le').ljust(72, b'\0')
        e[i * 128:(i + 1) * 128] = s
        first = ENDS[i] + 1
    ec = zlib.crc32(bytes(e[:32 * 128]))
    def hdr(cur, alt, pe):
        h = bytearray(B)
        h[:8] = b'EFI PART'
        struct.pack_into('<IIIIQQQQ', h, 8, 0x10000, 92, 0, 0, cur, alt, 6, 30119930)
        h[56:72] = b'\x09' * 16
        struct.pack_into('<QIII', h, 72, pe, 32, 128, ec)
        struct.pack_into('<I', h, 16, zlib.crc32(bytes(h[:92])))
        return bytes(h)
    mbr = bytearray(B)
    mbr[446:462] = bytes.fromhex('00000100eeffffff01000000ffffffff')
    mbr[510:512] = b'\x55\xaa'
    return bytes(mbr), hdr(1, DISK - 1, 2), bytes(e), hdr(DISK - 1, 1, DISK - 5)
def fill(n, seed):
    return bytes((i * seed + 13) & 0xff for i in range(256)) * (n // 256)
def dumps():
    mbr, h, e, bh = table()
    head = mbr + h + e + fill(B * 250, 3)
    tail = fill(B * 251, 5) + e + bh
    return head, tail
c = sys.argv[1]
if c == 'dumps':
    a, b = dumps()
    open(sys.argv[2], 'wb').write(a); open(sys.argv[3], 'wb').write(b)
elif c == 'disk':
    a, b = dumps()
    with open(sys.argv[2], 'wb') as f:
        f.truncate(DISK * B)
        f.write(a)
        f.seek((DISK - 256) * B); f.write(b)
        f.seek(1831432 * B); f.write(fill(B * 2, 7))
        f.seek(21633536 * B); f.write(fill(B, 11))
elif c == 'slot-change':
    with open(sys.argv[2], 'r+b') as f:
        f.seek(2 * B); e = bytearray(f.read(32 * 128))
        names = [e[i * 128 + 56:(i + 1) * 128].decode('utf-16-le').rstrip('\0') for i in range(32)]
        for i, n in enumerate(names):
            if n.endswith('_a') or n.endswith('_b'):
                e[i * 128 + 48:i * 128 + 56] = struct.pack('<Q', 0x3f000000000000)
            if n.endswith('_a'):
                j = names.index(n[:-1] + 'b')
                e[i * 128:i * 128 + 16], e[j * 128:j * 128 + 16] = e[j * 128:j * 128 + 16], e[i * 128:i * 128 + 16]
        ec = zlib.crc32(bytes(e))
        for hlba, pe in ((1, 2), (DISK - 1, DISK - 5)):
            f.seek(pe * B); f.write(e)
            f.seek(hlba * B); h = bytearray(f.read(B))
            struct.pack_into('<I', h, 88, ec); h[16:20] = b'\0' * 4
            struct.pack_into('<I', h, 16, zlib.crc32(bytes(h[:92])))
            f.seek(hlba * B); f.write(h)
elif c == 'entry':
    with open(sys.argv[2], 'rb') as f:
        for pe in (2, DISK - 5):
            f.seek(pe * B); e = f.read(32 * 128)
            for i in range(32):
                if e[i * 128 + 56:(i + 1) * 128].decode('utf-16-le').rstrip('\0') == sys.argv[3]:
                    print(e[i * 128:i * 128 + 16].hex(), hex(struct.unpack_from('<Q', e, i * 128 + 48)[0]))
elif c == 'block':
    d = b'\x5a' * B if sys.argv[4] == 'garbage' else open(sys.argv[4], 'rb').read()[int(sys.argv[5]) * B:(int(sys.argv[5]) + 1) * B]
    with open(sys.argv[2], 'r+b') as f:
        f.seek(int(sys.argv[3]) * B); f.write(d)
elif c == 'tablediff':
    h1, t1, h2, t2 = (open(x, 'rb').read() for x in sys.argv[2:6])
    tb = lambda t, lba: t[(lba - (DISK - 256)) * B:(lba - (DISK - 255)) * B]
    for name, a, b in (('mbr', h1[:B], h2[:B]), ('primary-header', h1[B:2 * B], h2[B:2 * B]), ('primary-entries', h1[2 * B:6 * B], h2[2 * B:6 * B]),
                       ('backup-entries', t1[-5 * B:-B], t2[-5 * B:-B]), ('backup-header', t1[-B:], t2[-B:])):
        o = 0
        while o < len(a):
            if a[o] != b[o]:
                st = o
                while o < len(a) and a[o] != b[o]:
                    o += 1
                print(name, st, o - 1)
            else:
                o += 1
elif c == 'check':
    with open(sys.argv[2], 'rb') as f:
        f.seek(B); h = f.read(B)
        pe, n, sz, ec = struct.unpack_from('<QIII', h, 72)
        if h[:8] != b'EFI PART': pe, n, sz, ec = 2, 32, 128, 0     # a damaged header names nothing: its fields are not read
        f.seek(pe * B); e = f.read(n * sz)
        hc = bytearray(h[:92]); hc[16:20] = b'\0' * 4
        pri = h[:8] == b'EFI PART' and zlib.crc32(bytes(hc)) == struct.unpack_from('<I', h, 16)[0] and zlib.crc32(e) == ec
        f.seek((DISK - 1) * B); bh = f.read(B)
        bpe = struct.unpack_from('<Q', bh, 72)[0] if bh[:8] == b'EFI PART' else DISK - 5
        f.seek(bpe * B); be = f.read(n * sz)
        hc = bytearray(bh[:92]); hc[16:20] = b'\0' * 4
        bak = bh[:8] == b'EFI PART' and zlib.crc32(bytes(hc)) == struct.unpack_from('<I', bh, 16)[0] and zlib.crc32(be) == struct.unpack_from('<I', bh, 88)[0]
        print('primary', 'valid' if pri else 'INVALID', 'backup', 'valid' if bak else 'INVALID')
        for i in range(n):
            s = e[i * sz:(i + 1) * sz]
            if s[:16] == b'\0' * 16: continue
            print(s[56:128].decode('utf-16-le').rstrip('\0'), *struct.unpack_from('<QQ', s, 32))
        f.seek(1831432 * B); print('sb', 'zero' if not f.read(2 * B).strip(b'\0') else 'data')
