#!/usr/bin/env python3
"""One line of a boot image's header, from `unpack_bootimg`: os version, patch level, command line.   usage: boot-menu-header.py IMG"""
import re, shutil, subprocess, sys, tempfile
d = tempfile.mkdtemp()
try:
    o = subprocess.run(["unpack_bootimg", "--boot_img", sys.argv[1], "--out", d], capture_output=True, text=True, check=True).stdout
finally:
    shutil.rmtree(d)
g = lambda k: (re.search(rf"^{k}: (.*)$", o, re.M) or [None, "?"])[1]
print(f"header {g('boot image header version')} os {g('os version')} patch {g('os patch level')} cmdline [{g('command line args')}]")
