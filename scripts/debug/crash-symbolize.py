#!/usr/bin/env python3
"""Helper of crash-symbolize.sh (stdin: CRASH and NMTL images lines). addrs: unslid cache addresses. print SYMS: the lines."""
import re, sys

CACHE = (0x180000000, 0x280000000)
HEX = re.compile(r'0x[0-9a-f]+')
HEAD = re.compile(r'CRASH (\S+?)\[(\d+)\] sig (\d+).* slide (0x[0-9a-f]+) mh (0x[0-9a-f]+)')
IMG = re.compile(r'NMTL\[(\d+) [^\]]+\]: images NegroniMetal (0x[0-9a-f]+) text (0x[0-9a-f]+) turnip (0x[0-9a-f]+) text (0x[0-9a-f]+)')
BODY = re.compile(r'CRASH (\S+) (pc|bt) (.*)')


def walk(stdin):
    """Yield (line, slide, mh, images of the pid) for each pc/bt line after its head line."""
    images, cur = {}, None
    for line in stdin:
        m = IMG.search(line)
        if m:
            images[m[1]] = [(int(m[2], 16), int(m[3], 16), 'NegroniMetal'), (int(m[4], 16), int(m[5], 16), 'turnip')]
            continue
        m = HEAD.search(line)
        if m:
            cur = (int(m[4], 16), int(m[5], 16), images.get(m[2], []))
            print(line.rstrip()[line.find('CRASH'):]) if len(sys.argv) > 2 else None
            continue
        if BODY.search(line) and cur:
            yield line, cur


def main():
    if sys.argv[1] == 'addrs':
        for line, (slide, _, _) in walk(sys.stdin):
            for a in HEX.findall(line[line.find('CRASH'):]):
                u = int(a, 16) - slide
                if CACHE[0] <= u < CACHE[1]:
                    print('%#x' % u)
        return
    syms = {}
    with open(sys.argv[2], errors='replace') as h:
        for s in h:
            k, _, v = s.partition(' ')
            syms[k] = v.strip()
    for line, (slide, mh, imgs) in walk(sys.stdin):
        print(line.rstrip()[line.find('CRASH'):].split(' pc ')[0].split(' bt ')[0])
        for a in HEX.findall(line[line.find('CRASH'):]):
            v, u = int(a, 16), int(a, 16) - slide
            name = syms.get('%#x' % u) if CACHE[0] <= u < CACHE[1] else None
            for base, size, n in imgs:
                if base <= v < base + size:
                    name = '%s+%#x' % (n, v - base)
            if name is None and mh <= v < mh + 0x4000000:
                name = 'main+%#x' % (v - mh)
            print('   %s %s' % (a, name or '?'))


main()
