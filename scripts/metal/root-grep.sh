#!/bin/bash
# Look for file names / strings in the iOS 16 root image without a mount (the root is an Android sparse image,
# ~/op10-apple/ios16-root.simg; APFS directory records keep names uncompressed). Prints byte offsets + matches.
#   scripts/metal/root-grep.sh 'MTLCompilerService[A-Za-z0-9._/-]*' [IMAGE]
# Run in tmux (11 GB read): scripts/bg.sh root-grep scripts/metal/root-grep.sh PATTERN
set -euo pipefail
pat=${1:?pattern (extended regex)}
img=${2:-$HOME/op10-apple/ios16-root.simg}
[ -f "$img" ] || { echo "no image $img" >&2; exit 1; }
LC_ALL=C grep -a -o -b -E "$pat" "$img" | sort -t: -k2 | uniq -c -f0 | head -400
