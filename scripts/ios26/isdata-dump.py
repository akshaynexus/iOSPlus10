#!/usr/bin/env python3
"""isdata-dump.py DIR OUT.png [--all]: the icons of iconservicesagent's store (com.apple.IconsCache/*/*.isdata, copied read only): a montage, newest last, each cell with the file's hour; and one line per file on stdout.
.isdata [V 23F84, read from the files]: u32 format code, u32 pixel bytes, u32 extra bytes, u32 ?, floats of the size in points; 48 bytes in all; then RGBA 16-bit float rows (bytes per pixel = 8) or BGRA8; the extra bytes hold the rendition's layers. Run with python3 -I. Needs Pillow and numpy."""
import glob
import os
import struct
import sys
import time
import numpy as np
from PIL import Image, ImageDraw


def load(path):
    b = open(path, "rb").read()
    fmt, pixels, extra, n = struct.unpack("<IIII", b[:16])
    if len(b) != 48 + pixels + extra or pixels == 0:
        return None
    for bpp, kind in ((8, "f16"), (4, "u8")):
        side = int(round((pixels / bpp) ** 0.5))
        if side * side * bpp == pixels:
            break
    else:
        return None
    raw = b[48:48 + pixels]
    if kind == "f16":
        a = np.frombuffer(raw, dtype="<f2").reshape(side, side, 4).astype(np.float32)
    else:
        a = np.frombuffer(raw, dtype=np.uint8).reshape(side, side, 4).astype(np.float32) / 255
    a = np.nan_to_num(a, nan=0, posinf=1, neginf=0)
    return fmt, side, kind, a, b"public.layeredimage" in b


def main():
    d, out = sys.argv[1], sys.argv[2]
    rows = []
    for p in sorted(glob.glob(os.path.join(d, "*.isdata")), key=os.path.getmtime):
        r = load(p)
        if not r:
            continue
        fmt, side, kind, a, layered = r
        alpha = a[..., 3]
        lit = (alpha > 0.02).mean()
        rgb = a[..., :3][alpha > 0.5]
        spread = float(rgb.std(axis=0).mean()) if len(rgb) else 0.0
        rows.append((os.path.getmtime(p), os.path.basename(p), side, kind, layered, lit, spread, a))
        print("%s\t%s\t%d\t%s\tlayered=%d\tcoverage=%.2f\tspread=%.3f" % (time.strftime("%H:%M", time.localtime(rows[-1][0])), rows[-1][1][:8], side, kind, layered, lit, spread))
    cell, cols = 96, 16
    grid = rows if "--all" in sys.argv else rows[::max(1, len(rows) // 160)]
    h = (len(grid) // cols + 1) * (cell + 12)
    m = Image.new("RGB", (cols * cell, h), (40, 40, 60))
    dr = ImageDraw.Draw(m)
    for i, r in enumerate(grid):
        a = r[7]
        rgb = np.clip(a[..., :3], 0, 1) ** (1 / 2.2) if r[3] == "f16" else np.clip(a[..., [2, 1, 0]], 0, 1)
        al = np.clip(a[..., 3:], 0, 1)
        bg = np.array([0.16, 0.16, 0.24])
        im = (rgb * al + bg * (1 - al)) if r[3] != "f16" else np.clip(a[..., :3], 0, 1) ** (1 / 2.2) + bg * (1 - al)
        tile = Image.fromarray((np.clip(im, 0, 1) * 255).astype(np.uint8)).resize((cell - 4, cell - 4))
        x, y = (i % cols) * cell, (i // cols) * (cell + 12)
        m.paste(tile, (x + 2, y + 2))
        dr.text((x + 2, y + cell - 2), time.strftime("%H:%M", time.localtime(r[0])) + (" L" if r[4] else ""), fill=(255, 255, 0))
    m.save(out)


main()
