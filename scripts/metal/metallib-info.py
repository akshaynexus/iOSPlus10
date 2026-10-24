#!/usr/bin/env python3
"""Print the header and the function table of Apple .metallib files (MTLB container).

    scripts/metal/metallib-info.py FILE.metallib [...]          one summary line per file + functions
    scripts/metal/metallib-info.py --summary FILE.metallib [...] one line per file
    scripts/metal/metallib-info.py --extract DIR FILE.metallib   write each function's AIR bitcode to DIR

Format reference: YuAo/MetalLibraryArchive (MIT) README and steelbrain/metal2vulkan
container/mtlb.rs. Header (88 bytes): 'MTLB', target u16, version u16.u16, type u8, os u8,
os version u16.u16, file size u64, then (offset u64, size u64) for: function list, public
metadata, private metadata, bitcode. Function list: u32 count, then per function u32 size and
tags (4-char name, u16 length, data) up to ENDT.
Function types (TYPE tag): 0 vertex, 1 fragment, 2 kernel, 3 unqualified, 4 visible, 5 extern,
6 intersection.
"""
import os
import struct
import sys

FTYPES = {0: "vertex", 1: "fragment", 2: "kernel", 3: "unqualified", 4: "visible",
          5: "extern", 6: "intersection"}


def parse(path):
    with open(path, "rb") as f:
        data = f.read()
    if data[:4] != b"MTLB":
        raise ValueError("not a metallib (no MTLB magic)")
    target, vmaj, vmin, ftype, osid, osmaj, osmin = struct.unpack_from("<HHHBBHH", data, 4)
    fsize, = struct.unpack_from("<Q", data, 16)
    secs = struct.unpack_from("<8Q", data, 24)
    flist_off, flist_size, _pub_off, _pub_size, _prv_off, _prv_size, bc_off, bc_size = secs
    hdr = dict(path=path, target=target, version=f"{vmaj}.{vmin & 0x7fff}", type=ftype,
               os=osid, os_version=f"{osmaj}.{osmin}", file_size=fsize, bitcode_size=bc_size)
    funcs = []
    count, = struct.unpack_from("<I", data, flist_off)
    p = flist_off + 4
    for _ in range(count):
        size, = struct.unpack_from("<I", data, p)
        q, end = p + 4, p + size
        fn = {}
        while q + 4 <= end:
            tag = data[q:q + 4].decode("ascii", "replace")
            if tag == "ENDT":
                break
            ln, = struct.unpack_from("<H", data, q + 4)
            val = data[q + 6:q + 6 + ln]
            q += 6 + ln
            if tag == "NAME":
                fn["name"] = val.rstrip(b"\0").decode("utf-8", "replace")
            elif tag == "TYPE":
                fn["type"] = FTYPES.get(val[0], str(val[0]))
            elif tag == "VERS":
                a, b, c, d = struct.unpack_from("<HHHH", val)
                fn["air"] = f"{a}.{b}"
                fn["msl"] = f"{c}.{d}"
            elif tag == "OFFT":
                fn["offsets"] = struct.unpack_from("<QQQ", val)
            elif tag == "MDSZ":
                fn["bitcode_size"], = struct.unpack_from("<Q", val)
            else:
                fn.setdefault("tags", []).append(tag)
        funcs.append(fn)
        p = end
    hdr["bitcode_off"] = bc_off
    return hdr, funcs, data


def main(argv):
    summary = "--summary" in argv
    argv = [a for a in argv if a != "--summary"]
    outdir = None
    if argv[:1] == ["--extract"]:
        outdir, argv = argv[1], argv[2:]
        os.makedirs(outdir, exist_ok=True)
    if not argv:
        print(__doc__)
        return 1
    rc = 0
    for path in argv:
        try:
            hdr, funcs, data = parse(path)
        except Exception as e:  # report and go on with the next file
            print(f"{path}: ERROR {e}")
            rc = 1
            continue
        kinds = {}
        for fn in funcs:
            kinds[fn.get("type", "?")] = kinds.get(fn.get("type", "?"), 0) + 1
        airs = sorted({fn.get("air", "?") for fn in funcs})
        msls = sorted({fn.get("msl", "?") for fn in funcs})
        print(f"{path}: MTLB v{hdr['version']} os={hdr['os']} {hdr['os_version']} "
              f"functions={len(funcs)} {kinds} AIR={','.join(airs)} MSL={','.join(msls)} "
              f"bitcode={hdr['bitcode_size']}")
        if summary:
            continue
        for fn in funcs:
            print(f"  {fn.get('type', '?'):12} {fn.get('name', '?'):60} AIR {fn.get('air', '?')}")
            if outdir and "offsets" in fn:
                bc = hdr["bitcode_off"] + fn["offsets"][2]
                size = fn.get("bitcode_size", 0)
                name = fn.get("name", "fn").replace("/", "_")
                base = os.path.basename(path).rsplit(".", 1)[0]
                with open(os.path.join(outdir, f"{base}.{name}.air.bc"), "wb") as o:
                    o.write(data[bc:bc + size])
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
