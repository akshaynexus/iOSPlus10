#!/usr/bin/env python3
"""Read the iOS dyld shared cache without ipsw (macOS + Linux; needs llvm-objdump + llvm-objcopy).

  scripts/debug/dsc-dis.py DIR dis VADDR LEN    disassemble LEN bytes at an unslid VADDR
  scripts/debug/dsc-dis.py DIR read VADDR LEN   raw bytes to stdout (e.g. | xxd)
  scripts/debug/dsc-dis.py DIR str TEXT...      where each C string TEXT is (vaddr + image path)

DIR = the directory with dyld_shared_cache_arm64*. iOS 16 20H392 has it in the Cryptex APFS image:
  apfs-fuse -o ro ~/op10-apple/20H392/087-86593-047.dmg out/mnt-cryptex
  DIR = out/mnt-cryptex/root/System/Library/Caches/com.apple.dyld
Branch and adrp targets are real vaddrs (the code is placed at its page-aligned address). Pointers in
data have the cache's high bits (e.g. 0x0201_95a940a8 = 0x195a940a8). Run with python3 -I.
"""
import bisect, glob, mmap, os, re, shutil, struct, subprocess, sys, tempfile


def caches(d):
    for f in sorted(glob.glob(os.path.join(d, 'dyld_shared_cache_arm64*'))):
        if f.endswith('.symbols'):
            continue
        with open(f, 'rb') as h:
            hdr = h.read(0x200)
            if not hdr.startswith(b'dyld_v1'):
                continue
            mo, mc = struct.unpack_from('<II', hdr, 0x10)
            h.seek(mo)
            yield f, [struct.unpack('<QQQII', h.read(32))[:3] for _ in range(mc)]


def find(d, va):
    for f, maps in caches(d):
        for a, s, fo in maps:
            if a <= va < a + s:
                return f, fo + va - a
    sys.exit('dsc-dis: vaddr %#x is in no mapping' % va)


def read(d, va, n):
    f, off = find(d, va)
    with open(f, 'rb') as h:
        h.seek(off)
        return h.read(n)


def images(d):
    with open(os.path.join(d, 'dyld_shared_cache_arm64'), 'rb') as f:
        hdr = f.read(0x400)
        io, ic = struct.unpack_from('<II', hdr, 0x1c0)
        if ic == 0:
            io, ic = struct.unpack_from('<II', hdr, 0x18)
        f.seek(io)
        raw = f.read(32 * ic)
        out = []
        for i in range(ic):
            a, _, _, po, _ = struct.unpack_from('<QQQII', raw, 32 * i)
            f.seek(po)
            out.append((a, f.read(256).split(b'\0')[0].decode()))
    return sorted(out)


def dis(d, va, n):
    base = va & ~0xfff
    tmp = tempfile.mkdtemp(prefix='dsc-dis-')
    try:
        b, o = os.path.join(tmp, 'c.bin'), os.path.join(tmp, 'c.o')
        with open(b, 'wb') as h:
            h.write(read(d, base, n + (va - base)))
        subprocess.run(['llvm-objcopy', '-I', 'binary', '-O', 'elf64-littleaarch64',
                        '--rename-section=.data=.text,alloc,load,code', b, o], check=True)
        r = subprocess.run(['llvm-objdump', '-d', '--no-show-raw-insn', '--triple=aarch64',
                            '--adjust-vma=%#x' % base, o], check=True, capture_output=True, text=True)
        for line in r.stdout.splitlines():
            m = re.match(r'\s*([0-9a-f]+):', line)
            if m and int(m.group(1), 16) >= va:
                print(re.sub(r' *<_binary[^>]*>', '', line))
    finally:
        shutil.rmtree(tmp)


def strs(d, texts):
    imgs = images(d)
    addrs = [a for a, _ in imgs]
    for f, maps in caches(d):
        with open(f, 'rb') as h:
            m = mmap.mmap(h.fileno(), 0, access=mmap.ACCESS_READ)
            for t in texts:
                for hit in re.finditer(re.escape(b'\0' + t.encode() + b'\0'), m):
                    off = hit.start() + 1
                    for a, s, fo in maps:
                        if fo <= off < fo + s:
                            va = a + off - fo
                            i = bisect.bisect_right(addrs, va) - 1
                            print('%s %#x %s' % (t, va, imgs[i][1] if i >= 0 else '?'))


def main():
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    d, cmd = sys.argv[1], sys.argv[2]
    if cmd == 'dis' and len(sys.argv) == 5:
        dis(d, int(sys.argv[3], 16), int(sys.argv[4], 0))
    elif cmd == 'read' and len(sys.argv) == 5:
        sys.stdout.buffer.write(read(d, int(sys.argv[3], 16), int(sys.argv[4], 0)))
    elif cmd == 'str':
        strs(d, sys.argv[3:])
    else:
        sys.exit(__doc__)


if __name__ == '__main__':
    main()
