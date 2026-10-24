#!/usr/bin/env python3
"""Extract the payload of an IM4P file (Apple firmware container, DER).

    im4p-extract.py IN.im4p OUT

IM4P = SEQUENCE { IA5String "IM4P", IA5String type, IA5String desc, OCTET STRING payload, ... }.
Payloads: raw, or LZFSE ('bvx2...'): decoded with macOS libcompression (ctypes) or, on Linux, the
`lzfse` tool (apt install lzfse). 'complzss' (old kernelcaches) is not supported.
"""
import ctypes, ctypes.util, shutil, subprocess, sys

def lzfse_decode(data):
    lib = ctypes.util.find_library('compression')
    if lib:                                     # macOS
        c = ctypes.CDLL(lib)
        c.compression_decode_buffer.restype = ctypes.c_size_t
        size = len(data) * 8
        while True:
            dst = ctypes.create_string_buffer(size)
            n = c.compression_decode_buffer(dst, size, data, len(data), None, 0x801)  # COMPRESSION_LZFSE
            if n == 0: raise SystemExit('LZFSE decode failed')
            if n < size: return dst.raw[:n]
            size *= 4
    if shutil.which('lzfse'):
        return subprocess.run(['lzfse', '-decode'], input=data, capture_output=True, check=True).stdout
    raise SystemExit('LZFSE payload: need macOS libcompression or the lzfse tool (apt install lzfse)')

def der(buf, i):
    tag = buf[i]; i += 1
    n = buf[i]; i += 1
    if n & 0x80:
        k = n & 0x7f
        n = int.from_bytes(buf[i:i + k], 'big'); i += k
    return tag, buf[i:i + n], i + n

def main():
    data = open(sys.argv[1], 'rb').read()
    tag, seq, _ = der(data, 0)
    assert tag == 0x30, 'not a DER sequence'
    i, items = 0, []
    while i < len(seq):
        t, v, i = der(seq, i)
        items.append((t, v))
    assert items[0] == (0x16, b'IM4P'), 'not an IM4P'
    kind = items[1][1].decode()
    payload = next(v for t, v in items[3:] if t == 0x04)
    if payload[:8] == b'complzss':
        sys.exit(f'{kind}: complzss payload is not supported')
    if payload[:4] == b'bvx2':
        payload = lzfse_decode(payload)
    open(sys.argv[2], 'wb').write(payload)
    print(f'{kind}: {len(payload)} bytes -> {sys.argv[2]}')

if __name__ == '__main__':
    main()
