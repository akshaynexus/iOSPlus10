#!/usr/bin/env python3
"""Mock of the Mi A3 camera commands (kernel patch 2771, laurel_cam_ctl.c) for the host test of op10tool camframe.

  python3 -I tools/laurel-cam-test/mock_phone.py FRAME.raw10 [PORT] [DROP]

UDP on 127.0.0.1:PORT (default 5141): camframe -> "ok camframe ...", the generation goes up after 0.5 s;
caminfo -> the same key/value line as the kernel; camread G O -> "LCF1" header + 1400 bytes. DROP = the share of
camread requests that get no answer (default 0.05), so the resend path of op10tool runs. Exits after 60 s.
"""
import random
import socket
import struct
import sys
import time

frame = open(sys.argv[1], "rb").read()
port = int(sys.argv[2]) if len(sys.argv) > 2 else 5141
drop = float(sys.argv[3]) if len(sys.argv) > 3 else 0.05
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(("127.0.0.1", port))
s.settimeout(0.1)
gen, ready_at, end = 1, 0.0, time.time() + 60
random.seed(7)
while time.time() < end:
    try:
        data, peer = s.recvfrom(64)
    except socket.timeout:
        continue
    cmd = data.decode().strip()
    busy = time.time() < ready_at
    if cmd == "camframe":
        s.sendto(b"ok camframe: capture started (kept frame gen %d goes away; poll caminfo)" % gen, peer)
        gen += 1
        ready_at = time.time() + 0.5
    elif cmd == "caminfo":
        s.sendto(("caminfo gen %d state %s w 1280 h 720 stride 1600 bytes %d bits 10 bayer RGGB frame 140 fps 93.5 "
                  "mean 230 exposure 732 gain 4096 runs %d" % (gen, "busy" if busy else "ready", len(frame), gen)).encode(), peer)
    elif cmd.startswith("camread "):
        g, o = (int(v) for v in cmd.split()[1:3])
        if busy or g != gen or o >= len(frame):
            s.sendto(b"error: no such frame part (kept generation %d, %d bytes)" % (gen, len(frame)), peer)
        elif random.random() >= drop:
            n = min(1400, len(frame) - o)
            s.sendto(b"LCF1" + struct.pack("<III", g, o, n) + frame[o:o + n], peer)
    else:
        s.sendto(b"error: unknown command", peer)
