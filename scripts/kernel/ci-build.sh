#!/bin/sh
# Build our kernel on GitHub Actions (public CI repo, Xcode 15 runner) and download it.
#   scripts/kernel/ci-build.sh          (run in tmux: make kernel-ci)
# 1. syncs ci/negroni-xnu/ + patches/xnu/*.patch + SLOP_SHA (the external/slop submodule commit)
#    into a clone of $CI_REPO (out/kernel/ci-repo), commits and pushes -> the workflow runs;
# 2. waits for that run, downloads the negroni-xnu-kernel artifact to out/kernel/<run>/;
# 3. points out/kernel/kernel.macho at it and records the run in config (kernel.run/repo/...).
set -eu
. "$(dirname "$0")/../lib/env.sh"
CI_REPO=${CI_REPO:-akshaynexus/negroni-xnu}
C=$OUT/kernel/ci-repo
[ -d "$C/.git" ] || gh repo clone "$CI_REPO" "$C" -- -q
git -C "$C" pull -q --rebase || true
rsync -a --delete --exclude .git "$REPO/ci/negroni-xnu/" "$C/"
mkdir -p "$C/patches"
cp "$REPO"/patches/xnu/*.patch "$C/patches/" 2>/dev/null || true
git -C "$EXT/slop" rev-parse HEAD > "$C/SLOP_SHA"
git -C "$C" add -A
if git -C "$C" diff --cached --quiet; then
  echo "no changes; dispatching a rebuild"
  gh workflow run kernel.yml -R "$CI_REPO" --ref main
else
  git -C "$C" -c user.name="$(git -C "$REPO" config user.name)" -c user.email="$(git -C "$REPO" config user.email)" \
    commit -q -m "sync from iOSPlus10 $(git -C "$REPO" rev-parse --short HEAD)"
  git -C "$C" push -q origin HEAD:main
fi
head=$(git -C "$C" rev-parse HEAD)
echo "waiting for the run of $head ..."
run=""
while [ -z "$run" ]; do
  sleep 10
  run=$(gh run list -R "$CI_REPO" -w negroni-xnu -L 10 --json databaseId,headSha -q ".[] | select(.headSha==\"$head\") | .databaseId" | head -1)
done
echo "run $run: https://github.com/$CI_REPO/actions/runs/$run"
"$REPO/scripts/lib/notify.sh" "kernel CI run $run started"
gh run watch "$run" -R "$CI_REPO" --interval 60 --exit-status || st=$?
D=$OUT/kernel/$run
mkdir -p "$D"
gh run download "$run" -R "$CI_REPO" -n negroni-xnu-kernel -D "$D" || true
[ -f "$D/kernel.development.negroni" ] || { gh run download "$run" -R "$CI_REPO" -n build-log -D "$D" || true;
  "$REPO/scripts/lib/notify.sh" "kernel CI run $run FAILED"; echo "build failed: $D/build.log"; exit 1; }
ln -sf "$run/kernel.development.negroni" "$OUT/kernel/kernel.macho"
grep -c "Skipping patch" "$D/patch-report.txt" 2>/dev/null | sed 's/^/skipped patches: /' || true
"$REPO/scripts/lib/notify.sh" "kernel CI run $run done: out/kernel/$run"
echo "kernel: $D/kernel.development.negroni (out/kernel/kernel.macho)"
