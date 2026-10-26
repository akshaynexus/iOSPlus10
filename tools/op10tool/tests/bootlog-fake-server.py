#!/usr/bin/env python3
"""Fake negroni USB command server for `op10tool bootlog --host 127.0.0.1` (tools/op10tool/tests/bootlog-test.sh):
answers "bootlog" and "bootlog read A C" (patch 0367 protocol) from an area file on 127.0.0.1:5141 and drops
DROP percent of the data datagrams, so the host's resend path runs. Exits after IDLE s without a request."""
import random, socket, struct, sys

area = open(sys.argv[1], "rb").read()
drop = float(sys.argv[2]) if len(sys.argv) > 2 else 0.0
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(("127.0.0.1", 5141))
s.settimeout(5)
random.seed(1)
while True:
    try:
        data, peer = s.recvfrom(256)
    except socket.timeout:
        break
    cmd = data.decode().strip()
    if cmd == "bootlog":
        s.sendto(b"bootlog v1 area 58643726 blocks 9216 slots 8 slotblocks 1025 boot 8 slot 3 state running "
                 b"secs 1 hfsend 4194304 running 1", peer)
    elif cmd.startswith("bootlog read "):
        a, c = map(int, cmd.split()[2:4])
        for b in range(a, a + c):
            blk = area[b * 4096:(b + 1) * 4096].ljust(4096, b"\0")
            for off in range(0, 4096, 1024):
                if random.random() * 100 < drop:
                    continue
                s.sendto(b"NBLD" + struct.pack("<III", b, off, 1024) + blk[off:off + 1024], peer)
    else:
        s.sendto(b"error: unknown command", peer)
