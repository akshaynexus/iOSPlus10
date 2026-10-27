#!/usr/bin/env python3
"""Simulate the kernel clock shift on a render-server screenshot (userland/screenshot negroni-shot, 1125x2436 PNG).

  uv run --with pillow scripts/display/clockshift-sim.py SHOT.png [SHOT2.png ...] OUT.png [--n 100]

For each shot, three crops of the panel's top-left (560x160 panel pixels) one under the other: as CoreAnimation drew it,
the 0267 strip (panel rows 0..120, left half rotated right by n), and 0391 (rows 34..80, columns 50..228 moved n right,
the n columns right of the box into the gap). Also prints the clock glyph box (near-white pixels in the top-left).
Panel = canvas minus fOffX 22 / fOffY 12 (NegroniFramebuffer: 1125x2436 presented, 1080x2412 panel).
"""
import sys
from PIL import Image

args = [a for a in sys.argv[1:]]
n = 100
if "--n" in args:
    i = args.index("--n")
    n = int(args[i + 1])
    del args[i:i + 2]
if len(args) < 2:
    print(__doc__)
    sys.exit(2)
out, shots = args[-1], args[:-1]


def strip(img, T=0, R=120, half=540):
    im = img.copy(); px = img.load(); q = im.load()
    for y in range(T, R):
        for x in range(half):
            q[(x + n) % half, y] = px[x, y]
    return im


def box(img, T=34, R=80, a=50, b=228):
    im = img.copy(); px = img.load(); q = im.load()
    for y in range(T, R):
        for x in range(a, b):
            q[x + n, y] = px[x, y]
        for x in range(n):
            q[a + x, y] = px[b + x, y]
    return im


tiles = []
for f in shots:
    src = Image.open(f).convert("RGB")
    px = src.load()
    pts = [(x, y) for y in range(0, 140) for x in range(0, src.size[0] // 2) if min(px[x, y]) > 225]
    if pts:
        print(f"{f}: clock glyphs at canvas x {min(p[0] for p in pts)}..{max(p[0] for p in pts)} "
              f"y {min(p[1] for p in pts)}..{max(p[1] for p in pts)} (panel rows {min(p[1] for p in pts) - 12}.."
              f"{max(p[1] for p in pts) - 12})")
    panel = src.crop((22, 12, 22 + 1080, 12 + 2412))
    tiles += [panel.crop((0, 0, 560, 160)), strip(panel).crop((0, 0, 560, 160)), box(panel).crop((0, 0, 560, 160))]
c = Image.new("RGB", (560, 170 * len(tiles)), (255, 0, 0))
for i, t in enumerate(tiles):
    c.paste(t, (0, 170 * i))
c.save(out)
print(f"{out}: per shot: original, 0267 strip, 0391 box (n {n})")
