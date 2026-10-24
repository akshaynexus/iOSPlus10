#!/usr/bin/env python3
"""Raw image -> Android sparse image (libsparse format 1.0), like AOSP img2simg. Pure Python.

    img2simg.py IN.img OUT.simg [--block 4096]

- File holes (SEEK_HOLE, a sparse file such as the macOS root image) -> DONT_CARE chunks.
- Data blocks that repeat one 32-bit value (e.g. zeros) -> FILL chunks.
- Other blocks -> RAW chunks.
fastboot splits the result itself (`fastboot -S 512M flash ...`).
"""
import argparse, os, struct

MAGIC, RAW, FILL, DONT_CARE = 0xED26FF3A, 0xCAC1, 0xCAC2, 0xCAC3

def data_ranges(fd, size):
    """(start, end) of the data regions; the whole file if SEEK_DATA is not supported."""
    try:
        out, pos = [], 0
        while pos < size:
            try: s = os.lseek(fd, pos, os.SEEK_DATA)
            except OSError: break                          # no more data
            e = os.lseek(fd, s, os.SEEK_HOLE)
            out.append((s, e)); pos = e
        return out
    except (AttributeError, OSError):
        return [(0, size)]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('inp'); ap.add_argument('out'); ap.add_argument('--block', type=int, default=4096)
    a = ap.parse_args()
    B = a.block
    size = os.path.getsize(a.inp)
    assert size % B == 0, 'image size must be a multiple of the block size'
    total = size // B
    fd = os.open(a.inp, os.O_RDONLY)
    chunks = []                                            # (type, nblocks, payload or fill word)
    def add(t, n, p=None):
        if chunks and chunks[-1][0] == t and t in (DONT_CARE,) :
            chunks[-1] = (t, chunks[-1][1] + n, None); return
        if chunks and t == FILL and chunks[-1][0] == FILL and chunks[-1][2] == p:
            chunks[-1] = (t, chunks[-1][1] + n, p); return
        chunks.append((t, n, p))
    blk = 0
    for s, e in data_ranges(fd, size):
        s, e = s // B, -(-e // B)
        if s > blk: add(DONT_CARE, s - blk)
        os.lseek(fd, s * B, os.SEEK_SET)
        raw_run, raw_start = [], s
        for k in range(s, e):
            d = os.read(fd, B)
            w = d[:4]
            if d == w * (B // 4):
                if raw_run: chunks.append((RAW, len(raw_run), b''.join(raw_run))); raw_run = []
                add(FILL, 1, w)
            else:
                raw_run.append(d)
                if len(raw_run) == 4096:                   # 16 MiB raw chunks
                    chunks.append((RAW, len(raw_run), b''.join(raw_run))); raw_run = []
        if raw_run: chunks.append((RAW, len(raw_run), b''.join(raw_run)))
        blk = e
    if blk < total: add(DONT_CARE, total - blk)
    with open(a.out, 'wb') as f:
        f.write(struct.pack('<IHHHHIIII', MAGIC, 1, 0, 28, 12, B, total, len(chunks), 0))
        for t, n, p in chunks:
            body = p if t == RAW else (p if t == FILL else b'')
            f.write(struct.pack('<HHII', t, 0, n, 12 + len(body)))
            f.write(body)
    raw = sum(n for t, n, _ in chunks if t == RAW)
    print(f'{a.out}: {total} blocks, {len(chunks)} chunks, {raw * B >> 20} MiB raw data')

if __name__ == '__main__':
    main()
