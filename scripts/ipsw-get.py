#!/usr/bin/env python3
"""Download single members of a remote ZIP (an IPSW) with many parallel HTTP range requests.

    ipsw-get.py URL OUTDIR NAME [NAME ...] [-j 16] [--chunk-mib 32]

Reads the ZIP central directory with range requests, then fetches each wanted member:
- The member's (compressed) bytes are split into chunks; N worker threads fetch them with
  `curl -r` and write them in place (os.pwrite). Finished chunks are recorded in OUT.part.done,
  so an interrupted run resumes.
- Stored (method 0): that is the file. Deflated (method 8, the IPSW DMGs): the downloaded raw
  deflate stream is inflated locally into OUT, then removed.
The CRC-32 from the ZIP directory is checked before the file gets its final name.
"""
import argparse, os, struct, subprocess, sys, threading, zlib
from concurrent.futures import ThreadPoolExecutor, as_completed

def curl(url, start, end):
    r = subprocess.run(['curl', '-sfL', '--retry', '5', '--retry-all-errors', '--max-time', '600',
                        '-r', f'{start}-{end}', url], capture_output=True)
    if r.returncode or len(r.stdout) != end - start + 1:
        raise IOError(f'range {start}-{end}: curl {r.returncode}, {len(r.stdout)} bytes')
    return r.stdout

def size_of(url):
    out = subprocess.run(['curl', '-sfIL', url], capture_output=True, text=True, check=True).stdout
    return int([l for l in out.splitlines() if l.lower().startswith('content-length:')][-1].split(':')[1])

def central_directory(url):
    total = size_of(url)
    tail = curl(url, total - 65536 - 22, total - 1)
    i = tail.rfind(b'PK\x06\x06')                              # ZIP64 end record
    if i >= 0:
        cd_size, cd_off = struct.unpack_from('<QQ', tail, i + 40)
    else:
        i = tail.rfind(b'PK\x05\x06')
        cd_size, cd_off = struct.unpack_from('<II', tail, i + 12)
    cd = curl(url, cd_off, cd_off + cd_size - 1)
    entries, i = {}, 0
    while cd[i:i + 4] == b'PK\x01\x02':
        method, = struct.unpack_from('<H', cd, i + 10)
        crc, csize, usize = struct.unpack_from('<III', cd, i + 16)
        nlen, xlen, clen = struct.unpack_from('<HHH', cd, i + 28)
        lho, = struct.unpack_from('<I', cd, i + 42)
        name = cd[i + 46:i + 46 + nlen].decode()
        x = cd[i + 46 + nlen:i + 46 + nlen + xlen]
        j = 0
        while j + 4 <= len(x):                                 # ZIP64 extra field
            tag, ln = struct.unpack_from('<HH', x, j)
            if tag == 1:
                vals = list(struct.unpack_from('<' + 'Q' * (ln // 8), x, j + 4))
                if usize == 0xffffffff: usize = vals.pop(0)
                if csize == 0xffffffff: csize = vals.pop(0)
                if lho == 0xffffffff: lho = vals.pop(0)
            j += 4 + ln
        entries[name] = (method, crc, csize, usize, lho)
        i += 46 + nlen + xlen + clen
    return entries

def fetch(url, name, entry, outdir, jobs, chunk):
    method, crc, csize, usize, lho = entry
    hdr = curl(url, lho, lho + 29)
    nlen, xlen = struct.unpack_from('<HH', hdr, 26)
    data0 = lho + 30 + nlen + xlen
    out = os.path.join(outdir, os.path.basename(name))
    if os.path.exists(out) and os.path.getsize(out) == usize:
        print(f'{name}: already complete'); return out
    part = out + ('.part' if method == 0 else '.deflate.part')
    done_f = part + '.done'
    size = csize                                   # bytes to download (== usize when stored)
    fd = os.open(part, os.O_RDWR | os.O_CREAT)
    os.ftruncate(fd, size)
    done = set(int(l) for l in open(done_f)) if os.path.exists(done_f) else set()
    todo = [k for k in range((size + chunk - 1) // chunk) if k not in done]
    lock, got = threading.Lock(), [len(done) * chunk]
    def work(k):
        s = k * chunk; e = min(size, s + chunk) - 1
        os.pwrite(fd, curl(url, data0 + s, data0 + e), s)
        with lock:
            with open(done_f, 'a') as f: f.write(f'{k}\n')
            got[0] += e - s + 1
            print(f'{name}: {min(got[0], size) * 100 // size}% ({min(got[0], size) >> 20}/{size >> 20} MiB)', flush=True)
    with ThreadPoolExecutor(jobs) as ex:
        for f in as_completed([ex.submit(work, k) for k in todo]):
            f.result()
    os.close(fd)
    c = 0
    if method == 0:
        with open(part, 'rb') as f:
            while b := f.read(1 << 24): c = zlib.crc32(b, c)
        tmp = part
    else:
        print(f'{name}: inflating', flush=True)
        tmp = out + '.part'
        z = zlib.decompressobj(-15)
        with open(part, 'rb') as f, open(tmp, 'wb') as g:
            while b := f.read(1 << 24):
                d = z.decompress(b); c = zlib.crc32(d, c); g.write(d)
            d = z.flush(); c = zlib.crc32(d, c); g.write(d)
    if c != crc:
        os.remove(done_f); sys.exit(f'{name}: CRC-32 mismatch ({c:08x} != {crc:08x}); chunks reset')
    os.rename(tmp, out); os.remove(done_f)
    if method != 0: os.remove(part)
    print(f'{name}: {usize} bytes, CRC-32 ok -> {out}')
    return out

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('url'); ap.add_argument('outdir'); ap.add_argument('names', nargs='+')
    ap.add_argument('-j', type=int, default=16); ap.add_argument('--chunk-mib', type=int, default=32)
    a = ap.parse_args()
    os.makedirs(a.outdir, exist_ok=True)
    ents = central_directory(a.url)
    for want in a.names:
        name = next((n for n in ents if n == want or n.endswith('/' + want)), None)
        if not name: sys.exit(f'{want}: not in the archive')
        if ents[name][0] not in (0, 8): sys.exit(f'{name}: compression method {ents[name][0]} not supported')
        fetch(a.url, name, ents[name], a.outdir, a.j, a.chunk_mib << 20)

if __name__ == '__main__':
    main()
