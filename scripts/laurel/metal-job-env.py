#!/usr/bin/env python3
"""metal-job-env.py ROOT [on|off]: RB_COLOR_MODE=fixed in the launchd jobs of RenderBox's clients, in a mounted Mi A3 iOS 16 root.

RenderBox reads RB_COLOR_MODE once, in a C++ static at its first RB::ColorMode (RenderBox 0x1e68c91e8 [V 20H392]). The plug-in sets it when
it loads, at the first Metal device: too late. Boot 2026-11-01 18:43: chronod printed "RB_COLOR_MODE=fixed" and still made every widget
surface OSType '_RB4' (2 planes, 10-bit + alpha): the kernel's import by ID refuses it and -[EAGLContext attachImage:] answers "not done"
(36 lines). In the job's own environment it is there before any code runs: plain BGRA widgets. Cache file only: launchd on this port
reads jobs from System/Library/xpc/launchd.plist (docs/usb-network.md). Idempotent. Works on macOS and Linux.
"""
import os
import plistlib
import sys

JOBS = ["com.apple.chronod", "com.apple.SpringBoard"]
KEY = "RB_COLOR_MODE"


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    op = sys.argv[2] if len(sys.argv) > 2 else "on"
    cache = os.path.join(sys.argv[1], "System/Library/xpc/launchd.plist")
    st = os.stat(cache)
    with open(cache, "rb") as f:
        data = plistlib.load(f)
    done = []
    for name in JOBS:
        job = data["LaunchDaemons"].get("/System/Library/LaunchDaemons/%s.plist" % name)
        if job is None:
            continue
        env = job.setdefault("EnvironmentVariables", {})
        if op == "on":
            env[KEY] = "fixed"
        else:
            env.pop(KEY, None)
        done.append(name)
    with open(cache, "wb") as f:
        plistlib.dump(data, f, fmt=plistlib.FMT_BINARY)
    os.chown(cache, st.st_uid, st.st_gid)
    os.chmod(cache, st.st_mode & 0o7777)
    print("metal-job-env: %s=%s in %s" % (KEY, "fixed" if op == "on" else "(removed)", ", ".join(done) or "no job"))


main()
