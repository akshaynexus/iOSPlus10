#!/bin/bash
# Stage libpthread-539.100.4 (the pair of xnu-12377.121.6 in Apple's macos-265 release.json) for the built-in SWEET provider.
# Same target as topaz 0019-stage-libpthread.sh (bsd/pthread/sweet_libpthread), so the series patches stay. Run from the xnu root.
set -euo pipefail
[[ "${MACHINE_CONFIG:-}" == SWEET ]] || exit 0
[[ -f bsd/pthread/pthread_shims.c ]] || exit 1
pthread_sha=1f4f5265b319111142f1bf3a27d4484ef5a98314
pthread_tmp=$(mktemp -d)
trap 'rm -rf "$pthread_tmp"' EXIT
git init -q "$pthread_tmp"
git -C "$pthread_tmp" fetch -q --depth 1 https://github.com/apple-oss-distributions/libpthread "$pthread_sha"
git -C "$pthread_tmp" checkout -q FETCH_HEAD
[[ "$(git -C "$pthread_tmp" rev-parse HEAD)" == "$pthread_sha" ]]
python3 - "$pthread_tmp" <<'PY'
from pathlib import Path
import shutil, sys
source = Path(sys.argv[1])
target = Path('bsd/pthread/sweet_libpthread')
if target.exists():
    raise SystemExit(f'refusing to overwrite existing provider: {target}')
for directory in ('kern', 'private', 'include'):
    shutil.copytree(source / directory, target / directory)
def replace(file, old, new, count):
    path = target / 'kern' / file
    text = path.read_text()
    if text.count(old) != count:
        raise SystemExit(f'libpthread source changed: {file}: {old!r} {text.count(old)}')
    path.write_text(text.replace(old, new))
# The kernel source has stricter address types than the kext SDK (same edits as UniXNU patches/libpthread).
replace('kern_trace.h', 'vm_kernel_unslide_or_perm_external(ptr,', 'vm_kernel_unslide_or_perm_external((vm_offset_t)ptr,', 1)
for callback, count in (('psynch_wait_update_owner', 4), ('psynch_wait_complete', 1), ('psynch_wait_wakeup', 2)):
    replace('kern_synch.c', f'pthread_kern->{callback}(kwq,', f'pthread_kern->{callback}((uintptr_t)kwq,', count)
replace('kern_support.c', '*kevent_list_out = NULL;', '*kevent_list_out = 0;', 1)
replace('kern_support.c', 'user_addr_t kevent_list = NULL;', 'user_addr_t kevent_list = 0;', 2)
replace('kern_support.c', 'workq_kevent(p, &th_addrs, NULL,', 'workq_kevent(p, &th_addrs, 0,', 1)
PY
cp "$(xcrun --sdk macosx --show-sdk-path)/usr/include/TargetConditionals.h" bsd/pthread/sweet_libpthread/
echo "Staged libpthread-539.100.4 ($pthread_sha) for SWEET"
