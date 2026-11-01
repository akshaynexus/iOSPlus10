#!/usr/bin/env python3
"""Mi A3 root: launchd jobs out that only burn CPU here (docs/laurel_sprout/battery-power.md "What burns the CPU").

    root-tweaks-perf.py MOUNTED_ROOT         (root.sh runs it on the mounted root)
    root-tweaks-perf.py --self-test          (host check on a made-up launchd.plist)

Env PERF_DROP_JOBS: program names, space separated; default below; empty: nothing removed.
launchd reads only System/Library/xpc/launchd.plist (docs/usb-network.md). A job is found by its program name, not by
its label. A name that has no job prints one line and is no error (the root may change).

Evidence [V logs/laurel-boot-1907.txt, laurel-boot-1934.txt of 2026-11-01]:
  nanotimekitcompaniond  48 starts in 9 min, median gap 11 s, no CRASH line: Apple Watch face companion; no watch here.
  wifip2pd               51 starts in 9 min, median gap 10 s, no CRASH line: Wi-Fi Direct / AWDL daemon; the Mi A3 port has
                         no AWDL here: no awdl0, no AWDL data path (docs/laurel_sprout/airplay-airdrop.md: the evidence and when it may come back;
                         the kernel's LAUREL AWDL line must say "on" first).
  syncdefaultsd          13 CRASH sig 6 in the first 4 min of boot 19:34, then launchd gives up.
Each start also runs one xpcproxy. [I] Cost: small on average (bound in the doc), but each start wakes the governor.
"""
import os, plistlib, sys, tempfile

DEFAULT = 'nanotimekitcompaniond wifip2pd syncdefaultsd'
CACHE = 'System/Library/xpc/launchd.plist'


def program(job):
    prog = job.get('Program')
    if not prog:
        args = job.get('ProgramArguments') or ['']
        prog = args[0]
    return os.path.basename(prog)


def drop(root, names):
    path = os.path.join(root, CACHE)
    with open(path, 'rb') as f:
        plist = plistlib.load(f)
    gone = []
    for section in ('LaunchDaemons', 'LaunchAgents'):
        jobs = plist.get(section, {})
        for key in [k for k, j in jobs.items() if isinstance(j, dict) and program(j) in names]:
            gone.append((program(jobs[key]), key))
            del jobs[key]
    st = os.stat(path)
    with open(path, 'wb') as f:
        plistlib.dump(plist, f, fmt=plistlib.FMT_BINARY)
    os.chown(path, st.st_uid, st.st_gid)
    os.chmod(path, st.st_mode & 0o7777)
    found = {g[0] for g in gone}
    for name in names:
        print(f'laurel perf: {name}: ' + ('job removed' if name in found else 'no job in launchd.plist'))
    return gone


def self_test():
    with tempfile.TemporaryDirectory() as root:
        path = os.path.join(root, CACHE)
        os.makedirs(os.path.dirname(path))
        with open(path, 'wb') as f:
            plistlib.dump({'LaunchDaemons': {
                '/x/com.apple.wifip2pd.plist': {'Program': '/usr/sbin/wifip2pd'},
                '/x/com.apple.nanotime.plist': {'ProgramArguments': ['/usr/libexec/nanotimekitcompaniond', '-x']},
                '/x/com.apple.wifid.plist': {'Program': '/usr/sbin/wifid'},
            }}, f, fmt=plistlib.FMT_BINARY)
        gone = drop(root, DEFAULT.split())
        with open(path, 'rb') as f:
            left = plistlib.load(f)['LaunchDaemons']
        assert sorted(g[0] for g in gone) == ['nanotimekitcompaniond', 'wifip2pd'], gone
        assert list(left) == ['/x/com.apple.wifid.plist'], left
    print('root-tweaks-perf: self-test passed (host only)')


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    if sys.argv[1] == '--self-test':
        self_test()
        return
    names = os.environ.get('PERF_DROP_JOBS', DEFAULT).split()
    if not names:
        print('laurel perf: PERF_DROP_JOBS empty: no job removed')
        return
    drop(sys.argv[1], names)


if __name__ == '__main__':
    main()
