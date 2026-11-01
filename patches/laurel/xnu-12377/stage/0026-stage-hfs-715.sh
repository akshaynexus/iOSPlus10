#!/bin/bash
# Stage hfs-715.120.4 (the pair of xnu-12377.121.6 in Apple's macos-265 release.json) for the built-in SWEET file system.
# Same target as topaz 0026-stage-hfs.sh (bsd/sweet_hfs), so the series patches stay. Run from the xnu root.
set -euo pipefail
[[ "${MACHINE_CONFIG:-}" == SWEET ]] || exit 0
[[ -f bsd/kern/bsd_init.c ]] || exit 1
hfs_sha=124b970fd5390f1c2cd6f985478616a04f6eeb1f
hfs_tmp=$(mktemp -d)
trap 'rm -rf "$hfs_tmp"' EXIT
git init -q "$hfs_tmp"
git -C "$hfs_tmp" fetch -q --depth 1 https://github.com/apple-oss-distributions/hfs "$hfs_sha"
git -C "$hfs_tmp" checkout -q FETCH_HEAD
[[ "$(git -C "$hfs_tmp" rev-parse HEAD)" == "$hfs_sha" ]]
python3 - "$hfs_tmp" <<'PY'
from pathlib import Path
import shutil, sys
source = Path(sys.argv[1])
target = Path('bsd/sweet_hfs')
if target.exists():
    raise SystemExit(f'refusing to overwrite existing HFS sources: {target}')
for directory in ('core', 'hfs_encodings'):
    shutil.copytree(source / directory, target / directory)
# SWEET has no AppleKeyStore (content protection is not built); its header is only needed for the key-wrapping API.
path = target / 'core' / 'hfs_iokit.h'
text = path.read_text()
include = '#include <AppleKeyStore/AppleKeyStoreFSServices.h>\n'
first = 'int hfs_unwrap_key('
end = '__END_DECLS'
if text.count(include) != 1 or text.count(first) != 1 or text.count(end) != 1:
    raise SystemExit(f'HFS source changed: {path}')
text = text.replace(include, '#if CONFIG_PROTECT\n' + include + '#endif\n')
i, j = text.index(first), text.index(end)
text = text[:i] + '#if CONFIG_PROTECT\n' + text[i:j].rstrip('\n') + '\n#endif\n\n' + text[j:]
path.write_text(text)
PY
cp "$(xcrun --sdk macosx --show-sdk-path)/usr/include/TargetConditionals.h" bsd/sweet_hfs/
echo "Staged hfs-715.120.4 ($hfs_sha) for SWEET"
