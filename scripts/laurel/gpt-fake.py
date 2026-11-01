#!/usr/bin/env python3
# Test fixture: a table in the layout of the Mi A3's LUN 0, made here from names and numbers (no bytes of a real table: the GUIDs are made up). Host test only.
#   gpt-fake.py dumps HEAD TAIL          the two 1 MiB dumps in the format of the backup
#   gpt-fake.py disk PATH [--raw-sb]     a sparse disk file of 30119936 blocks with that table and a fake f2fs superblock block at the start of userdata
#   gpt-fake.py check PATH               an independent reader, not op10tool: as Linux block/partitions/efi.c without "gpt=": a valid primary or no table. Prints "name first last" and the state of the backup
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
elif c == 'check':
    with open(sys.argv[2], 'rb') as f:
        f.seek(B); h = f.read(B)
        pe, n, sz, ec = struct.unpack_from('<QIII', h, 72)
        f.seek(pe * B); e = f.read(n * sz)
        hc = bytearray(h[:92]); hc[16:20] = b'\0' * 4
        pri = h[:8] == b'EFI PART' and zlib.crc32(bytes(hc)) == struct.unpack_from('<I', h, 16)[0] and zlib.crc32(e) == ec
        f.seek((DISK - 1) * B); bh = f.read(B)
        bpe = struct.unpack_from('<Q', bh, 72)[0]; f.seek(bpe * B); be = f.read(n * sz)
        hc = bytearray(bh[:92]); hc[16:20] = b'\0' * 4
        bak = bh[:8] == b'EFI PART' and zlib.crc32(bytes(hc)) == struct.unpack_from('<I', bh, 16)[0] and zlib.crc32(be) == struct.unpack_from('<I', bh, 88)[0]
        print('primary', 'valid' if pri else 'INVALID', 'backup', 'valid' if bak else 'INVALID')
        for i in range(n):
            s = e[i * sz:(i + 1) * sz]
            if s[:16] == b'\0' * 16: continue
            print(s[56:128].decode('utf-16-le').rstrip('\0'), *struct.unpack_from('<QQ', s, 32))
        f.seek(1831432 * B); print('sb', 'zero' if not f.read(2 * B).strip(b'\0') else 'data')
