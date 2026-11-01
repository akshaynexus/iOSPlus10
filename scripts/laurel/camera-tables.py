#!/usr/bin/env python3
"""Mi A3 camera: dump the register tables of an mm-camera2 sensor library (reference for the kernel parser).

  scripts/laurel/camera-tables.py LIB.so [MODE]      (default mode: the 1280x720 one)

Independent second reading of the layout that bsd/dev/laurel_cam_lib.h (kernel patch 2771) uses; the host test
(scripts/laurel/cam-test.sh) compares this output with the C parser's output for every library in
out/laurel/camera/lib/. Output (text, stdout only; the tables are Sony/Xiaomi data and never go into git):
  lib NAME slave 0x34 id 0x0586@0x0016 modes 7 lanes 4 settle 0x13 3phase 0 filter 3
  mode K WxH line L frame F vt V op O dt 0x2b decode 2
  init N
  0x0136 0x18 0
  ...
  res K N
  0x0112 0x0a 0
"""
import struct
import sys

REGS, ENTRY = 3000, 8
INIT, RES, RES_STRIDE = 0x9F2C, 0x5C090, 0x5DD0
OUT_INFO, OUT_REC, CSI, LUT, LUT_STRIDE, OUTPUT = 0xAE1F0, 0x60, 0xAE740, 0xAE744, 0x104, 0x5FA4


def data_section(b):
    if b[:4] != b"\x7fELF" or b[4] != 1 or b[5] != 1:
        raise SystemExit("not an ELF32 LE file")
    shoff, = struct.unpack_from("<I", b, 0x20)
    shent, shnum, shstr = struct.unpack_from("<HHH", b, 0x2E)
    secs = [struct.unpack_from("<10I", b, shoff + i * shent) for i in range(shnum)]
    stroff = secs[shstr][4]
    for s in secs:
        if b[stroff + s[0]:stroff + s[0] + 6] == b".data\0":
            return b[s[4]:s[4] + s[5]]
    raise SystemExit("no .data")


def table(d, off):
    addr_type, data_type = struct.unpack_from("<II", d, off + REGS * ENTRY + 4)
    if (addr_type, data_type) != (2, 1):
        raise SystemExit("table at %#x: trailer %d/%d, not 2/1" % (off, addr_type, data_type))
    out = []
    for i in range(REGS):
        a, v, dl = struct.unpack_from("<HHI", d, off + i * ENTRY)
        if a == 0:
            break
        out.append((a, v & 0xFF, dl))
    return out


def main():
    b = open(sys.argv[1], "rb").read()
    d = data_section(b)
    name = d[:32].split(b"\0")[0].decode()
    slave, = struct.unpack_from("<I", d, 0x20)
    id_reg, cid = struct.unpack_from("<HH", d, 0x30)
    n, = struct.unpack_from("<I", d, OUT_INFO)
    lanes, settle, ph3 = d[CSI], d[CSI + 1], d[CSI + 2]
    filt, = struct.unpack_from("<I", d, OUTPUT + 12)
    print("lib %s slave 0x%02x id 0x%04x@0x%04x modes %d lanes %d settle 0x%02x 3phase %d filter %d" % (
        name, slave, cid, id_reg, n, lanes, settle, ph3, filt))
    want = None
    for k in range(n):
        r = OUT_INFO + 8 + k * OUT_REC
        w, h, ll, fl = struct.unpack_from("<4H", d, r)
        vt, = struct.unpack_from("<I", d, r + 12)
        op, = struct.unpack_from("<Q", d, r + 0x58)
        lut = LUT + k * LUT_STRIDE
        print("mode %d %dx%d line %d frame %d vt %d op %d dt 0x%02x decode %d" % (
            k, w, h, ll, fl, vt, op, d[lut + 5], d[lut + 6]))
        if (w, h) == (1280, 720) and want is None:
            want = k
    if len(sys.argv) > 2:
        want = int(sys.argv[2])
    t = table(d, INIT)
    print("init %d" % len(t))
    for a, v, dl in t:
        print("0x%04x 0x%02x %d" % (a, v, dl))
    if want is not None:
        t = table(d, RES + want * RES_STRIDE)
        print("res %d %d" % (want, len(t)))
        for a, v, dl in t:
            print("0x%04x 0x%02x %d" % (a, v, dl))


if __name__ == "__main__":
    main()
