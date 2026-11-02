#!/usr/bin/env python3
"""dual-boot-test.sh: write bytes into a fake partition or image: FILE OFFSET HEX."""
import sys
with open(sys.argv[1], 'r+b') as f:
    f.seek(int(sys.argv[2]))
    f.write(bytes.fromhex(sys.argv[3]))
