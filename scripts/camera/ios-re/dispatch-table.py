#!/usr/bin/env python3
"""Dump an IOExternalMethodDispatch table from a plain (non-fileset) arm64 kernelcache.

  dispatch-table.py KERNELCACHE VMADDR COUNT

Entry = {u64 function, u32 scalarIn, u32 structIn, u32 scalarOut, u32 structOut} (24 bytes; 0xffffffff =
variable). The vm -> file map comes from the LC_SEGMENT_64 commands of the Mach-O header.
20H392 iPhone10,3 AppleH10CamInUserClient: VMADDR 0xfffffff006f3c768, COUNT 94 (found by a stride-24
pointer scan of the kext __DATA_CONST, 2026-10-26). Read only. Run with python3 -I.
"""
import struct
import sys


def segments(d):
    magic, _, _, _, ncmds, _, _, _ = struct.unpack_from("<8I", d, 0)
    if magic != 0xfeedfacf:
        sys.exit("not a 64-bit Mach-O (decompress the kernelcache first)")
    at, segs = 32, []
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", d, at)
        if cmd == 0x19:
            vmaddr, vmsize, fileoff, filesize = struct.unpack_from("<4Q", d, at + 24)
            segs.append((vmaddr, vmsize, fileoff, filesize))
        at += size
    return segs


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    d = open(sys.argv[1], "rb").read()
    va, n = int(sys.argv[2], 0), int(sys.argv[3], 0)
    for vmaddr, vmsize, fileoff, filesize in segments(d):
        if vmaddr <= va < vmaddr + min(vmsize, filesize):
            off = fileoff + va - vmaddr
            break
    else:
        sys.exit(f"{va:#x} is not in a file-backed segment")
    print("# sel handler scalarIn structIn scalarOut structOut   (0xffffffff = variable)")
    for i in range(n):
        fn, si, sti, so, sto = struct.unpack_from("<Q4I", d, off + 24 * i)
        print(f"{i:2d} {fn:#x} {si} {sti} {so} {sto}")


main()
