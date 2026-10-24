#!/usr/bin/env python3
"""Read a value from config/negroni-ne2211.toml for shell scripts.

    conf.py SECTION.KEY          -> value (lists joined by spaces)
"""
import sys, tomllib
from pathlib import Path

cfg = tomllib.loads((Path(__file__).resolve().parents[1] / 'config/negroni-ne2211.toml').read_text())
v = cfg
for k in sys.argv[1].split('.'):
    v = v[k]
print(' '.join(map(str, v)) if isinstance(v, list) else v)
