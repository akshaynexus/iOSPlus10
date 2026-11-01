#!/usr/bin/env python3
"""Host test of the LaurelHEVC decoder core against an independent decoder. docs/laurel_sprout/hevc.md section 7.

  scripts/laurel/hevc-test.py [--tool out/laurel/hevc/host/hevc-test] [--limit N] [--min-psnr 45] FILE.HEIC...

For each file: this script reads the HEIF container (as CMPhoto does on the phone), hands the tiles of the primary image and of its alpha
image to hevc-test (the same hevc_core.c as the iOS plug-in), puts the tiles on the grid, and compares with the independent decoder libde265
(tile by tile through ctypes: heif-dec itself un-premultiplies layers, so its planes differ on purpose): Y, Cb, Cr and alpha PSNR, plus width and
height against `heif-dec`. A line per file, a summary at the end. Exit 0 when all pass. Needs: heif-dec, libde265.so.0.
"""
import argparse, math, os, struct, subprocess, sys, tempfile
from array import array


def boxes(b, start, end):
    p = start
    while p + 8 <= end:
        size, kind = struct.unpack_from('>I4s', b, p)
        head = 8
        if size == 1:
            size = struct.unpack_from('>Q', b, p + 8)[0]
            head = 16
        elif size == 0:
            size = end - p
        if size < head or p + size > end:
            raise ValueError('bad box at %d' % p)
        yield kind.decode('latin1'), p + head, p + size
        p += size


def child(b, start, end, name):
    for k, s, e in boxes(b, start, end):
        if k == name:
            return s, e
    return None


def uint(b, p, n):
    return int.from_bytes(b[p:p + n], 'big') if n else 0


class Heif:
    """The boxes of a HEIF file that decoding needs: pitm, iinf, iloc, iprp, iref, idat."""

    def __init__(self, path):
        self.b = b = open(path, 'rb').read()
        s, e = child(b, 0, len(b), 'meta')
        s += 4
        ps, pe = child(b, s, e, 'pitm')
        self.primary = struct.unpack_from('>H', b, ps + 4)[0] if b[ps] == 0 else struct.unpack_from('>I', b, ps + 4)[0]
        self.types = {}
        s2, e2 = child(b, s, e, 'iinf')
        ver = b[s2]
        p = s2 + 4 + (2 if ver == 0 else 4)
        for k, a, z in boxes(b, p, e2):
            if k == 'infe':
                v = b[a]
                iid = struct.unpack_from('>H', b, a + 4)[0] if v == 2 else struct.unpack_from('>I', b, a + 4)[0]
                off = a + (8 if v == 2 else 10)
                self.types[iid] = b[off:off + 4].decode('latin1')
        self.idat = child(b, s, e, 'idat')
        self.loc = self.parse_iloc(*child(b, s, e, 'iloc'))
        self.props, self.assoc = self.parse_iprp(*child(b, s, e, 'iprp'))
        self.refs = self.parse_iref(child(b, s, e, 'iref'))

    def parse_iloc(self, s, e):
        b = self.b
        ver = b[s]
        off, ln = b[s + 4] >> 4, b[s + 4] & 15
        base, idx = b[s + 5] >> 4, b[s + 5] & 15
        p = s + 6
        n = uint(b, p, 2 if ver < 2 else 4)
        p += 2 if ver < 2 else 4
        out = {}
        for _ in range(n):
            iid = uint(b, p, 2 if ver < 2 else 4)
            p += 2 if ver < 2 else 4
            method = 0
            if ver:
                method = b[p + 1] & 15
                p += 2
            p += 2
            bo = uint(b, p, base)
            p += base
            ext = uint(b, p, 2)
            p += 2
            parts = []
            for _ in range(ext):
                if ver and idx:
                    p += idx
                eo = uint(b, p, off)
                p += off
                el = uint(b, p, ln)
                p += ln
                parts.append((bo + eo, el))
            out[iid] = (method, parts)
        return out

    def parse_iprp(self, s, e):
        b = self.b
        ps, pe = child(b, s, e, 'ipco')
        props = [(k, a, z) for k, a, z in boxes(b, ps, pe)]
        assoc = {}
        a, z = child(b, s, e, 'ipma')
        ver, flags = b[a], uint(b, a + 1, 3)
        p = a + 4
        n = uint(b, p, 4)
        p += 4
        for _ in range(n):
            iid = uint(b, p, 2 if ver < 1 else 4)
            p += 2 if ver < 1 else 4
            c = b[p]
            p += 1
            lst = []
            for _ in range(c):
                if flags & 1:
                    lst.append(uint(b, p, 2) & 0x7fff)
                    p += 2
                else:
                    lst.append(b[p] & 0x7f)
                    p += 1
            assoc[iid] = lst
        return props, assoc

    def parse_iref(self, where):
        out = []
        if where is None:
            return out
        s, e = where
        b = self.b
        ver = b[s]
        w = 2 if ver == 0 else 4
        for k, a, z in boxes(b, s + 4, e):
            src = uint(b, a, w)
            n = uint(b, a + w, 2)
            out.append((k, src, [uint(b, a + w + 2 + i * w, w) for i in range(n)]))
        return out

    def item_bytes(self, iid):
        method, parts = self.loc[iid]
        base = self.idat[0] if method == 1 else 0
        return b''.join(self.b[base + o:base + o + n] for o, n in parts)

    def prop(self, iid, name):
        for i in self.assoc.get(iid, []):
            if i and self.props[i - 1][0] == name:
                return self.props[i - 1]
        return None

    def hvcc(self, iid):
        k, a, z = self.prop(iid, 'hvcC')
        return self.b[a:z]

    def image(self, iid):
        """(tile ids in raster order, columns, rows, output w, h, tile item for hvcC)"""
        if self.types[iid] == 'grid':
            g = self.item_bytes(iid)
            flags = g[1]
            rows, cols = g[2] + 1, g[3] + 1
            w, h = (struct.unpack_from('>II', g, 4) if flags & 1 else struct.unpack_from('>HH', g, 4))
            tiles = next(t for k, src, t in self.refs if k == 'dimg' and src == iid)
            return tiles, cols, rows, w, h
        k, a, z = self.prop(iid, 'ispe')
        w, h = struct.unpack_from('>II', self.b, a + 4)
        return [iid], 1, 1, w, h

    def alpha(self):
        for k, src, t in self.refs:
            if k == 'auxl' and self.primary in t:
                a = self.prop(src, 'auxC')
                if a and (b'alpha' in self.b[a[1]:a[2]] or b'auxid:1' in self.b[a[1]:a[2]]):
                    return src
        return None


def decode(tool, heif, tiles, tmp, tag):
    job = os.path.join(tmp, tag + '.job')
    out = os.path.join(tmp, tag + '.out')
    with open(job, 'wb') as j:
        h = heif.hvcc(tiles[0])
        j.write(b'HVJ1' + struct.pack('<I', len(h)) + h + struct.pack('<II', 0, len(tiles)))
        for t in tiles:
            s = heif.item_bytes(t)
            j.write(struct.pack('<I', len(s)) + s)
    r = subprocess.run([tool, job, out], capture_output=True, text=True)
    if r.returncode:
        raise RuntimeError('hevc-test: %s %s' % (r.stdout.strip(), r.stderr.strip()[:200]))
    pics = {}
    b = open(out, 'rb').read()
    p = 0
    while p < len(b):
        if b[p:p + 4] != b'HVF1':
            raise RuntimeError('bad output')
        idx, w, h, bits, mono, full, matrix = struct.unpack_from('<7I', b, p + 4)
        p += 32
        s = 2 if bits > 8 else 1
        ys, uvs = w * s * h, ((w + 1) // 2) * 2 * s * ((h + 1) // 2)
        pics[idx] = dict(w=w, h=h, bits=bits, mono=mono, full=full, matrix=matrix, y=b[p:p + ys], uv=b[p + ys:p + ys + uvs])
        p += ys + uvs
    return pics, r.stdout.strip()


def compose(pics, cols, rows, w, h, bits):
    """the tiles on the grid, cropped to w x h: Y, Cb, Cr planes as bytes (8-bit) or lists (more)."""
    s = 2 if bits > 8 else 1
    tw, th = pics[0]['w'], pics[0]['h']
    cw, ch = (w + 1) // 2, (h + 1) // 2
    Y, U, V = bytearray(w * h * s), bytearray(cw * ch * s), bytearray(cw * ch * s)
    for i, pic in pics.items():
        cx, cy = i % cols * tw, i // cols * th
        for r in range(pic['h']):
            if cy + r >= h:
                break
            n = min(pic['w'], w - cx)
            if n > 0:
                Y[(cy + r) * w * s + cx * s:(cy + r) * w * s + (cx + n) * s] = pic['y'][r * pic['w'] * s:(r * pic['w'] + n) * s]
        pw = (pic['w'] + 1) // 2
        for r in range((pic['h'] + 1) // 2):
            if cy // 2 + r >= ch:
                break
            n = min(pw, cw - cx // 2)
            row = pic['uv'][r * pw * 2 * s:(r * pw * 2 + n * 2) * s]
            a = (cy // 2 + r) * cw * s + cx // 2 * s
            U[a:a + n * s] = row[0::2] if s == 1 else b''.join(row[k:k + 2] for k in range(0, len(row), 4))
            V[a:a + n * s] = row[1::2] if s == 1 else b''.join(row[k:k + 2] for k in range(2, len(row), 4))
    return bytes(Y), bytes(U), bytes(V)


def psnr(a, b, bits=8):
    if len(a) != len(b):
        raise ValueError('sizes differ %d %d' % (len(a), len(b)))
    code, peak = ('H', 65535.0) if bits > 8 else ('B', 255.0)   # more than 8 bits: 16-bit samples, value in the high bits
    x, y = array(code, a), array(code, b)
    se = sum((p - q) ** 2 for p, q in zip(x, y))
    return math.inf if se == 0 else 10 * math.log10(peak * peak * len(x) / se)


def read_y4m(path):
    b = open(path, 'rb').read()
    head = b[:b.index(b'\n')].decode().split()
    return next(int(t[1:]) for t in head if t[0] == 'W'), next(int(t[1:]) for t in head if t[0] == 'H')


class De265:
    """The reference: the system's libde265, tile by tile, before libheif's alpha and colour steps."""

    def __init__(self):
        import ctypes as C
        self.C = C
        self.lib = lib = C.CDLL('libde265.so.0')
        lib.de265_new_decoder.restype = C.c_void_p
        lib.de265_push_NAL.argtypes = [C.c_void_p, C.c_char_p, C.c_int, C.c_int64, C.c_void_p]
        lib.de265_flush_data.argtypes = [C.c_void_p]
        lib.de265_decode.argtypes = [C.c_void_p, C.POINTER(C.c_int)]
        lib.de265_get_next_picture.argtypes = [C.c_void_p]
        lib.de265_get_next_picture.restype = C.c_void_p
        lib.de265_get_image_plane.argtypes = [C.c_void_p, C.c_int, C.POINTER(C.c_int)]
        lib.de265_get_image_plane.restype = C.POINTER(C.c_ubyte)
        lib.de265_get_image_width.argtypes = lib.de265_get_image_height.argtypes = [C.c_void_p, C.c_int]
        lib.de265_get_bits_per_pixel.argtypes = [C.c_void_p, C.c_int]
        lib.de265_get_chroma_format.argtypes = [C.c_void_p]
        lib.de265_free_decoder.argtypes = [C.c_void_p]

    def plane(self, img, ch, sample):
        C = self.C
        st = C.c_int()
        ptr = self.lib.de265_get_image_plane(img, ch, C.byref(st))
        w, h = self.lib.de265_get_image_width(img, ch), self.lib.de265_get_image_height(img, ch)
        raw = C.string_at(ptr, st.value * h)
        return b''.join(raw[r * st.value:r * st.value + w * sample] for r in range(h)), w, h

    @staticmethod
    def high(raw, bits):
        if bits == 8:
            return raw
        w = array('H', raw)
        return array('H', (v << (16 - bits) for v in w)).tobytes()

    def tile(self, hvcc, data):
        """one tile: same dict as decode() gives, with the planes as hevc-test writes them"""
        lib = self.lib
        C = self.C
        d = lib.de265_new_decoder()
        n = hvcc[22]
        p = 23
        for _ in range(n):
            c = struct.unpack_from('>H', hvcc, p + 1)[0]
            p += 3
            for _ in range(c):
                ln = struct.unpack_from('>H', hvcc, p)[0]
                lib.de265_push_NAL(d, hvcc[p + 2:p + 2 + ln], ln, 0, None)
                p += 2 + ln
        size = (hvcc[21] & 3) + 1
        p = 0
        while p < len(data):
            ln = int.from_bytes(data[p:p + size], 'big')
            lib.de265_push_NAL(d, data[p + size:p + size + ln], ln, 0, None)
            p += size + ln
        lib.de265_flush_data(d)
        more = C.c_int(1)
        img = None
        while more.value and img is None:
            lib.de265_decode(d, C.byref(more))
            img = lib.de265_get_next_picture(d)
        if img is None:
            lib.de265_free_decoder(d)
            raise RuntimeError('libde265 gave no picture')
        bits = lib.de265_get_bits_per_pixel(img, 0)
        sample = 2 if bits > 8 else 1
        y, w, h = self.plane(img, 0, sample)
        y = self.high(y, bits)
        if lib.de265_get_chroma_format(img) == 0:
            uv = (b'\x80' if sample == 1 else b'\x00\x80') * (((w + 1) // 2) * 2 * ((h + 1) // 2))
            mono = 1
        else:
            u = self.high(self.plane(img, 1, sample)[0], bits)
            v = self.high(self.plane(img, 2, sample)[0], bits)
            uv = bytearray(len(u) * 2)
            uv[0::2 * sample] = u[0::sample]
            uv[1 * sample::2 * sample] = v[0::sample]
            if sample == 2:
                uv[1::4] = u[1::2]
                uv[3::4] = v[1::2]
            mono = 0
        out = dict(w=w, h=h, bits=bits, mono=mono, y=y, uv=bytes(uv))
        lib.de265_free_decoder(d)
        return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--tool', default='out/laurel/hevc/host/hevc-test')
    ap.add_argument('--min-psnr', type=float, default=45.0)
    ap.add_argument('files', nargs='+')
    a = ap.parse_args()
    de = De265()
    bad = 0
    worst = math.inf
    for f in a.files:
        with tempfile.TemporaryDirectory(prefix='hevc-test-') as tmp:
            try:
                x = Heif(f)
                tiles, cols, rows, w, h = x.image(x.primary)
                pics, note = decode(a.tool, x, tiles, tmp, 'c')
                bits = pics[0]['bits']
                Y, U, V = compose(pics, cols, rows, w, h, bits)
                ref = os.path.join(tmp, 'ref.y4m')
                subprocess.run(['heif-dec', '-o', ref, f], check=True, capture_output=True)
                clap = x.prop(x.primary, 'clap')
                want = (w, h)
                if clap:                            # a crop in the container: CMPhoto applies it on the phone, libheif here
                    n = struct.unpack_from('>IIII', x.b, clap[1])
                    want = (n[0] // n[1], n[2] // n[3])
                ok = read_y4m(ref) == want          # libheif agrees on the size of the whole image
                hv = x.hvcc(tiles[0])
                RY, RU, RV = compose({i: de.tile(hv, x.item_bytes(t)) for i, t in enumerate(tiles)}, cols, rows, w, h, bits)
                py, pu, pv = psnr(Y, RY, bits), psnr(U, RU, bits), psnr(V, RV, bits)
                line = '%dx%d %d tiles Y %.1f Cb %.1f Cr %.1f dB [%s]' % (w, h, len(tiles), py, pu, pv, note.split(', ', 2)[2])
                vals = [py, pu, pv]
                aid = x.alpha()
                if aid is not None:
                    at, ac, ar, aw, ah = x.image(aid)
                    ap_, _ = decode(a.tool, x, at, tmp, 'a')
                    ay, _, _ = compose(ap_, ac, ar, aw, ah, ap_[0]['bits'])
                    ha = x.hvcc(at[0])
                    rav, _, _ = compose({i: de.tile(ha, x.item_bytes(t)) for i, t in enumerate(at)}, ac, ar, aw, ah, ap_[0]['bits'])
                    pa = psnr(ay, rav)
                    vals.append(pa)
                    line += ' alpha mono=%d %dx%d %.1f dB' % (ap_[0]['mono'], aw, ah, pa)
                v = min(vals)
                worst = min(worst, v)
                ok = ok and v >= a.min_psnr
                print(('PASS ' if ok else 'FAIL ') + line + ' ' + os.path.basename(f))
                bad += not ok
            except Exception as e:
                print('FAIL %s: %s: %s' % (os.path.basename(f), type(e).__name__, e))
                bad += 1
    print('hevc-test: %d of %d files pass, lowest plane %.1f dB (minimum %.1f)' % (len(a.files) - bad, len(a.files), worst, a.min_psnr))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
