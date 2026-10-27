#!/usr/bin/env python3
"""Print the symbolicated user stacks of a stackshot report (.ips, bug_type 509, "variant": "stackshot").

FrontBoard writes one when an app does not exit in time (e.g. /var/mobile/Library/Logs/CrashReporter/
Camera-*.ips); it holds every process's threads, so a hang shows who waits on whom ("waitInfo",
"turnstileInfo"). Frames in the dyld shared cache are symbolicated with ipsw against the extracted 20H392
cache; other images are printed as UUID + offset.

  python3 -I scripts/debug/ips-stackshot.py REPORT.ips PROC[,PROC...] [THREAD-ID|QUEUE-LABEL-PART]
  e.g. python3 -I scripts/debug/ips-stackshot.py logs/Camera-2026-10-27-051639.ips Camera
Env: DSC (default out/dsc/cache/dyld_shared_cache_arm64), A2S (default out/dsc/20H392.a2s, ipsw's symbol cache).
Read only. macOS and Linux (needs ipsw: scripts/setup/native-tools.sh). docs/camera-ios-2026-10-27.md section 8.
"""
import functools
import json
import os
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DSC = os.environ.get('DSC', os.path.join(REPO, 'out/dsc/cache/dyld_shared_cache_arm64'))
A2S = os.environ.get('A2S', os.path.join(REPO, 'out/dsc/20H392.a2s'))
CACHE_BASE = 0x180000000   # unslid base of the arm64 cache (the report gives offsets from the slid base)


@functools.lru_cache(maxsize=None)
def sym(addr):
    cmd = ['ipsw', 'dyld', 'a2s', DSC, hex(addr), '-i']
    if os.path.exists(A2S):
        cmd += ['--cache', A2S]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=120).stdout
    except (OSError, subprocess.TimeoutExpired) as e:   # no ipsw, or it hangs: print the raw address
        return '%s (no symbol: %s)' % (hex(addr), e.__class__.__name__)
    lines = [x.strip() for x in out.splitlines() if x.strip()]
    # ipsw -i: "IMAGE | ----- | > /path (__TEXT.__text) | 0xaddr: symbol + off"
    text = lines[-1] if lines else hex(addr)
    return text.split('| > ')[-1]


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    with open(sys.argv[1]) as f:
        f.readline()                     # the one-line JSON header
        report = json.load(f)
    procs = sys.argv[2].split(',')
    only = sys.argv[3] if len(sys.argv) > 3 else None
    shot = report['stackshot']
    images = shot['binaryImages']        # [uuid, load address, kind]; kind 'S' = the shared cache
    print('report', report.get('captureTime'), report.get('procName'), 'termination:',
          json.dumps(report.get('termination', {}).get('details', []))[:300])
    for pid, p in shot['processByPid'].items():
        if p.get('procname') not in procs:
            continue
        print('=== pid %s %s' % (pid, p.get('procname')))
        for w in p.get('waitInfo', []):
            print('  wait:', w)
        for w in p.get('turnstileInfo', []):
            print('  turnstile:', w)
        for tid, t in p.get('threadById', {}).items():
            label = t.get('dispatch_queue_label', '')
            if only and only != tid and only not in label:
                continue
            print('-- thread %s %s %s %s' % (tid, t.get('name', ''), label, ','.join(t.get('state', []))))
            for index, offset in t.get('userFrames', []):
                if not 0 <= index < len(images) or len(images[index]) < 3:
                    print('    image %d (not in binaryImages) +%#x' % (index, offset))
                    continue
                uuid, _, kind = images[index][:3]
                if kind == 'S':
                    print('    ' + sym(CACHE_BASE + offset))
                else:
                    print('    image %d %s (%s) +%#x' % (index, uuid, kind, offset))


if __name__ == '__main__':
    main()
