#!/bin/sh
# Fetch the reference-only repos into external/ (they are not submodules; the build does not read them).
# Usage: get-references.sh            fetch every missing repo
#        get-references.sh NAME...    fetch the named repos
#        get-references.sh -l         list the table and the on-disk state
# A directory that already exists is never changed. REF_DIR=... puts the clones in another folder.
# Each fetch is a shallow fetch of the pinned commit; if the server refuses it, a full fetch of the branch.
set -eu
. "$(dirname "$0")/../lib/env.sh"
DEST=${REF_DIR:-$EXT}

# NAME URL COMMIT [BRANCH]
TABLE='
UniXNU-negroni     https://github.com/pawlickerr/UniXNU-negroni.git   f812002ae3e6b861d23007efdfd9f1c394934ba9 dev
ios-sweet          https://github.com/akshaynexus/ios-sweet.git       45263bee51df4a0f55cdf9c649af886399488ddb main
ios-sweet-upstream https://github.com/dipa-studio/ios-sweet.git       45263bee51df4a0f55cdf9c649af886399488ddb main
UniXNU-ios26       https://github.com/none24smu/UniXNU.git            68c513467bb6c44106c053c410582c1d14f96dd7 ios26
UniXNU-zeta        https://github.com/none24smu/UniXNU-zeta.git       318b2ea45bca77ca6b7a91c00c87efc8a44597e1 main
UniXNU-pong        https://github.com/Chengdong-Yu/UniXNU-pong.git    ab74f075320fe54eee24d5d150386e5b0f0f427f main
ios-sailfish       https://github.com/joranv1/ios-sailfish.git        6f27e41ff249f2680540ebe8ee5ab982c5e641c9
bergamota          https://github.com/ry-diffusion/bergamota.git      0826e48c3d3f4bd9b0ab7d5af82ed92dfaeec425 develop
hackios-xnu-kernel https://github.com/oosexgang/hackios-xnu-kernel.git d82c64a3a31cd27a0a0afbf6e213e467e44b1b4c main
ios-apollo         https://github.com/aTechGeekDev/ios-apollo.git     1c1a199c4f2fcf3484a58a5e8248caffdf14e45e main
ios-s9             https://github.com/syncmodz/ios-s9.git             7b72f7c0db34fc396498d71bb7e1af90d6f899f3
Chlorophyll        https://github.com/ry-diffusion/Chlorophyll.git    787338fc7c297f54e2000bca02f4fa36f1154c5a
ios-spes           https://github.com/AdyaGMD/ios-spes.git            2cd45c4fb30c9edd3ebc45321d41fce24ad8e0ab spes
owl                https://github.com/seemoo-lab/owl.git              0ee3263f944ea721c355f826aa90d636d012a512 master
opendrop           https://github.com/seemoo-lab/opendrop.git         11fe7ba7861093b302bc0637e8cb10adf2d29337 master
ios-topaz          https://github.com/MakrSas/ios-topaz.git           e4772911e116ab4ab6c4ac1f38e6106fefe8b483 topaz
Mu-Silicium        https://github.com/Project-Silicium/Mu-Silicium.git 4bd8ae83bf37de41777f19e0777db70f59383a6d main
laurel-kernel-oss  https://github.com/MiCode/Xiaomi_Kernel_OpenSource.git d3766fc8cda2d96de2850faa9ce58e5a37ea9f9c laurel-r-oss
laurel-kernel-los  https://github.com/LineageOS/android_kernel_xiaomi_sm6125.git 8aaa002bfb7ba1cac2c02dbb42ae0259ef2e47ba lineage-24.0
laurel-device-los  https://github.com/LineageOS/android_device_xiaomi_laurel_sprout.git d389daebe22c2713b09742ab7153535c421ebdeb lineage-24.0
sm6125-common-los  https://github.com/LineageOS/android_device_xiaomi_sm6125-common.git 0e2b2bbfbc218d73a1f9fc17cfb3d82401f06ad9 lineage-24.0
ios-sweet-linux    https://github.com/myh120405/ios-sweet-linux.git   8d09cf0d6748e40845dd413e9157e465024252ab main
xnu-linux-toolchain https://github.com/Allenwdk/xnu-linux-toolchain.git 909990e4ec2c6cda30c20cdb23219946918c7fd6 main
hackios-umi        https://github.com/ls9875/hackios-umi.git          6ac5eee39b076faf5c33ee14a9b17558779ee0b4 main
hackios-scion      https://github.com/Scion-Project/hackios-xnu-kernel.git e407d1e75a8d79b1cf5975e9abe52f23a71106f2 main
laurel-mainline    https://github.com/laurel-sprout-mainline/laurel_sprout_mainline.git 2cb8fd07918d6dd07180796da5b75cb491400df9 mainline-6.18-split
'

rows() { printf '%s\n' "$TABLE" | sed '/^[[:space:]]*$/d'; }

list() {
  printf '%-19s %-8s %-8s %s\n' NAME STATE PIN HEAD
  rows | while read -r name url commit branch; do
    d=$DEST/$name
    if [ -e "$d" ]; then
      head=$(git -C "$d" rev-parse HEAD 2>/dev/null || echo '?')
      [ "$head" = "$commit" ] && pin=match || pin=differs
      printf '%-19s %-8s %-8s %s\n' "$name" present "$pin" "$head"
    else
      printf '%-19s %-8s %-8s %s\n' "$name" absent - "(pin $commit${branch:+, branch $branch})"
    fi
  done
}

fetch() { # NAME URL COMMIT [BRANCH]
  name=$1 url=$2 commit=$3 branch=${4:-}
  d=$DEST/$name
  if [ -e "$d" ]; then echo "$name: $d exists, not changed"; return 0; fi
  tmp=$d.partial
  rm -rf "$tmp"
  mkdir -p "$tmp"
  git -C "$tmp" init -q
  git -C "$tmp" remote add origin "$url"
  echo "$name: fetching $commit from $url"
  if git -C "$tmp" fetch -q --depth 1 origin "$commit"; then
    git -C "$tmp" checkout -q --detach FETCH_HEAD
  else
    echo "$name: commit fetch refused, full fetch of ${branch:-the default branch}"
    git -C "$tmp" fetch -q origin ${branch:+"$branch"}
    git -C "$tmp" checkout -q --detach "$commit"
  fi
  head=$(git -C "$tmp" rev-parse HEAD)
  if [ "$head" != "$commit" ]; then echo "$name: HEAD $head is not the pin $commit" >&2; return 1; fi
  mv "$tmp" "$d"
  echo "$name: $d at $commit"
}

if [ "${1:-}" = -l ]; then list; exit 0; fi
mkdir -p "$DEST"
fail=0
if [ $# -eq 0 ]; then
  while read -r name url commit branch; do
    fetch "$name" "$url" "$commit" "$branch" </dev/null || fail=1
  done <<ROWS
$(rows)
ROWS
else
  for want in "$@"; do
    row=$(rows | awk -v n="$want" '$1 == n')
    if [ -z "$row" ]; then echo "$want: not in the table (see -l)" >&2; fail=1; continue; fi
    # shellcheck disable=SC2086
    fetch $row || fail=1
  done
fi
exit $fail
