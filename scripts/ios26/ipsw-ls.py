#!/usr/bin/env python3
"""List the files in a remote IPSW (zip) with HTTP range reads only (a few hundred KiB).

   scripts/ios26/ipsw-ls.py URL [REGEX]

Prints size and name of each member (ZIP64 aware). Standard library only; macOS and Linux.
"""
import re, struct, sys, urllib.request

def get(url, start, end):
    req = urllib.request.Request(url, headers={"Range": f"bytes={start}-{end}"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read()

def size_of(url):
    req = urllib.request.Request(url, method="HEAD")
    with urllib.request.urlopen(req, timeout=60) as r:
        return int(r.headers["Content-Length"])

def main():
    url = sys.argv[1]
    pat = re.compile(sys.argv[2]) if len(sys.argv) > 2 else None
    total = size_of(url)
    tail = get(url, max(0, total - 65536 - 22), total - 1)
    eocd = tail.rfind(b"PK\x05\x06")
    cd_size, cd_off = struct.unpack_from("<II", tail, eocd + 12)
    loc = tail.rfind(b"PK\x06\x07")
    if loc >= 0:  # ZIP64
        (z64,) = struct.unpack_from("<Q", tail, loc + 8)
        rec = get(url, z64, z64 + 55)
        cd_size, cd_off = struct.unpack_from("<QQ", rec, 40)
    cd = get(url, cd_off, cd_off + cd_size - 1)
    p = 0
    while p + 46 <= len(cd) and cd[p:p + 4] == b"PK\x01\x02":
        csize, usize = struct.unpack_from("<II", cd, p + 20)
        nlen, elen, clen = struct.unpack_from("<HHH", cd, p + 28)
        name = cd[p + 46:p + 46 + nlen].decode("utf-8", "replace")
        extra = cd[p + 46 + nlen:p + 46 + nlen + elen]
        q = 0
        while q + 4 <= len(extra):
            hid, hlen = struct.unpack_from("<HH", extra, q)
            if hid == 1 and usize == 0xFFFFFFFF:
                (usize,) = struct.unpack_from("<Q", extra, q + 4)
            q += 4 + hlen
        if not pat or pat.search(name):
            print(f"{usize:>13} {name}")
        p += 46 + nlen + elen + clen

if __name__ == "__main__":
    main()
