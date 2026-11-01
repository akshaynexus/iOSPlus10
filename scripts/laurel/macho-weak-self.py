#!/usr/bin/env python3
"""macho-weak-self.py DYLIB: the optional imports of a Mach-O looked up in itself, not in every image of the process.

Turnip has about 3300 weak imports: the entrypoint tables' entrypoints that no layer defines, all absent. Mesa's Darwin link
(-undefined dynamic_lookup) makes each a flat lookup: dyld asks every loaded image for each one when the library loads. The cost
grows with the images of the process [I]: boot 2026-11-01 18:40, plug-in check to RedwoodGPU open: 3 s in small processes, 10 s of
device open in SpringBoard [V], and a poster has 5 s until launchd kills it (docs/laurel_sprout/metal.md section 11). In the
chained-fixups import table each weak import with library ordinal FLAT_LOOKUP (-2) gets SELF (0): dyld looks in this image's
exports only, finds nothing, and a missing weak import is NULL as before. In place, same size; sign it again afterwards. Prints one
line with the count. Runs with python3 -I; macOS + Linux.
"""
import struct
import sys

LC_DYLD_CHAINED_FIXUPS = 0x80000034
MH_MAGIC_64 = 0xFEEDFACF
FLAT = 0xFE  # BIND_SPECIAL_DYLIB_FLAT_LOOKUP (-2) in 8 bits


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    path = sys.argv[1]
    with open(path, "rb") as f:
        data = bytearray(f.read())
    magic, _, _, _, ncmds, _, _, _ = struct.unpack_from("<8I", data, 0)
    if magic != MH_MAGIC_64:
        sys.exit("macho-weak-self: %s: not a thin 64-bit Mach-O" % path)
    off, fixups = 32, None
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, off)
        if cmd == LC_DYLD_CHAINED_FIXUPS:
            fixups = struct.unpack_from("<I", data, off + 8)[0]
        off += size
    if fixups is None:
        sys.exit("macho-weak-self: %s: no LC_DYLD_CHAINED_FIXUPS" % path)
    _, _, imports, _, count, form, _ = struct.unpack_from("<7I", data, fixups)
    if form not in (1, 2):  # DYLD_CHAINED_IMPORT, DYLD_CHAINED_IMPORT_ADDEND: lib_ordinal:8 weak_import:1 name_offset:23
        sys.exit("macho-weak-self: %s: import format %d not handled" % (path, form))
    step = 4 if form == 1 else 8
    changed = weak_other = 0
    for i in range(count):
        at = fixups + imports + i * step
        word = struct.unpack_from("<I", data, at)[0]
        if not word & 0x100:
            continue
        if word & 0xFF == FLAT:
            struct.pack_into("<I", data, at, word & ~0xFF)
            changed += 1
        elif word & 0xFF != 0:
            weak_other += 1
    with open(path, "wb") as f:
        f.write(data)
    print("macho-weak-self: %d of %d imports: flat lookup -> this image (%d other weak imports stay)" % (changed, count, weak_other))


main()
