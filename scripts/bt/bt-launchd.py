#!/usr/bin/env python3
"""Edit an iOS 16 launchd job cache (System/Library/xpc/launchd.plist) for Bluetooth (docs/bluetooth-plan.md 4).

    bt-launchd.py CACHE on  BLUETOOTHD_PLIST [STUB_PATH]   enable
    bt-launchd.py CACHE off                                back to the default root (bluetoothd job removed,
                                                           BlueTool job = /usr/sbin/BlueTool -R)
    bt-launchd.py CACHE status

launchd on this port reads jobs only from the cache (docs/usb-network.md); the key of a job is the path of its
plist in /System/Library/LaunchDaemons. "on":
  1. com.apple.bluetoothd: the job from BLUETOOTHD_PLIST (the stock /System/Library/LaunchDaemons file; the
     20H392 launchd cache of this port has no bluetoothd job at all, only BlueTool, bluetoothuiservice and
     bluetoothuserd, so "on" adds it) + EnvironmentVariables
     BT_HCI_TRANSPORT=H4BC:POSIX:com.apple.uart.bluetooth,3000000 (bluetoothd 0x100156160: transport H4BC,
     driver POSIX, device string = kernel control name + ",baud"; the default name com.apple.uart.sk.bluetooth
     needs Skywalk, which our kernel does not have) and BT_BAUDRATE=3000000.
  2. com.apple.BlueTool: ProgramArguments [STUB_PATH] (default /usr/libexec/negroni-bluetool, userland/bluetooth):
     the stock BlueTool boots Broadcom chips only.
Without negronibt=4 and the ADT node /arm-io/bluetooth, bluetoothd finds no device and exits 0 once
("No bluetooth on this device"; KeepAlive SuccessfulExit=false: no restart), so "on" is harmless on other boots.
Works on macOS and Linux (python3 plistlib; the key has dots, which plutil key paths cannot hold).
"""
import os, plistlib, sys

BTD_KEY = '/System/Library/LaunchDaemons/com.apple.bluetoothd.plist'
BT_KEY = '/System/Library/LaunchDaemons/com.apple.BlueTool.plist'
ENV = {'BT_HCI_TRANSPORT': 'H4BC:POSIX:com.apple.uart.bluetooth,3000000', 'BT_BAUDRATE': '3000000'}
STOCK_BLUETOOL = ['/usr/sbin/BlueTool', '-R']
STUB = '/usr/libexec/negroni-bluetool'


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    path, op = sys.argv[1], sys.argv[2]
    st = os.stat(path)
    data = plistlib.load(open(path, 'rb'))
    jobs = data['LaunchDaemons']
    bt = jobs.get(BT_KEY)
    if op == 'status':
        b = jobs.get(BTD_KEY)
        print('bluetoothd job:', 'absent' if b is None else 'present, env ' + repr(b.get('EnvironmentVariables', {})))
        print('BlueTool job:', 'absent' if bt is None else bt.get('ProgramArguments'))
        return
    if op == 'on':
        if len(sys.argv) < 4:
            sys.exit('on needs BLUETOOTHD_PLIST')
        stub = sys.argv[4] if len(sys.argv) > 4 else STUB
        job = jobs.get(BTD_KEY) or plistlib.load(open(sys.argv[3], 'rb'))
        job.setdefault('EnvironmentVariables', {}).update(ENV)
        jobs[BTD_KEY] = job
        if bt is not None:
            bt['ProgramArguments'] = [stub]
            bt.pop('Program', None)
        print('bt-launchd: bluetoothd job on with', ENV, '; BlueTool job ->', stub if bt is not None else '(no job!)')
    elif op == 'off':
        jobs.pop(BTD_KEY, None)
        if bt is not None:
            bt['ProgramArguments'] = list(STOCK_BLUETOOL)
        print('bt-launchd: bluetoothd job removed; BlueTool job = /usr/sbin/BlueTool -R')
    else:
        sys.exit(__doc__)
    with open(path, 'wb') as f:
        plistlib.dump(data, f, fmt=plistlib.FMT_BINARY)
    try:
        os.chown(path, st.st_uid, st.st_gid)
    except PermissionError:
        pass
    os.chmod(path, st.st_mode & 0o7777)


if __name__ == '__main__':
    main()
