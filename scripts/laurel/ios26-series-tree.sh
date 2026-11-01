#!/bin/bash
# Make the two source trees of the Mi A3 iOS 26 kernel in out/laurel-kernel-ios26/src/:
#   shadow/  xnu-8796.141.3 + the topaz stage scripts (the 8796 pairs of libpthread, HFS, BearSSL); apply-series.py walks the
#            series on it, as the "before" and "after" of a three-way merge. Only an input: nothing of it is built.
#   xnu/     xnu-12377.121.6 + the series (scripts/ios26/apply-series.py with scripts/laurel/ios26-series.py). Report: series-report.txt.
#   --dev    one git commit per step in xnu/, conflict markers stay in the file (to write a base patch).
set -euo pipefail
. "$(dirname "$0")/../lib/env.sh"
. "$REPO/scripts/laurel/ios26-env.sh"
[ -d "$MACOS_SDK/usr/include" ] || { mkdir -p "$DEPS"; tar -xJf "$W/dl/MacOSX$SDK_VER.sdk.tar.xz" -C "$DEPS"; }
export XNU_SDK_PATH=$MACOS_SDK XNU_SDK_VERSION=$SDK_VER
S=$W/src
m=$W/cache/xnu.git
for tag in xnu-12377.121.6 xnu-8796.141.3; do
  git -C "$m" rev-parse -q --verify "refs/tags/$tag" >/dev/null 2>&1 || {
    git init -q --bare "$m"; git -C "$m" fetch -q --depth 1 https://github.com/apple-oss-distributions/xnu.git "refs/tags/$tag:refs/tags/$tag"; }
done
# the shadow base (with the 8796 stage scripts run once; they fetch three repos)
if [ ! -f "$S/shadow-base/.staged" ]; then
  rm -rf "$S/shadow-base"
  git -c advice.detachedHead=false clone -q --depth 1 --branch xnu-8796.141.3 "file://$m" "$S/shadow-base" 2>/dev/null
  for s in "$TOPAZ"/xnu/patches/*.sh; do (cd "$S/shadow-base" && MACHINE_CONFIG=SWEET MACOS_VERSION=13.5 bash "$s"); done
  git -C "$S/shadow-base" add -A
  git -C "$S/shadow-base" -c user.name=x -c user.email=x@x commit -q -m stage
  touch "$S/shadow-base/.staged"
fi
rm -rf "$S/shadow" "$S/xnu"
cp -a "$S/shadow-base" "$S/shadow"
git -c advice.detachedHead=false clone -q --depth 1 --branch xnu-12377.121.6 "file://$m" "$S/xnu" 2>/dev/null
got=$(git -C "$S/xnu" rev-parse HEAD); [ "$got" = ac9718fb1af618d5ce8678d0dc6e8a58f252216f ] || { echo "xnu tag is $got" >&2; exit 1; }
echo BUILD/ >> "$S/xnu/.git/info/exclude"
git -C "$S/xnu" config user.name x; git -C "$S/xnu" config user.email x@x; git -C "$S/xnu" config commit.gpgsign false
cd "$REPO"
arg=(); [ "${1:-}" = --dev ] && arg=(--dev --commit)
IOS26_SHADOW=$S/shadow python3 -I scripts/ios26/apply-series.py "$S/xnu" --profile scripts/laurel/ios26-series.py "${arg[@]}" > "$W/series-report.txt" 2>&1; rc=$?
tail -1 "$W/series-report.txt"
exit $rc
