#!/usr/bin/env python3
"""celld-job.py ROOT [on|off]: the launchd job of /usr/local/libexec/laurel-celld in a mounted Mi A3 iOS 16 root.

launchd on this port reads jobs only from its cache, System/Library/xpc/launchd.plist (docs/usb-network.md); the key is the path of the job's plist. The daemon runs
as root for the whole boot: it publishes the cellular data session to configd (docs/laurel_sprout/cellular.md section 11). Idempotent. macOS and Linux.
"""
import os
import plistlib
import sys

LABEL = "com.laurel.celld"
KEY = f"/System/Library/LaunchDaemons/{LABEL}.plist"
JOB = {
    "Label": LABEL,
    "ProgramArguments": ["/usr/local/libexec/laurel-celld"],
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
    root, op = sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else "on"
    cache = os.path.join(root, "System/Library/xpc/launchd.plist")
    with open(cache, "rb") as f:
        data = plistlib.load(f)
    jobs = data["LaunchDaemons"]
    if op == "on":
        jobs[KEY] = JOB
    elif op == "off":
        jobs.pop(KEY, None)
    else:
        sys.exit(__doc__)
    st = os.stat(cache)
    tmp = cache + ".new"
    with open(tmp, "wb") as f:
        plistlib.dump(data, f, fmt=plistlib.FMT_BINARY)
    os.chmod(tmp, st.st_mode)
    if os.geteuid() == 0:
        os.chown(tmp, st.st_uid, st.st_gid)
    os.replace(tmp, cache)
    print(f"celld-job: {LABEL} {op}")


if __name__ == "__main__":
    main()
