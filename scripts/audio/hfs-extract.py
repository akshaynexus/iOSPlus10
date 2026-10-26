#!/usr/bin/env python3
"""Read-only extractor: files from an HFS+ volume inside an Android sparse image (or a raw image).

  python3 -I scripts/audio/hfs-extract.py IMAGE OUTDIR /path/in/volume [/more/paths ...]

Each path may be a file or a folder (a folder is copied recursively). The image is never written.
Use: the 20H392 root (~/op10-apple/ios16-root.simg) without a 16 GiB raw copy, e.g. the HAL
plug-ins for the mediaserverd crash analysis:

  python3 -I scripts/audio/hfs-extract.py ~/op10-apple/ios16-root.simg out/audio/hal-plugins \
      /System/Library/Audio/Plug-Ins/HAL /Library/Audio/Plug-Ins

Supports: sparse chunks RAW/FILL/DONT_CARE, the catalog B-tree (descent by parent ID only, so no
Unicode name ordering is needed), the extents overflow file, decmpfs compression types 3/4 (zlib)
and 7/8, 11/12 (LZVN, LZFSE: decoded with macOS libcompression when it is there). Files go to
OUTDIR (keep it git-ignored: Apple binaries never go into git).

Not supported: HFS+ hard links (their catalog entry points into the hidden private-data
directory) come out as empty files; symlinks are not followed.
"""
import ctypes
import ctypes.util
import os
import struct
import sys
import zlib


class Image:
    def __init__(self, path):
        self.f = open(path, "rb")
        h = self.f.read(28)
        self.chunks = None
        if len(h) == 28 and struct.unpack_from("<I", h)[0] == 0xED26FF3A:
            _, _, _, fhs, chs, bs, tb, tc, _ = struct.unpack("<IHHHHIIII", h)
            self.bs = bs
            self.chunks = []        # (first block, blocks, kind, file offset or fill)
            at = fhs
            blk = 0
            for _ in range(tc):
                self.f.seek(at)
                kind, _, n, total = struct.unpack("<HHII", self.f.read(12))
                data = at + chs
                if kind == 0xCAC1:
                    self.chunks.append((blk, n, "raw", data))
                elif kind == 0xCAC2:
                    self.f.seek(data)
                    self.chunks.append((blk, n, "fill", self.f.read(4)))
                elif kind == 0xCAC3:
                    self.chunks.append((blk, n, "none", None))
                if kind != 0xCAC4:
                    blk += n
                at += total
            self.starts = [c[0] for c in self.chunks]

    def read(self, off, size):
        if self.chunks is None:
            self.f.seek(off)
            return self.f.read(size)
        import bisect
        out = bytearray()
        while size > 0:
            blk = off // self.bs
            i = bisect.bisect_right(self.starts, blk) - 1
            first, n, kind, x = self.chunks[i]
            end = (first + n) * self.bs
            take = min(size, end - off)
            if kind == "raw":
                self.f.seek(x + off - first * self.bs)
                out += self.f.read(take)
            elif kind == "fill":
                rel = (off - first * self.bs) % 4
                out += (x * ((take + rel) // 4 + 2))[rel:rel + take]
            else:
                out += bytes(take)
            off += take
            size -= take
        return bytes(out)


def fork(b):
    size, _, blocks = struct.unpack_from(">QII", b, 0)
    ext = [struct.unpack_from(">II", b, 16 + 8 * i) for i in range(8)]
    return size, blocks, [e for e in ext if e[1]]


class HFS:
    def __init__(self, img):
        self.img = img
        vh = img.read(1024, 512)
        if vh[:2] not in (b"H+", b"HX"):
            raise SystemExit("no HFS+ volume header at 1024 (%r)" % vh[:2])
        self.bs = struct.unpack_from(">I", vh, 40)[0]
        self.ext_fork = fork(vh[0xC0:0x110])
        self.cat_fork = fork(vh[0x110:0x160])
        self.attr_fork = fork(vh[0x160:0x1B0])
        self.overflow = {}
        self.ext_tree = None
        self.ext_tree = self.Tree(self, 3, self.ext_fork)
        for k, recs in self.ext_tree.leaves():
            # key: keyLength u16, forkType u8, pad u8, fileID u32, startBlock u32
            ft, fid, sb = struct.unpack_from(">BxII", k, 2)
            ext = [struct.unpack_from(">II", recs, 8 * i) for i in range(8)]
            self.overflow.setdefault((fid, ft), []).append((sb, [e for e in ext if e[1]]))
        self.cat = self.Tree(self, 4, self.cat_fork)
        self.attr = self.Tree(self, 8, self.attr_fork) if self.attr_fork[0] else None

    def extents(self, fid, ftype, f):
        size, blocks, ext = f
        ext = list(ext)
        have = sum(e[1] for e in ext)
        for sb, more in sorted(self.overflow.get((fid, ftype), [])):
            if sb == have:
                ext += more
                have += sum(e[1] for e in more)
        return size, ext

    def read_fork(self, fid, ftype, f):
        size, ext = self.extents(fid, ftype, f)
        out = bytearray()
        for start, count in ext:
            if len(out) >= size:
                break
            out += self.img.read(start * self.bs, count * self.bs)
        return bytes(out[:size])

    class Tree:
        def __init__(self, hfs, fid, f):
            self.hfs = hfs
            self.size, self.ext = hfs.extents(fid, 0, f) if hfs.ext_tree is not None or fid != 3 else (f[0], f[2])
            h = self.raw(0, 512)
            (self.depth, self.root, _, self.first_leaf, _, self.node_size) = struct.unpack_from(">HIIIIH", h, 14)
            self.cache = {}

        def raw(self, off, n):
            out = bytearray()
            bs = self.hfs.bs
            pos = 0
            for start, count in self.ext:
                span = count * bs
                if off < pos + span and n > 0:
                    a = off - pos
                    take = min(n, span - a)
                    out += self.hfs.img.read(start * bs + a, take)
                    off += take
                    n -= take
                pos += span
            return bytes(out)

        def node(self, i):
            if i not in self.cache:
                if len(self.cache) > 4096:
                    self.cache.clear()
                self.cache[i] = self.raw(i * self.node_size, self.node_size)
            return self.cache[i]

        def records(self, i):
            b = self.node(i)
            flink, _, kind, _, n = struct.unpack_from(">IIbBH", b, 0)
            offs = [struct.unpack_from(">H", b, self.node_size - 2 * (j + 1))[0] for j in range(n + 1)]
            recs = []
            for j in range(n):
                r = b[offs[j]:offs[j + 1]]
                kl = struct.unpack_from(">H", r)[0]
                key = r[:2 + kl]
                body = r[2 + kl + ((2 + kl) & 1):] if kind == -1 else r[2 + kl:]
                recs.append((key, body))
            return flink, kind, recs

        def leaves(self, start=None):
            i = self.first_leaf if start is None else start
            while i:
                flink, kind, recs = self.records(i)
                for k, body in recs:
                    yield k, body
                i = flink

        def find_leaf(self, keyfn, target):
            """Leaf node where records with keyfn(key) >= target begin."""
            i = self.root
            while True:
                _, kind, recs = self.records(i)
                if kind == -1:
                    return i
                pick = recs[0]
                for k, body in recs:
                    if keyfn(k) < target:
                        pick = (k, body)
                    else:
                        break
                i = struct.unpack_from(">I", pick[1])[0]

    @staticmethod
    def cat_key(k):
        parent, n = struct.unpack_from(">IH", k, 2)
        name = k[8:8 + 2 * n].decode("utf-16-be", "replace")
        return parent, name

    def children(self, cnid):
        leaf = self.cat.find_leaf(lambda k: struct.unpack_from(">I", k, 2)[0], cnid)
        for k, body in self.cat.leaves(leaf):
            parent, name = self.cat_key(k)
            if parent < cnid:
                continue
            if parent > cnid:
                return
            rtype = struct.unpack_from(">h", body)[0]
            if rtype in (1, 2):
                yield name, rtype, body

    def lookup(self, path):
        cnid, rtype, body = 2, 1, None
        for part in [p for p in path.split("/") if p]:
            for name, t, b in self.children(cnid):
                if name == part or name.lower() == part.lower():
                    rtype, body = t, b
                    cnid = struct.unpack_from(">I", b, 8)[0]
                    break
            else:
                return None
        return cnid, rtype, body

    def xattr(self, cnid, want):
        if self.attr is None:
            return None
        leaf = self.attr.find_leaf(lambda k: struct.unpack_from(">I", k, 4)[0], cnid)
        for k, body in self.attr.leaves(leaf):
            fid = struct.unpack_from(">I", k, 4)[0]
            if fid < cnid:
                continue
            if fid > cnid:
                return None
            n = struct.unpack_from(">H", k, 12)[0]
            name = k[14:14 + 2 * n].decode("utf-16-be", "replace")
            if name == want:
                rt = struct.unpack_from(">I", body)[0]
                if rt == 0x10:      # inline data
                    size = struct.unpack_from(">I", body, 12)[0]
                    return body[16:16 + size]
                if rt == 0x20:      # fork data
                    f = fork(body[8:8 + 80])
                    return self.read_fork(cnid, 0xFF, f)
                return None
        return None

    def file_data(self, cnid, body):
        flags = body[0x29 + 0]     # bsdInfo at 0x20: ownerID 4, groupID 4, adminFlags 1, ownerFlags 1
        owner_flags = body[0x29]
        data = self.read_fork(cnid, 0, fork(body[0x58:0xA8]))
        if not owner_flags & 0x20:  # UF_COMPRESSED
            return data, "plain"
        d = self.xattr(cnid, "com.apple.decmpfs")
        if d is None or d[:4] != b"fpmc":
            return data, "compressed, no decmpfs xattr"
        ctype, usize = struct.unpack_from("<IQ", d, 4)
        if ctype in (3, 7, 11):     # inline in the xattr
            payload = d[16:]
            return decompress(ctype, payload, usize), "decmpfs %d" % ctype
        rsrc = self.read_fork(cnid, 0xFF, fork(body[0xA8:0xF8]))
        if ctype == 4:              # zlib in the resource fork
            hdr_off = struct.unpack_from(">I", rsrc, 0)[0]
            base = hdr_off + 4
            count = struct.unpack_from("<I", rsrc, base)[0]
            out = bytearray()
            for i in range(count):
                o, n = struct.unpack_from("<II", rsrc, base + 4 + 8 * i)
                out += decompress(3, rsrc[base + o:base + o + n], 65536)
            return bytes(out[:usize]), "decmpfs 4"
        if ctype in (8, 12):        # LZVN / LZFSE chunks: u32 offset table at the start
            first = struct.unpack_from("<I", rsrc, 0)[0]
            offs = [struct.unpack_from("<I", rsrc, 4 * i)[0] for i in range(first // 4)]
            out = bytearray()
            for a, b in zip(offs, offs[1:]):
                out += decompress(ctype - 1, rsrc[a:b], 65536)
            return bytes(out[:usize]), "decmpfs %d" % ctype
        return data, "decmpfs type %d not supported" % ctype


_lib = None


def decompress(ctype, payload, usize):
    global _lib
    if ctype == 3:
        if payload[:1] == b"\xff" or (payload[:1] != b"\x78"):
            return payload[1:]          # stored uncompressed
        return zlib.decompress(payload)
    if payload[:1] in (b"\x06", b"\xff"):
        return payload[1:]
    if _lib is None:
        p = ctypes.util.find_library("compression")
        if not p:
            raise SystemExit("LZVN/LZFSE data and no libcompression")
        _lib = ctypes.CDLL(p)
        _lib.compression_decode_buffer.restype = ctypes.c_size_t
    algo = 0x900 if ctype == 7 else 0x801     # COMPRESSION_LZVN (private value) / COMPRESSION_LZFSE
    if ctype == 7:
        # LZVN raw stream: wrap it as an LZFSE 'bvxn' block so the public LZFSE decoder takes it
        hdr = b"bvxn" + struct.pack("<II", usize, len(payload))
        payload = hdr + payload + b"bvx$"
        algo = 0x801
    dst = ctypes.create_string_buffer(usize + 16)
    n = _lib.compression_decode_buffer(dst, usize + 16, payload, len(payload), None, algo)
    if n == 0 and usize:
        raise SystemExit("decode failed (type %d)" % ctype)
    return dst.raw[:n]


def copy(hfs, cnid, rtype, body, dest, log):
    if rtype == 1:
        os.makedirs(dest, exist_ok=True)
        for name, t, b in list(hfs.children(cnid)):
            copy(hfs, struct.unpack_from(">I", b, 8)[0], t, b, os.path.join(dest, name.replace("/", ":")), log)
        return
    mode = struct.unpack_from(">H", body, 0x2A + 0)[0] if False else struct.unpack_from(">H", body, 0x2A)[0]
    data, how = hfs.file_data(cnid, body)
    if (mode & 0o170000) == 0o120000:   # symbolic link: target in the data fork
        try:
            os.symlink(data.decode(), dest)
        except FileExistsError:
            pass
        log.append("%s -> %s" % (dest, data.decode()))
        return
    with open(dest, "wb") as f:
        f.write(data)
    os.chmod(dest, (mode & 0o777) | 0o600)
    log.append("%s %d bytes (%s)" % (dest, len(data), how))


def main():
    if len(sys.argv) < 4:
        print(__doc__)
        sys.exit(1)
    hfs = HFS(Image(sys.argv[1]))
    out = sys.argv[2]
    for p in sys.argv[3:]:
        r = hfs.lookup(p)
        if r is None:
            print("not found: %s" % p)
            continue
        log = []
        copy(hfs, r[0], r[1], r[2], os.path.join(out, p.lstrip("/")), log)
        print("\n".join(log))


if __name__ == "__main__":
    main()
