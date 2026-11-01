#!/usr/bin/env python3
"""Host test of the LaurelHEVC core with made clips: B-frames, 10-bit, monochrome, 4:2:2. docs/laurel_sprout/hevc.md section 7.

  scripts/laurel/hevc-test-video.py [--tool out/laurel/hevc/host/hevc-test] DIR

Makes the clips in DIR with the host's ffmpeg + libx265 and heif-enc, reads hvcC + samples from the MP4 box tables, runs hevc-test with slice and with
frame threads, and compares each picture with libde265 (scripts/laurel/hevc-test.py, class De265). Checks: every sample gives one picture, the output
order is the display order (tags not rising = the reorder map works), PSNR. Exit 0 when all pass.
"""
import argparse, importlib.util, os, struct, subprocess, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location('hevc_test', os.path.join(HERE, 'hevc-test.py'))
T = importlib.util.module_from_spec(spec)
spec.loader.exec_module(T)


def mp4_samples(path):
    b = open(path, 'rb').read()
    def find(s, e, *names):
        for n in names:
            s, e = T.child(b, s, e, n)
        return s, e
    ms, me = find(0, len(b), 'moov')
    for k, s, e in T.boxes(b, ms, me):
        if k != 'trak':
            continue
        stbl = find(s, e, 'mdia', 'minf', 'stbl')
        sd = T.child(b, *stbl, 'stsd')
        hv = b.find(b'hvcC', sd[0], sd[1])
        if hv < 0:
            continue
        n = struct.unpack_from('>I', b, hv - 4)[0]
        hvcc = b[hv + 4:hv - 4 + n]
        a = T.child(b, *stbl, 'stsz')[0]
        fixed, count = struct.unpack_from('>II', b, a + 4)
        sizes = [fixed] * count if fixed else list(struct.unpack_from('>%dI' % count, b, a + 12))
        a = T.child(b, *stbl, 'stsc')[0]
        stsc = [struct.unpack_from('>III', b, a + 8 + 12 * i) for i in range(struct.unpack_from('>I', b, a + 4)[0])]
        co = T.child(b, *stbl, 'stco')
        a = co[0]
        chunks = list(struct.unpack_from('>%dI' % struct.unpack_from('>I', b, a + 4)[0], b, a + 8))
        out, si = [], 0
        for c, off in enumerate(chunks):
            per = next(p for first, p, _ in reversed(stsc) if first <= c + 1)
            for _ in range(per):
                out.append(b[off:off + sizes[si]])
                off += sizes[si]
                si += 1
        return hvcc, out
    raise ValueError('no hvcC track in ' + path)


def de265_sequence(de, hvcc, samples):
    """every picture of the clip in output order; a fresh pass of De265.tile logic with all samples pushed"""
    lib, C = de.lib, de.C
    d = lib.de265_new_decoder()
    p = 23
    for _ in range(hvcc[22]):
        c = struct.unpack_from('>H', hvcc, p + 1)[0]
        p += 3
        for _ in range(c):
            ln = struct.unpack_from('>H', hvcc, p)[0]
            lib.de265_push_NAL(d, hvcc[p + 2:p + 2 + ln], ln, 0, None)
            p += 2 + ln
    size = (hvcc[21] & 3) + 1
    for s in samples:
        p = 0
        while p < len(s):
            ln = int.from_bytes(s[p:p + size], 'big')
            lib.de265_push_NAL(d, s[p + size:p + size + ln], ln, 0, None)
            p += size + ln
    lib.de265_flush_data(d)
    pics, more = [], C.c_int(1)
    while more.value:
        lib.de265_decode(d, C.byref(more))
        while True:
            img = lib.de265_get_next_picture(d)
            if img is None:
                break
            bits = lib.de265_get_bits_per_pixel(img, 0)
            pics.append(de.high(de.plane(img, 0, 2 if bits > 8 else 1)[0], bits))
    lib.de265_free_decoder(d)
    return pics


def run(tool, hvcc, samples, mode, tmp):
    job, out = os.path.join(tmp, 'j'), os.path.join(tmp, 'o')
    with open(job, 'wb') as j:
        j.write(b'HVJ1' + struct.pack('<I', len(hvcc)) + hvcc + struct.pack('<II', mode, len(samples)))
        for s in samples:
            j.write(struct.pack('<I', len(s)) + s)
    r = subprocess.run([tool, job, out], capture_output=True, text=True)
    b, p, pics = open(out, 'rb').read(), 0, []
    while p < len(b):
        idx, w, h, bits, mono, full, matrix = struct.unpack_from('<7I', b, p + 4)
        p += 32
        s = 2 if bits > 8 else 1
        pics.append((idx, b[p:p + w * h * s], bits))
        p += w * h * s + ((w + 1) // 2) * 2 * s * ((h + 1) // 2)
    return r, pics


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--tool', default='out/laurel/hevc/host/hevc-test')
    ap.add_argument('dir')
    a = ap.parse_args()
    os.makedirs(a.dir, exist_ok=True)
    de, bad = T.De265(), 0
    for name, fmt, min_db in (('8bit', 'yuv420p', 45), ('10bit', 'yuv420p10le', 45), ('mono8', 'gray', 45), ('mono10', 'gray10le', 45), ('422-10', 'yuv422p10le', 45)):
        f = os.path.join(a.dir, name + '.mp4')
        if not os.path.exists(f):
            subprocess.run(['ffmpeg', '-y', '-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=s=640x360:r=30:d=1', '-pix_fmt', fmt, '-c:v', 'libx265', '-tag:v', 'hvc1',
                            '-x265-params', 'log-level=error:bframes=4:keyint=15', f], check=True)
        hvcc, samples = mp4_samples(f)
        ref = de265_sequence(de, hvcc, samples)
        for mode, label in ((0, 'slice'), (1, 'frame')):
            with tempfile.TemporaryDirectory(prefix='hevc-video-') as tmp:
                r, pics = run(a.tool, hvcc, samples, mode, tmp)
            reordered = any(pics[i][0] > pics[i + 1][0] for i in range(len(pics) - 1))
            worst = min((T.psnr(p[1], q, p[2]) for p, q in zip(pics, ref)), default=0)
            ok = r.returncode == 0 and len(pics) == len(samples) == len(ref) and worst >= min_db and reordered
            print('%s %-6s %s threads: %d samples, %d pictures, libde265 %d, reordered %s, lowest luma %.1f dB; %s' % (
                'PASS' if ok else 'FAIL', name, label, len(samples), len(pics), len(ref), reordered, worst, r.stdout.strip()))
            bad += not ok
    print('hevc-test-video: %s' % ('all pass' if not bad else '%d FAIL' % bad))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
