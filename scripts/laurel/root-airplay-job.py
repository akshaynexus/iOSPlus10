#!/usr/bin/env python3
"""root-airplay-job.py ROOT on|off: the launchd job of /usr/libexec/laurel-airplay in a mounted Mi A3 iOS 16 root.
   root-airplay-job.py --self-test     host check on a made-up root.

launchd on this port reads jobs only from its cache, System/Library/xpc/launchd.plist (docs/usb-network.md); a job's key is the path of its
plist in /System/Library/LaunchDaemons, which is also written, for the record. Same form as metal-gate-job.py. The job runs once at boot, no
KeepAlive, so no restart loop. As root: /dev/console is root's [I: as the Metal gate]. Works on macOS and Linux.
"""
import os
import plistlib
import sys
import tempfile

LABEL = 'com.laurel.airplay'
KEY = f'/System/Library/LaunchDaemons/{LABEL}.plist'
JOB = {
    'Label': LABEL,
    'ProgramArguments': ['/usr/libexec/laurel-airplay'],
    'RunAtLoad': True,
    'KeepAlive': False,
    'UserName': 'root',
    'POSIXSpawnType': 'Adaptive',
    'EnablePressuredExit': False,
    'EnableTransactions': False,
}


def apply(root, op):
    cache = os.path.join(root, 'System/Library/xpc/launchd.plist')
    file = root + KEY
    st = os.stat(cache)
    with open(cache, 'rb') as f:
        data = plistlib.load(f)
    if op == 'on':
        data['LaunchDaemons'][KEY] = JOB
        with open(file, 'wb') as f:
            plistlib.dump(JOB, f, fmt=plistlib.FMT_BINARY)
        os.chmod(file, 0o644)
        if os.geteuid() == 0:
            os.chown(file, 0, 0)
    else:
        data['LaunchDaemons'].pop(KEY, None)
        if os.path.exists(file):
            os.remove(file)
    with open(cache, 'wb') as f:
        plistlib.dump(data, f, fmt=plistlib.FMT_BINARY)
    os.chmod(cache, st.st_mode & 0o7777)
    if os.geteuid() == 0:
        os.chown(cache, st.st_uid, st.st_gid)
    print(f'laurel airplay: job {LABEL} {op}')


def self_test():
    with tempfile.TemporaryDirectory() as root:
        os.makedirs(os.path.join(root, 'System/Library/xpc'))
        os.makedirs(os.path.join(root, 'System/Library/LaunchDaemons'))
        cache = os.path.join(root, 'System/Library/xpc/launchd.plist')
        with open(cache, 'wb') as f:
            plistlib.dump({'LaunchDaemons': {'/x/other.plist': {'Program': '/x'}}}, f, fmt=plistlib.FMT_BINARY)
        for _ in range(2):      # idempotent
            apply(root, 'on')
        with open(cache, 'rb') as f:
            jobs = plistlib.load(f)['LaunchDaemons']
        assert sorted(jobs) == [KEY, '/x/other.plist'] and jobs[KEY]['KeepAlive'] is False, jobs
        assert os.path.exists(root + KEY)
        apply(root, 'off')
        with open(cache, 'rb') as f:
            assert list(plistlib.load(f)['LaunchDaemons']) == ['/x/other.plist']
        assert not os.path.exists(root + KEY)
    print('root-airplay-job: self-test passed (host only)')


def main():
    if sys.argv[1:] == ['--self-test']:
        self_test()
    elif len(sys.argv) == 3 and sys.argv[2] in ('on', 'off'):
        apply(sys.argv[1], sys.argv[2])
    else:
        sys.exit(__doc__)


if __name__ == '__main__':
    main()
