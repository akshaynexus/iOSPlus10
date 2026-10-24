#!/usr/bin/env python3
"""Check that every symbol a Mach-O imports exists in the target iOS's dyld shared cache.

Binaries built with a new SDK (iPhoneOS 27.1) for iOS 16.0 can import symbols iOS 16 does not have (ios-flame
HANDOFF "the strchrnul lesson": a weak import silently resolves to NULL; a strong one stops dyld). This lists
the imports with `nm -m` and the exports of the cache images with `ipsw dyld macho --symbols` (cached in
out/metal/spi/exports/).

    scripts/metal/check-imports.py DSC BINARY [BINARY...]
    DSC = MOUNTED_ROOT/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64
Exit code: 0 = all found, 1 = missing symbols (listed), 2 = usage/tool error.
"""
import concurrent.futures
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CACHE = os.path.join(REPO, "out", "metal", "spi", "exports")

# what "(from X)" names in nm -m output, as cache image paths (libSystem and libc++ re-export several images)
IMAGES = {
    "libSystem": ["/usr/lib/libSystem.B.dylib", "/usr/lib/system/libsystem_c.dylib", "/usr/lib/system/libsystem_kernel.dylib",
                  "/usr/lib/system/libsystem_pthread.dylib", "/usr/lib/system/libsystem_malloc.dylib",
                  "/usr/lib/system/libdyld.dylib", "/usr/lib/system/libsystem_info.dylib",
                  "/usr/lib/system/libsystem_platform.dylib", "/usr/lib/system/libdispatch.dylib",
                  "/usr/lib/system/libsystem_m.dylib", "/usr/lib/system/libsystem_darwin.dylib",
                  "/usr/lib/system/libsystem_trace.dylib", "/usr/lib/system/libsystem_blocks.dylib",
                  "/usr/lib/system/libunwind.dylib", "/usr/lib/system/libcompiler_rt.dylib",
                  "/usr/lib/system/libsystem_c.dylib", "/usr/lib/system/libxpc.dylib",
                  "/usr/lib/system/libsystem_containermanager.dylib", "/usr/lib/system/libcommonCrypto.dylib",
                  "/usr/lib/system/libcorecrypto.dylib", "/usr/lib/system/libsystem_featureflags.dylib",
                  "/usr/lib/system/libsystem_notify.dylib", "/usr/lib/system/libsystem_sandbox.dylib",
                  "/usr/lib/system/libsystem_networkextension.dylib", "/usr/lib/system/libsystem_asl.dylib",
                  "/usr/lib/system/libsystem_symptoms.dylib", "/usr/lib/system/libmacho.dylib",
                  "/usr/lib/system/libcopyfile.dylib", "/usr/lib/system/libremovefile.dylib",
                  "/usr/lib/system/libsystem_coreservices.dylib", "/usr/lib/system/libsystem_dnssd.dylib",
                  "/usr/lib/system/libkeymgr.dylib", "/usr/lib/system/libcache.dylib", "/usr/lib/system/libsystem_configuration.dylib",
                  "/usr/lib/system/liboah.dylib", "/usr/lib/system/libsystem_collections.dylib"],
    "libc++": ["/usr/lib/libc++.1.dylib", "/usr/lib/libc++abi.dylib"],
    "libobjc": ["/usr/lib/libobjc.A.dylib"],
    "Foundation": ["/System/Library/Frameworks/Foundation.framework/Foundation"],
    "CoreFoundation": ["/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"],
    "Metal": ["/System/Library/Frameworks/Metal.framework/Metal"],
    "IOSurface": ["/System/Library/Frameworks/IOSurface.framework/IOSurface"],
    "IOKit": ["/System/Library/Frameworks/IOKit.framework/Versions/A/IOKit"],
    "Security": ["/System/Library/Frameworks/Security.framework/Security"],
}
SYM = re.compile(r"\s(_[^\s]+)\s*$")


UNDEF = re.compile(r"\(undefined\) external\s+(_\S+)\s+\(from ([^)]+)\)")


def exports(dsc, image):
    os.makedirs(CACHE, exist_ok=True)
    out = os.path.join(CACHE, image.strip("/").replace("/", "_") + ".txt")
    if not os.path.exists(out):
        r = subprocess.run(["ipsw", "dyld", "macho", dsc, image, "--symbols"], capture_output=True, text=True)
        with open(out, "w") as f:
            f.write(r.stdout)
    syms, used = set(), set()
    with open(out) as f:
        for line in f:
            if "(undefined)" in line:
                # what this iOS's own images import from a library: proof that the library exports it there
                # (re-exports and resolvers, e.g. libsystem_c's memcpy, are in the export trie but not in nlist)
                m = UNDEF.search(line)
                if m:
                    used.add((m.group(1), os.path.basename(m.group(2))))
                continue
            if "external" not in line:
                continue
            m = SYM.search(line.rstrip())
            if m:
                syms.add(m.group(1))
    return syms, used


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    dsc, bins = argv[0], argv[1:]
    need = {}  # lib -> {sym: [bins]}
    for b in bins:
        r = subprocess.run(["nm", "-m", b], capture_output=True, text=True)
        for line in r.stdout.splitlines():
            if "(undefined)" not in line:
                continue
            m = re.search(r"external (\S+) \(from ([^)]+)\)", line)
            if not m:
                continue
            sym, lib = m.group(1), m.group(2)
            need.setdefault(lib, {}).setdefault(sym, []).append(os.path.basename(b))
    images = sorted({i for lib in need for i in IMAGES.get(lib, [])})
    with concurrent.futures.ThreadPoolExecutor(max_workers=os.cpu_count() or 4) as ex:
        have = dict(zip(images, ex.map(lambda i: exports(dsc, i), images)))
    missing = 0
    imported = set().union(*(u for _, u in have.values())) if have else set()
    for lib, syms in sorted(need.items()):
        if lib not in IMAGES:
            print(f"check-imports: unknown library {lib} ({len(syms)} symbols): not checked")
            continue
        names = {os.path.basename(i) for i in IMAGES[lib]}
        pool = set().union(*(have[i][0] for i in IMAGES[lib]))
        pool |= {sym for sym, frm in imported if frm in names}
        pool |= {"_" + sym[len("__platform_"):] for sym in pool if sym.startswith("__platform_")}
        for sym, users in sorted(syms.items()):
            if sym not in pool:
                missing += 1
                print(f"check-imports: MISSING {sym} (from {lib}) in {','.join(sorted(set(users)))}")
        print(f"check-imports: {lib}: {len(syms)} imports checked")
    print(f"check-imports: {'FAIL' if missing else 'PASS'} ({missing} missing)")
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
