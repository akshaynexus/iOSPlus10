#!/usr/bin/env python3
"""Host test of `op10tool input`: a fake command server on 127.0.0.1:5141 with the words of kernel patch 2983. Usage: input-test.py OP10TOOL"""
import re, socket, subprocess, sys, threading, time

op = sys.argv[1]
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(("127.0.0.1", 5141))
s.settimeout(0.2)
got, reply, stop = [], {"synth": b"synth on"}, []


def serve():
    while not stop:
        try:
            d, a = s.recvfrom(256)
        except socket.timeout:
            continue
        w = d.decode()
        got.append((time.time(), w))
        s.sendto(reply.get(w, b"ok"), a)


threading.Thread(target=serve, daemon=True).start()


def run(*a):
    return subprocess.run([op, "input", "--host", "127.0.0.1", *a], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=10)


assert run("check").returncode == 0
got.clear()
r = run("swipe", "100", "200", "300", "400", "160")
assert r.returncode == 0, r.stdout
words = [w for _, w in got]
assert words[0] == "touch 9 1 100 200" and words[-2] == "touch 9 1 300 400" and words[-1] == "touch 9 0 300 400", words
assert all(re.fullmatch(r"touch 9 [01] \d+ \d+", w) for w in words), words
span = got[-1][0] - got[0][0]
assert 0.15 <= span <= 0.5, span
got.clear()
assert run("key", "home", "20").returncode == 0
assert [w for _, w in got] == ["key 3 1", "key 3 0"], got
reply["synth"] = b"synth off"
assert run("check").returncode != 0
reply["touch 9 1 5 5"] = b"error: busy"
r = run("tap", "5", "5")
assert r.returncode != 0 and "busy" in r.stdout, r.stdout
stop.append(1)
s.close()
r = run("check")  # no server: an answer, not a hang
assert r.returncode != 0
print(f"input-test: ok; a 160 ms swipe took {span * 1000:.0f} ms, {len(words)} words")
