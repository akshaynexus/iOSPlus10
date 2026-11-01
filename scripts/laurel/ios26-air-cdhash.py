#!/usr/bin/env python3
"""ios26-air-cdhash.py ROOT: one line per binary of ours for the root's trust list: "cdhash path". Read-only. Works on macOS and Linux."""
import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
s = importlib.util.spec_from_file_location('chk', os.path.join(HERE, 'ios26-injected-check.py'))
chk = importlib.util.module_from_spec(s)
s.loader.exec_module(chk)
for rel in ('usr/libexec/laurel-awdld', 'usr/libexec/laurel-airplay'):
    p = os.path.join(sys.argv[1], rel)
    if not os.path.exists(p):
        continue
    with open(p, 'rb') as f:
        data = f.read()
    _, cs = chk.parse(data)
    if cs is None:
        sys.exit(f'ios26-air-cdhash: {rel}: no signature')
    print(chk.code_directory(data, cs)[2], '/' + rel)
