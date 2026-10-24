#!/bin/sh
# Install the NuGet-type external dependencies of the Mu build without NuGet.exe/Mono.
#   scripts/uefi/fetch-extdeps.sh
# A .nupkg is a ZIP. stuart only checks <dir>/<name>_extdep/extdep_state.yaml for the version, then
# picks the host folder (e.g. Linux-x86-64, Linux-ARM-64). So: download the package from the same
# feed (NuGet v3 flat container) with curl, unpack the <name>/ folder, write the state file.
# Handled ext_dep files: every type: nuget yaml/json in the build scopes (today only mu_nasm).
set -eu
. "$(dirname "$0")/../lib/env.sh"
MU=$EXT/Mu-Silicium-negroni
"$REPO/scripts/lib/native-env.sh" python3 - "$MU" <<'EOF'
import json, os, pathlib, shutil, subprocess, sys, tempfile, zipfile
mu = pathlib.Path(sys.argv[1])
scopes = {'global', 'edk2-build', 'negroni', 'gcc_aarch64_linux'}      # DeviceBuild.py Scopes
for f in list(mu.rglob('*_ext_dep.yaml')) + list(mu.rglob('*_ext_dep.json')):
    if '/Build/' in str(f):
        continue
    text = f.read_text()
    try:
        d = json.loads(text)
    except ValueError:
        import yaml
        d = yaml.safe_load(text)
    if d.get('type') != 'nuget' or d.get('scope') not in scopes:
        continue
    name, ver, src = d['name'], d['version'], d['source']
    dest = f.parent / f'{name}_extdep'
    state = dest / 'extdep_state.yaml'
    if state.exists() and f'version: {ver}' in state.read_text():
        print(f'{name} {ver}: present'); continue
    base = src.rsplit('/v3/index.json', 1)[0] + '/v3/flat2'
    url = f'{base}/{name.lower()}/{ver.lower()}/{name.lower()}.{ver.lower()}.nupkg'
    with tempfile.TemporaryDirectory() as t:
        pkg = os.path.join(t, 'p.nupkg')
        subprocess.run(['curl', '-sfL', '--retry', '3', '-o', pkg, url], check=True)
        shutil.rmtree(dest, ignore_errors=True)
        with zipfile.ZipFile(pkg) as z:
            z.extractall(t)
        inner = pathlib.Path(t) / name
        shutil.copytree(inner if inner.is_dir() else t, dest)
    for p in dest.rglob('*'):
        if p.is_file() and '.' not in p.name:
            p.chmod(0o755)
    state.write_text(f'version: {ver}\n')
    print(f'{name} {ver}: installed from {url} -> {dest.relative_to(mu)}')
EOF
