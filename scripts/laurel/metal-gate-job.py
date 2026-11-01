#!/usr/bin/env python3
"""metal-gate-job.py ROOT [on|off]: the launchd job of /usr/libexec/laurel-metal-gate in a mounted Mi A3 iOS 16 root.

launchd on this port reads jobs only from its cache, System/Library/xpc/launchd.plist (docs/usb-network.md); a job's key is the
path of its plist in /System/Library/LaunchDaemons, which is also written, for the record. The job runs once at boot as root, with
no KeepAlive. Why a job of its own: the backboardd wrapper runs as user mobile, and the gate must write /var/db/negronimetal and
the plug-in bundle, both root's (boot 2026-11-01 15:27, docs/laurel_sprout/metal.md 6.1). Idempotent. Works on macOS and Linux.
"""
import os
import plistlib
import sys

LABEL = "com.laurel.metal-gate"
KEY = f"/System/Library/LaunchDaemons/{LABEL}.plist"
JOB = {
    "Label": LABEL,
    "ProgramArguments": ["/usr/libexec/laurel-metal-gate"],
    "RunAtLoad": True,
    "KeepAlive": False,
    "UserName": "root",
    "POSIXSpawnType": "Adaptive",
    "EnablePressuredExit": False,
    "EnableTransactions": False,
}


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    root = sys.argv[1]
    op = sys.argv[2] if len(sys.argv) > 2 else "on"
    cache = os.path.join(root, "System/Library/xpc/launchd.plist")
    file = root + KEY
    st = os.stat(cache)
    with open(cache, "rb") as f:
        data = plistlib.load(f)
    if op == "on":
        data["LaunchDaemons"][KEY] = JOB
        with open(file, "wb") as f:
            plistlib.dump(JOB, f, fmt=plistlib.FMT_BINARY)
        os.chmod(file, 0o644)
        try:
            os.chown(file, 0, 0)
        except PermissionError:
            pass
    else:
        data["LaunchDaemons"].pop(KEY, None)
        if os.path.exists(file):
            os.remove(file)
    with open(cache, "wb") as f:
        plistlib.dump(data, f, fmt=plistlib.FMT_BINARY)
    try:
        os.chown(cache, st.st_uid, st.st_gid)
    except PermissionError:
        pass
    os.chmod(cache, st.st_mode & 0o7777)
    print(f"metal-gate-job: {LABEL} {op} in {os.path.relpath(cache, root)} ({len(data['LaunchDaemons'])} jobs)")


if __name__ == "__main__":
    main()
