#!/usr/bin/env python3
"""Mi A3 camera: the plug-in's colour tuning file from the phone's own stock chromatix libraries (root step, never in git).

  scripts/laurel/camera-tuning.py LIBDIR sunny|qtech OUT.isp

LIBDIR has libchromatix_laurus_imx586_<module>_{common,default_preview[_dw9800w]}.so (scripts/laurel/camera-inventory.sh).
Output: the RWCISP02 file that isp_load_tuning (userland/camera/camera_isp.c) reads. Found by shape in .data, each one checked [V stock files]:
  default_preview: 6 colour matrices 0x30 bytes apart (9 floats, rows sum to 1), after the 10 u32 colour temperature limits
                   (hi/lo pairs 6500/7000, 5300/5800, 4200/4700, 3100/3600, 2500/2800)
  common:          lens shading sets, 884 floats (R, Gr, Gb, B, each 13 rows of 17; middle about 1, corners 3 to 4.4)
Order of the matrices from the coldest to the warmest light [I: the limits come in that order; the matrices themselves do not name a light]. The light of
a shading set is not named in the file: [I] the sets are ordered by the corners' red over blue, which grows as the light gets warmer.
No white balance reference points: the plug-in's grey world stays free. Exit 1 when something has another shape.
"""
import struct
import sys

GRID = 13 * 17


def data_section(path):
    b = open(path, "rb").read()
    if b[:4] != b"\x7fELF" or b[4] != 1:
        raise SystemExit(f"{path}: not an ELF32 file")
    shoff, = struct.unpack_from("<I", b, 0x20)
    shent, shnum, shstr = struct.unpack_from("<HHH", b, 0x2E)
    secs = [struct.unpack_from("<10I", b, shoff + i * shent) for i in range(shnum)]
    names = secs[shstr][4]
    for s in secs:
        if b[names + s[0]:].split(b"\0", 1)[0] == b".data":
            return b[s[4]:s[4] + s[5]]
    raise SystemExit(f"{path}: no .data")


def floats(d):
    return struct.unpack(f"<{len(d) // 4}f", d[:len(d) // 4 * 4])


def is_ccm(m):
    return all(-3 < x < 4 for x in m) and all(abs(sum(m[i:i + 3]) - 1) < 0.03 for i in (0, 3, 6)) and m[0] > 1 and m[4] > 1 and m[8] > 1


def find_ccms(d):
    f = floats(d)
    for i in range(len(f) - 80):
        if all(is_ccm(f[i + 12 * k:i + 12 * k + 9]) for k in range(6)):
            return [f[i + 12 * k:i + 12 * k + 9] for k in range(6)]
    raise SystemExit("no 6 colour matrices 0x30 bytes apart")


def find_lsc(d):
    f = floats(d)
    sets, i = [], 0
    while i + 4 * GRID <= len(f):
        if all(0.9 < x < 9 for x in f[i:i + 4 * GRID]) and all(f[i + c * GRID + GRID // 2] < 1.3 for c in range(4)):
            sets.append(f[i:i + 4 * GRID])
            i += 4 * GRID
        else:
            i += 1
    if not sets:
        raise SystemExit("no lens shading set")
    # the same set twice (the file has low-light copies): once
    unique = []
    for s in sets:
        if all(max(abs(a - b) for a, b in zip(s, u)) > 1e-3 for u in unique):
            unique.append(s)

    def warmth(s):
        return (s[0] + s[16] + s[GRID - 17] + s[GRID - 1]) / (s[3 * GRID] + s[3 * GRID + 16] + s[4 * GRID - 17] + s[4 * GRID - 1])
    return sorted(unique, key=warmth, reverse=True)


def main():
    if len(sys.argv) != 4:
        raise SystemExit(__doc__)
    libdir, module, out = sys.argv[1:]
    base = f"{libdir}/libchromatix_laurus_imx586_{module}_"
    preview = base + ("default_preview_dw9800w.so" if module == "qtech" else "default_preview.so")
    ccm = find_ccms(data_section(preview))
    lsc = find_lsc(data_section(base + "common.so"))
    # ascending colour temperature, the file's order reversed: 0..2500, 2800..3100, 3600..4200, 4700..5300, 5800..6500, 7000..
    ranges = [(0, 2500), (2800, 3100), (3600, 4200), (4700, 5300), (5800, 6500), (7000, 20000)]
    o = bytearray(b"RWCISP02")
    o += struct.pack("<I", 1) + struct.pack("<ffI", 0, 10000, 6)
    for (lo, hi), m in zip(ranges, reversed(ccm)):
        o += struct.pack("<ff", lo, hi) + struct.pack("<9f", *m)
    picks = lsc[:6]
    n = len(picks)
    o += struct.pack("<I", 1) + struct.pack("<ffI", 0, 10000, n)
    for i, s in enumerate(picks):
        t = 2600 + (6800 - 2600) * (i / (n - 1) if n > 1 else 0.5)
        o += struct.pack("<ff", t, t) + struct.pack(f"<{4 * GRID}f", *s)
    o += struct.pack("<I", 0)
    with open(out, "wb") as f:
        f.write(o)
    corner = max(picks[0][:GRID])
    print(f"camera-tuning: {out}: 6 colour matrices, {n} lens shading sets of {len(lsc)} (red corner x{corner:.2f}), {len(o)} bytes")


main()
