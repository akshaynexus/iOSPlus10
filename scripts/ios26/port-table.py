#!/usr/bin/env python3
"""Markdown table of the iOS 16 kernel patches on xnu-12377 for docs/ios26-port-status.md.

    scripts/ios26/port-table.py out/kernel/local-ios26/patch-check.tsv [PATCH_DIR...] > table.md

PATCH_DIRs (default: external/slop/negroni-ios/xnu/patches and patches/xnu) give each patch's files: a patch that
only touches driver files is marked as carried by 0006 (bsd/dev) / 0007 (IOKit drivers).

Columns: patch, text result on 12377 (scripts/ios26/patch-check.sh: upstream / clean / fuzz / partial n/m / fail /
stage), family, state in the iOS 26 series (patches/xnu-12377): "ported (NNNN)", "reworked (NNNN)", "obsolete",
"replaced (NNNN)", "blocked: why", or "not started". STATE below is the hand-kept part; update it with each port.
"""
import csv, os, re, sys

# patch number (4 digits, slop 0001-0127 and ours 0200-0399) -> state in patches/xnu-12377
STATE = {
    '0001': 'obsolete: flag removed upstream',
    '0002': 'not started (dxb 26.0 + Xcode 27.1 build without it: [V] compile reached all of bsd/osfmk)',
    '0003': 'reworked (0004: fbcon_probe before the 12377 phandle lookup, outside PL011_UART)',
    '0004': 'reworked (0002 config, 0003 GIC/IRQ/start.s)',
    '0005': 'replaced (0005 native PAC, stage 2)',
    '0006': 'reworked (0002: 12377 MacOSX master + nos_arm_asm/nos_arm_pmap, no CPU counters)',
    '0007': 'not needed so far (12377 + UniXNU base, 0001)',
    '0008': 'reworked (0001 machine_routines_nos.c; 12377 has kpc.c; amcc via apple_amcc option)',
    '0010': 'ported (0003 start.s band, negroni_early.c)',
    '0009': 'reworked (0002: 12377 export lists, 48 names + IOUnifiedAddressTranslator)',
    '0011': 'ported (0003 arm_vm_init.c, file-level carry)',
    '0012': 'ported (0003 arm_init.c/arm_vm_init.c/negroni_early.c, 0004 pe_serial.c)',
    '0022': 'ported (0004 IOService.cpp, file-level carry); mockfs itself not started',
    '0037': 'not started (bindfs line in MASTER.arm64.negroni, with the root family)',
    '0047': 'ported (0004 serial_console.c tee, 0006 negroni_ufs.c log)',
    '0057': 'not started (config_ext_resolver off in MASTER.arm64.negroni, with the root family)',
    '0088': 'ported (0003 start.s/arm_vm_init.c/negroni_early.c, 0007 framebuffer/HID)',
    '0094': 'ported (0003 sleh.c negronitrace)',
    '0011': 'not started',
    '0012': 'not started',
    '0013': 'blocked: 12377 crypto init differs (corecrypto KPI v14); port UniXNU source corecrypto instead',
    '0014': 'blocked: same as 0013',
    '0015': 'not started (UniXNU native-trust-cache-runtime is the 12377 model)',
    '0016': 'ported (0004 NegroniPlatformExpert)',
    '0017': 'ported (0003 pe_fiq.c vtimer INTID from ADT)',
    '0018': 'ported (0004 NegroniCPU)',
    '0019': 'blocked: 12377 pthread callback ABI (UniXNU build-pthread-12377.py, libpthread-539)',
    '0065': 'ported (0003 start.s PSCI entry, 0004 NegroniCPU)',
    '0067': 'ported (0004 console mute)',
    '0078': 'ported (0003 8 cores)',
    '0082': 'ported (0003 redistributor stride)',
    '0083': 'ported (0003 no CNTP_CTL write)',
    '0084': 'ported (0003 IRQ trace)',
    '0085': 'ported (0003 kernel thread backtraces)',
    '0086': 'ported (0003)',
    '0126': 'ported (0001, from UniXNU zzx-pmap-sync-64bit-pa)',
    '0200': 'reworked (0004 IOStartIOKit)',
    '0288': 'ported (0003 negroni_cpuidle.c; RPMh hooks weak in 0004)',
    '0295': 'ported (0003 SPI dispatch)',
    '0297': 'reworked (0003: SEA FnV case next to the 12377 expected-fault PC match)',
    '0360': 'ported (0004 debug.c)',
    '0363': 'obsolete: 12377 BOOT_LINE_LENGTH is 1024',
    '0367': 'ported (0004 debug.c hook; bootlog in negroni_ufs.c not yet)',
    '0378': 'obsolete with 0363 [I] (check the truncation code)',
    '0382': 'ported (0004 negroni_top.c, 0003 cpuidle)',
    '0383': 'ported (0003 cpuidle part); negroni_rpmh.c not started',
}

FAMILY = [
    (r'framebuffer|fb-|fbcon|display|panel|dsi|dpu|te-', 'display'),
    (r'machine-config|master-config|smp|psci|gic|timer|boot-cpu|cpuidle|cpu-idle|physmap|pmap|io-submap|early|mmio|irq', 'machine'),
    (r'amfi|trust-cache|sandbox|entitle|cs-signed', 'codesign/sandbox'),
    (r'aks|applekeystore|keystore', 'AKS'),
    (r'pthread|bearssl|sha|md5|aes|prng|rng|crypto', 'crypto/pthread'),
    (r'hfs|mockfs|ramdisk|ufs|root|bindfs', 'storage/root'),
    (r'usb|ecm|command-server|live-log|panic-usb|bootlog|console|crash|log|trace|sampler|kmem-report', 'debug/USB'),
    (r'gpu|adreno|surface|iomfb|accel|kgsl', 'GPU/IOSurface'),
    (r'wifi|wlan|apple80211', 'Wi-Fi'),
    (r'bt-', 'Bluetooth'),
    (r'audio|adsp|tfa|slpi', 'audio/DSP'),
    (r'battery|charg|vooc|typec|thermal|cpufreq|power|reboot|pon|rtc|calendar|watchdog', 'power/thermal'),
    (r'touch|keys|hid|haptic|vibrator|fingerprint|fp-', 'input/haptics'),
    (r'cam-', 'camera'),
]


def family(name):
    for rx, fam in FAMILY:
        if re.search(rx, name):
            return fam
    return 'other'


DRV_BSD = re.compile(r'^(bsd/dev/negroni_|bsd/conf/files$)')
DRV_IOK = re.compile(r'^(iokit/Kernel/arm/(Negroni|hid/)|iokit/conf/files\.arm64$|iokit/KernelConfigTables\.cpp$)')
OURS = re.compile(r'^(osfmk/arm64/(negroni_|start\.s|sleh\.c|cpu\.c|machine_routines\.c|arm_vm_init\.c|caches_asm\.s|proc_reg\.h)|'
                  r'pexpert/|osfmk/console/serial_console\.c|osfmk/kern/(debug\.c|negroni_top\.c)|osfmk/arm/(arm_init|model_dep)\.c|'
                  r'iokit/Kernel/(IOStartIOKit|IOService)\.cpp|makedefs/|config/)')


def files_of(name, dirs):
    for d in dirs:
        f = os.path.join(d, name)
        if os.path.exists(f):
            return sorted(set(re.findall(r'^\+\+\+ b/(\S+)', open(f, errors='ignore').read(), re.M)))
    return []


def auto_state(files):
    if not files:
        return None
    bsd = all(DRV_BSD.match(f) for f in files)
    iok = all(DRV_IOK.match(f) for f in files)
    both = all(DRV_BSD.match(f) or DRV_IOK.match(f) for f in files)
    if bsd:
        return 'ported as is (0006), compiles [V]'
    if iok:
        return 'ported as is (0007), compile level [V]; user-client ABI not re-traced'
    if both:
        return 'ported as is (0006 + 0007), compiles [V]'
    rest = [f for f in files if not (DRV_BSD.match(f) or DRV_IOK.match(f) or OURS.match(f))]
    if not rest:
        return None
    drv = any(DRV_BSD.match(f) or DRV_IOK.match(f) for f in files)
    head = 'driver part in 0006/0007; ' if drv else ''
    return head + 'core hooks not started: ' + ', '.join(rest[:4]) + (' ...' if len(rest) > 4 else '')


def main():
    rows = list(csv.DictReader(open(sys.argv[1]), delimiter='\t'))
    here = os.path.dirname(os.path.abspath(__file__))
    repo = os.path.dirname(os.path.dirname(here))
    dirs = sys.argv[2:] or [os.path.join(repo, 'external/slop/negroni-ios/xnu/patches'), os.path.join(repo, 'patches/xnu')]
    print('| Patch | Text on 12377 | Family | iOS 26 series state |')
    print('|---|---|---|---|')
    for r in rows:
        n = r['patch']
        num = n[:4]
        st = r['status']
        if st == 'partial':
            st = f"partial {r['hunks_failed']}/{r['hunks_total']} failed"
        elif st == 'fail':
            st = f"fail {r['hunks_failed']}/{r['hunks_total']}"
        state = STATE.get(num) or auto_state(files_of(n, dirs)) or 'not started'
        if n.endswith('.sh'):
            state = {'0019': STATE['0019'], '0020': 'not started (BearSSL stage, crypto family)',
                     '0026': 'not started (hfs-? tag that matches 12377 must be picked)'}.get(num, state)
        print(f'| `{n}` | {st} | {family(n)} | {state} |')


if __name__ == '__main__':
    main()
