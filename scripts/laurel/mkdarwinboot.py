#!/usr/bin/env python3
"""UniXNU payload volume (FAT) for the Mi A3 (laurel_sprout) XNU kernel, booted by DarwinBoot.

usage: mkdarwinboot.py KERNEL ADT OUT.img --cmdline "..." [--size-mib 48] [--timeout 3]

Port of external/slop/negroni-ios/tools/mkdarwinboot.py to the topaz tool chain (external/ios-topaz/tools/mkpayload.py
gives parse_macho/apply_chained_fixups). DarwinBoot copies the kernel's segments as they are in the file, so the
chained rebases that mkpayload.py applied at payload time are applied here, to the file. The ADT must carry
/chosen/darwinboot-memory-size (scripts/laurel/mkadt.py --darwinboot). Layout (external/UniXNU/docs/concepts/payload.md):
  /EFI/UniXNU/unixnu.toml   /Payloads/kernel.macho   /Payloads/kernel.macho.adt
The volume becomes the ramdisk of the Android boot image (scripts/laurel/uefi-image.sh); NegroniBootMemoryDxe publishes
it as a block device, UniXNU finds unixnu.toml on it. Needs pyfatfs (out/venv, scripts/setup/native-tools.sh).
"""
import os, re, shutil, sys, tempfile

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
sys.path.insert(0, os.path.join(REPO, 'external', 'ios-topaz', 'tools'))
from mkpayload import parse_macho, apply_chained_fixups  # noqa: E402

TOML = '''version = 1

[boot]
timeout = {timeout}
default = "ios16"

[ui]
title = "laurel-ios"

[[entry]]
id = "ios16"
title = "iOS 16 (laurel XNU, TOPAZ_4K)"
type = "xnu"
# UEFI FAT paths: backslashes (DarwinBoot passes the path through unchanged)
path = '\\Payloads\\kernel.macho'
args = "{cmdline}"
'''


def main():
    a = sys.argv[1:]

    def opt(name, default=None):
        if name in a:
            i = a.index(name); v = a[i + 1]; del a[i:i + 2]; return v
        return default
    cmdline = opt('--cmdline', '')
    size = int(opt('--size-mib', '48'))
    timeout = int(opt('--timeout', '3'))
    if len(a) != 3:
        sys.exit(__doc__)
    kernel, adt, out = a
    # UniXNU's own rule (docs/concepts/payload.md): [A-Za-z0-9_.-]+ with an optional =[A-Za-z0-9_.,-]+; <= 1000 bytes
    for tok in cmdline.split():
        if not re.fullmatch(r'[A-Za-z0-9_.\-]+(=[A-Za-z0-9_.,\-]+)?', tok):
            sys.exit(f'mkdarwinboot: boot-arg {tok!r} has characters UniXNU refuses')
    if len(cmdline.encode()) > 1000:
        sys.exit(f'mkdarwinboot: command line is {len(cmdline.encode())} bytes; UniXNU takes at most 1000')
    buf = bytearray(open(kernel, 'rb').read())
    n = apply_chained_fixups(buf, parse_macho(buf))
    d = tempfile.mkdtemp()
    try:
        os.makedirs(f'{d}/EFI/UniXNU'); os.makedirs(f'{d}/Payloads')
        open(f'{d}/Payloads/kernel.macho', 'wb').write(buf)
        shutil.copy(adt, f'{d}/Payloads/kernel.macho.adt')
        open(f'{d}/EFI/UniXNU/unixnu.toml', 'w').write(TOML.format(timeout=timeout, cmdline=cmdline.replace('"', '\\"')))
        if os.path.exists(out):
            os.remove(out)
        with open(out, 'wb') as f:
            f.truncate(size << 20)
        from pyfatfs.PyFat import PyFat
        from pyfatfs.PyFatFS import PyFatFS
        pf = PyFat(); pf.mkfs(out, fat_type=PyFat.FAT_TYPE_FAT32, label='LAURELESP', size=size << 20); pf.close()
        fs = PyFatFS(out)
        for root, dirs, files in os.walk(d):
            rel = os.path.relpath(root, d).replace(os.sep, '/')
            rel = '' if rel == '.' else rel
            for dn in dirs:
                fs.makedir(f'/{rel}/{dn}'.replace('//', '/'))
            for fn in files:
                with open(os.path.join(root, fn), 'rb') as src, fs.openbin(f'/{rel}/{fn}'.replace('//', '/'), 'w') as dst:
                    shutil.copyfileobj(src, dst)
        fs.close()
    finally:
        shutil.rmtree(d)
    print(f'{out}: {n} rebases applied, kernel {len(buf)} bytes, {size} MiB FAT')


if __name__ == '__main__':
    main()
