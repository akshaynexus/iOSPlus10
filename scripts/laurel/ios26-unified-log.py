#!/usr/bin/env python3
"""Read a copy of an iOS unified log with no Apple tool: ios26-unified-log.py DIAGNOSTICS_DIR UUIDTEXT_DIR [REGEX] > text.
One line per firehose record: pid, process, format string where it can be found (dsc or main image), then the C strings of the record.
Copy of the phone's files, read-only: `tar cf - diagnostics uuidtext` in /var/db over SSH. Run with python3 -I. Host only."""
import bisect, glob, os, re, struct, sys


def lz4(src):
    out = bytearray(); i = 0; n = len(src)
    while i < n:
        t = src[i]; i += 1
        l = t >> 4
        if l == 15:
            while True:
                b = src[i]; i += 1; l += b
                if b != 255: break
        out += src[i:i + l]; i += l
        if i >= n: break
        o = src[i] | src[i + 1] << 8; i += 2
        m = t & 15
        if m == 15:
            while True:
                b = src[i]; i += 1; m += b
                if b != 255: break
        m += 4
        p = len(out) - o
        if o >= m:
            out += out[p:p + m]
        else:
            for k in range(m): out.append(out[p + k])
    return bytes(out)


def chunks(b):
    i = 0
    while i + 16 <= len(b):
        tag, sub, sz = struct.unpack_from('<IIQ', b, i)
        yield tag, sub, b[i + 16:i + 16 + sz]
        i = (i + 16 + sz + 7) & ~7


class Catalog:
    """Process list of one catalog chunk: (first, second proc id) -> pid, main uuid, dsc uuid."""
    def __init__(self, d):
        self.procs = {}
        subsys_off, procs_off, nprocs, sub_off = struct.unpack_from('<HHHH', d, 0)
        self.uuids = [d[24 + i * 16:40 + i * 16].hex().upper() for i in range(subsys_off // 16)]
        p = 24 + procs_off
        for _ in range(nprocs):
            idx, unk, main, dsc, first, second, pid, euid = struct.unpack_from('<HHHHQIII', d, p)
            self.procs[(first, second)] = (pid, main, dsc, euid)
            p += 32
            n1 = struct.unpack_from('<I', d, p)[0]; p += 8 + n1 * 16   # uuid entries: number + pad, then entries
            n2 = struct.unpack_from('<I', d, p)[0]; p += 8 + n2 * 6
            p = (p + 7) & ~7


def image_name(uu, root):
    try:
        with open(os.path.join(root, uu[:2], uu[2:]), 'rb') as f:
            b = f.read()
    except OSError:
        return uu[:8]
    e = b.rstrip(b'\0').rsplit(b'\0', 1)[-1]
    return e.decode('utf8', 'replace').rsplit('/', 1)[-1] or uu[:8]


def strs(b):
    return [m.group().decode('utf8', 'replace') for m in re.finditer(rb'[\x20-\x7e\t\n]{4,}', b)]


def run(diag, ut, pat):
    rx = re.compile(pat) if pat else None
    names = {}
    for path in sorted(glob.glob(os.path.join(diag, 'Persist', '*.tracev3')) + glob.glob(os.path.join(diag, 'Special', '*.tracev3'))):
        b = open(path, 'rb').read()
        cat = None
        for tag, sub, d in chunks(b):
            if tag == 0x600b:
                try: cat = Catalog(d)
                except struct.error: cat = None
            if tag != 0x600d or d[:4] not in (b'bv41', b'bv4-'):
                continue
            if d[:4] == b'bv41':
                cs = struct.unpack_from('<I', d, 8)[0]; u = lz4(d[12:12 + cs])
            else:
                us = struct.unpack_from('<I', d, 4)[0]; u = d[8:8 + us]
            for t2, s2, e in chunks(u):
                if t2 != 0x6001:
                    continue
                first, second = struct.unpack_from('<QI', e, 0)
                base = struct.unpack_from('<Q', e, 24)[0]
                pub = struct.unpack_from('<H', e, 16)[0]
                info = cat.procs.get((first, second)) if cat else None
                pid = info[0] if info else 0
                if info:
                    uu = cat.uuids[info[1]] if info[1] < len(cat.uuids) else ''
                    name = names.setdefault(uu, image_name(uu, ut))
                else:
                    name = '?'
                i = 32; end = 32 + pub - 16
                while i + 24 <= min(end, len(e)):
                    atype, ltype, flags, loc, tid, dlo, dhi, sz = struct.unpack_from('<BBHIQIHH', e, i)
                    data = e[i + 24:i + 24 + sz]
                    i += 24 + ((sz + 7) & ~7)
                    if atype != 4:
                        continue
                    t = base + (dlo | dhi << 32)
                    ss = strs(data)
                    if not ss:
                        continue
                    line = f'{t} {pid} {name} L{ltype}: ' + ' | '.join(s.replace('\n', ' ') for s in ss)
                    if rx is None or rx.search(line):
                        print(line)


if __name__ == '__main__':
    run(sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else None)
