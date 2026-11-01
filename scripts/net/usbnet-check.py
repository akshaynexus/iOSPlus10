#!/usr/bin/env python3
"""Check a root after root-add-ssh.py: USB must not take Wi-Fi's default route or DNS; SSH works with the repo key.
  usbnet-check.py ROOT PHONE_KEY.pub      (scripts/laurel/root-dry-run.sh; docs/usb-network.md "ue0 and Wi-Fi")"""
import os, plistlib, sys

r, pub = sys.argv[1], sys.argv[2]
SVC = '1F05B0E7-0000-4000-8000-0000000000E0'
JOBS = '/System/Library/LaunchDaemons/dev.iosplus10.'
with open(r + '/private/var/preferences/SystemConfiguration/preferences.plist', 'rb') as f:
    svc = plistlib.load(f)['NetworkServices'][SVC]
with open(r + '/System/Library/xpc/launchd.plist', 'rb') as f:
    jobs = plistlib.load(f)['LaunchDaemons']
fail = []
if 'Router' in svc['IPv4'] or 'DNS' in svc:
    fail.append('the USB service has a router or DNS')
if svc.get('PrimaryRank') != 'Last':
    fail.append('the USB service is not rank Last')
if JOBS + 'usbnetcfg.plist' in jobs:
    fail.append('usbnetcfg runs at boot')
if JOBS + 'laurelnet.plist' not in jobs:
    fail.append('no laurelnet job')
if not os.access(r + '/usr/local/bin/laurelnet', os.X_OK):
    fail.append('no laurelnet binary')
with open(r + '/private/var/root/.ssh/authorized_keys') as f:
    keys = f.read()
with open(pub) as f:
    if f.read().strip() not in keys:
        fail.append('the repo key is not in authorized_keys')
if '-s' not in jobs[JOBS + 'dropbear.plist']['ProgramArguments']:
    fail.append('dropbear still takes passwords (-s absent)')
print('root-dry-run: USB network + SSH login', 'PASS' if not fail else 'FAIL: ' + '; '.join(fail))
sys.exit(1 if fail else 0)
