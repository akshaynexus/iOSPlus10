#!/bin/sh
# Compare our pins of the GPU/Metal upstreams with their current branch heads (read-only, nothing is changed in external/).
#   scripts/bg.sh gpuopt-upstream scripts/setup/upstream-check.sh          all rows (network: always in tmux)
#   scripts/setup/upstream-check.sh NAME...                                 the named rows
# Per row: a blob-less clone in out/upstream/NAME (trees and commits only; blobs come on demand), then
#   out/upstream/NAME.log      `git log --name-status PIN..HEAD` limited to the row's paths
#   out/upstream/NAME.head     the branch head (the new pin candidate)
# and one summary line. The table pins must equal .gitmodules / get-references.sh / scripts/*/env.sh; change them together.
set -eu
. "$(dirname "$0")/../lib/env.sh"
U=$OUT/upstream
mkdir -p "$U"

# NAME URL PIN BRANCH PATHS (PATHS: space-separated pathspecs inside quotes-free list joined by ',' ; '.' = everything)
TABLE='
hackios-xnu-kernel  https://github.com/oosexgang/hakios-xnu-kernel.git      d82c64a3a31cd27a0a0afbf6e213e467e44b1b4c main userland,tools,docs,xnu,patches,README.md
hackios-xnu-userland https://github.com/oosexgang/hackios-xnu-userland.git  a79ff0772a3454fd1ef127e181e5b3bce6c9ce18 main .
metal2vulkan        https://github.com/steelbrain/metal2vulkan.git          f6a96b7da82f3032e3fd7b1dc52c07bfd9b78dc8 master crates,CHANGELOG.md,README.md
ios-flame           https://github.com/NWylynko/ios-flame.git               745c4341af86089efb0df851fa8a27fb8face624 main phone,tools,xnu,HANDOFF.md,METAL-NEXT.md,README.md
ios-topaz           https://github.com/MakrSas/ios-topaz.git                e4772911e116ab4ab6c4ac1f38e6106fefe8b483 topaz xnu,userland,README.md
hackios-scion       https://github.com/Scion-Project/hackios-xnu-kernel.git e407d1e75a8d79b1cf5975e9abe52f23a71106f2 main userland,tools,xnu,docs,README.md
hackios-umi         https://github.com/ls9875/hackios-umi.git               6ac5eee39b076faf5c33ee14a9b17558779ee0b4 main .
ios-redfin          https://github.com/DenialOfGravity/ios-redfin.git       0c4433cf0060e5f0cd8947e558841c113bbad4db main .
'

check() { # NAME URL PIN BRANCH PATHS
  name=$1 url=$2 pin=$3 branch=$4 paths=$5
  d=$U/$name
  if [ ! -d "$d/.git" ]; then
    rm -rf "$d"
    git init -q "$d"
    git -C "$d" remote add origin "$url"
  fi
  git -C "$d" fetch -q --filter=blob:none origin "+refs/heads/$branch:refs/remotes/origin/$branch" || { echo "$name: fetch failed"; return 1; }
  head=$(git -C "$d" rev-parse "origin/$branch")
  echo "$head" > "$U/$name.head"
  if ! git -C "$d" cat-file -e "$pin^{commit}" 2>/dev/null; then
    echo "$name: pin ${pin%"${pin#???????}"} not in $branch (history rewritten?), head ${head%"${head#???????}"}"
    git -C "$d" log --oneline -50 "origin/$branch" > "$U/$name.log"
    return 0
  fi
  # shellcheck disable=SC2086
  set -- $(printf '%s' "$paths" | tr ',' ' ')
  git -C "$d" log --date=short --format='--- %h %ad %s' --name-status "$pin..origin/$branch" -- "$@" > "$U/$name.log"
  n=$(git -C "$d" rev-list --count "$pin..origin/$branch")
  m=$(grep -c '^--- ' "$U/$name.log" || true)
  echo "$name: pin ${pin%"${pin#???????}"} -> head ${head%"${head#???????}"} ($(git -C "$d" log -1 --date=short --format=%ad "origin/$branch")): $n commits, $m touch $paths"
}

rows() { printf '%s\n' "$TABLE" | sed '/^[[:space:]]*$/d'; }
want=" $* "
rc=0
rows | while read -r name url pin branch paths; do
  [ $# = 0 ] || case "$want" in *" $name "*) ;; *) continue ;; esac
  check "$name" "$url" "$pin" "$branch" "$paths" || rc=1
done

# Mesa: the newest release on archive.mesa3d.org next to our 25.0.7 pin (scripts/gpu/env.sh, scripts/laurel/gpu-env.sh)
if [ $# = 0 ] || case "$want" in *" mesa "*) true ;; *) false ;; esac; then
  curl -fsSL --retry 3 https://archive.mesa3d.org/ > "$U/mesa-index.html" &&
    latest=$(grep -oE 'mesa-[0-9]+\.[0-9]+\.[0-9]+\.tar\.xz' "$U/mesa-index.html" | sed 's/mesa-//; s/\.tar\.xz//' | sort -uV | tail -1) &&
    echo "mesa: pin 25.0.7 -> newest release $latest" || echo "mesa: archive index not readable"
fi
exit $rc
