#!/usr/bin/env python3
"""Does the 20H392 dyld cache export what a plug-in imports? dyld refuses a file with a missing import, and VideoToolbox ignores a failed dlopen without a
word, so this is checked at build time, not on the phone. Also checks the private symbols vt_plugin dlsyms.
  scripts/laurel/hevc-check-imports.py CACHE_DIR out/laurel/hevc/HEVCH8.videodecoder    (python3 -I; exit 1 when one is missing)
"""
import importlib.util, os, re, subprocess, sys
spec = importlib.util.spec_from_file_location('dsc', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'dsc-image.py'))
D = importlib.util.module_from_spec(spec)
spec.loader.exec_module(D)
PRIVATE = 'VTVideoDecoderGetClassID CMDerivedObjectCreate CMBaseObjectGetDerivedStorage VTDecoderSessionSetPixelBufferAttributes VTDecoderSessionGetPixelBufferPool ' \
          'VTDecoderSessionEmitDecodedFrame VTDecoderSessionGetDestinationPixelBufferAttributes VTRegisterVideoDecoderWithInfo kVTVideoDecoder_IsHardwareAccelerated ' \
          'kVTVideoDecoderInfo_Rating'.split()


def main():
    c = D.Cache(sys.argv[1])
    have = set()
    for va, path in c.imgs:
        if re.search(r'/usr/lib/system/|/(CoreFoundation|CoreMedia|CoreVideo|VideoToolbox)$|libobjc\.A|libSystem', path):
            im = D.Image(c, va)
            if im.trie and im.trie[1]:
                have.update(n for n, _, _ in D.walk_trie(im.link(*im.trie)))
    out = subprocess.run(['llvm-nm', '-u', sys.argv[2]], capture_output=True, text=True, check=True).stdout
    need = [l.split()[-1] for l in out.splitlines() if l.strip()]
    miss = [n for n in need if n not in have and n != 'dyld_stub_binder']
    miss_private = [n for n in PRIVATE if '_' + n not in have]
    print('hevc-check-imports: %d imports, %d exports in the cache, missing: %s; private missing: %s' % (len(need), len(have), miss or 'none', miss_private or 'none'))
    return 1 if miss or miss_private else 0


if __name__ == '__main__':
    sys.exit(main())
