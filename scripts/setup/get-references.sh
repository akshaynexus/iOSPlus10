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
# hackios-xnu-kernel: renamed upstream to oosexgang/hakios-xnu-kernel (GitHub redirects the old URL). Its main branch
# (a48d2b2, 2026-11-01) shares no history with d82c64a, and d82c64a has GPU work a48d2b2 lacks: keep d82c64a
# (docs/laurel_sprout/upstream-2026-11-01.md; scripts/setup/upstream-check.sh compares the heads).
# 2026-11-07 (docs/laurel_sprout/upstream-2026-11-07.md): the closest siblings of the Mi A3 (Cortex-A73/A53 = Kryo 2xx ARMv8.0,
# Adreno 610, the same GIC at 0x0f200000) and the SM6125 Linux work. Pins bumped above the same day: ios-spes (A610 Metal rounds
# 0156-0169), bergamota (Chlorophyll on Turnip, iOS 26 GPU, BT on iOS 18), UniXNU-pong, ios-s9, hackios-scion, ios-sweet-linux,
# Mu-Silicium (3 commits, none for laurel_sprout). A present directory stays at its old pin (-l says "differs").
# UniXNU-tb128fu: Lenovo TB128FU (SM6225, A73/A53, A610): iPadOS 17 home screen; SGIs never arrive on this GIC, IPIs are
#   software-pended SPIs 536..543; timer INTID 19; PAN off; A610 without GMU; UFS HS-G3 2 lanes. Problems (a), (b).
# ArmCpu-tb128fu: the CPU/GIC/timer component with armcpu-self-ipi, armcpu-spi-ipi(-base), armcpu-timer-intid. Problem (a).
# Adreno610-tb128fu: NativeAdreno for an A6XX without a GMU (ring, CP init, non-coherent table walks, stall snapshots). Problem (b).
# AdrenoMetal-tb128fu: the Metal plug-in tuned for the A610 (sysmem passes, no concurrent binning, padded-row aliasing). Problem (b).
# uefi-tb128fu: a Mu-only Mu-Silicium tree for SM6225 (no vendor DXEs: Divar silicon package, splash framebuffer). Problem (e).
# UniXNU-clover: Xiaomi Mi Pad 4 (SDM660 = Kryo 260, the Mi A3's CPU): 8-core SMP with IPIs, eMMC root, first present; 334 rounds
#   of notes (notes/development-log.md, power-bringup.md, gpu-bringup.md for the Adreno 512 rails). Problems (a), (d).
# uefi-clover: its Mu-Silicium overlay (SDM660 ConfigurationMapLib, ClockDxe patch, DTB split tools). Problem (e).
# ios-doha: Moto G8 Plus (SM6125, the Mi A3's SoC): ios-sweet + ios-a5xelte ARMv8.0/4K series, GICD ARE_NS before GICR (0402),
#   diagnostic shim (PSCI CPU_ON of 7 cores, SGI, timer 19). Up to the root wait on 2026-11-03. Problems (a), (c).
# ios-ginkgo: Redmi Note 8 (SM6125): probe-only; its hardware map (GIC, PSCI, SMCCC, TG16) cross-checks ours. Problem (c).
# UniXNU-gta4l: Galaxy Tab A7 (SM6115 Bengal, A73/A53, A610): docs/tb128fu-comparison.md, PMGR bridge, PAN off. Problem (c).
# topaz-woa: Windows on ARM for the SM6225 (A610 WDDM driver with zap/SMMU/ring/MDP scanout, RPM votes, ADSP audio, FT5452 touch,
#   Mu-Silicium patches, DSDT). Problems (b), (d), (e).
# ginkgo-mainline: mainline Linux 7.0 on the SM6125 (DRM/DSI, NT36672A, WCN3990, A610, PMI632 QG, docs/ with the bring-up). Problem (f).
# arctos-willow: postmarketOS 7.2 on the Redmi Note 8T (SM6125): DTS and driver patches (OSM cpufreq, A610 zap, WCN3990 BT UART,
#   ADSP sensors, IPA modem). Problem (f).
# Portsmith-iOS: the index of every UniXNU/HakiOS/ios-sweet device port (ports/catalog/unixnu-devices.toml, 265 records). Problem (c).
TABLE='
UniXNU-negroni     https://github.com/pawlickerr/UniXNU-negroni.git   f812002ae3e6b861d23007efdfd9f1c394934ba9 dev
ios-sweet          https://github.com/akshaynexus/ios-sweet.git       45263bee51df4a0f55cdf9c649af886399488ddb main
ios-sweet-upstream https://github.com/dipa-studio/ios-sweet.git       45263bee51df4a0f55cdf9c649af886399488ddb main
UniXNU-ios26       https://github.com/none24smu/UniXNU.git            68c513467bb6c44106c053c410582c1d14f96dd7 ios26
UniXNU-zeta        https://github.com/none24smu/UniXNU-zeta.git       eb489285a1d9153872f00c93ebb519a269b249b5 main
IOS-26-Hot         https://github.com/nithinyadavamaraboina-online/IOS-26-Hot.git d249939b9c36380afaee1a76cf167aeee8347475 master
hakios-dada        https://github.com/superboyyy/hakios-arm64e-dada.git f1ae906fcc43ba8f763663257724ba938fb820ab main
AdrenoMetal        https://github.com/UniXNU/AdrenoMetal.git e82788dd367753802ec2e00476ab27addfb46834 main
metal2vulkan-inferno https://github.com/MakrSas/metal2vulkan-inferno.git f9832cec3fe55d28069e3c8aa4bd307a7c0296c9
Bergamota          https://github.com/friendlycatt/Bergamota.git 23475744ca5cc6790037c8ebcf4b03662a24d922 develop
UniXNU-pong        https://github.com/Chengdong-Yu/UniXNU-pong.git    e0ee6df109b4b5dc706cac660d4f8210dc911dac main
ios-sailfish       https://github.com/joranv1/ios-sailfish.git        6f27e41ff249f2680540ebe8ee5ab982c5e641c9
bergamota          https://github.com/ry-diffusion/bergamota.git      37a7a7a917fc09945ed2f7d1ae68b84d4525b4cb develop
hackios-xnu-kernel https://github.com/oosexgang/hackios-xnu-kernel.git d82c64a3a31cd27a0a0afbf6e213e467e44b1b4c main
hakios-main        https://github.com/oosexgang/hakios-xnu-kernel.git  63fc2b4633bac3af8e57dadab9f5a8d4cb940438 main
ios-apollo         https://github.com/aTechGeekDev/ios-apollo.git     1f75f381e31da96de537653fbac2252d2eb80418 main
ios-s9             https://github.com/syncmodz/ios-s9.git             646570b679b8d9147557f993ebc3ae9500ab9cfd
Chlorophyll        https://github.com/ry-diffusion/Chlorophyll.git    787338fc7c297f54e2000bca02f4fa36f1154c5a
ios-spes           https://github.com/AdyaGMD/ios-spes.git            bdc2682efd6398f61185eab398361b066bf93794 spes
owl                https://github.com/seemoo-lab/owl.git              0ee3263f944ea721c355f826aa90d636d012a512 master
opendrop           https://github.com/seemoo-lab/opendrop.git         11fe7ba7861093b302bc0637e8cb10adf2d29337 master
ios-topaz          https://github.com/MakrSas/ios-topaz.git           e4772911e116ab4ab6c4ac1f38e6106fefe8b483 topaz
Mu-Silicium        https://github.com/Project-Silicium/Mu-Silicium.git 8471e47f5248ebbffc2e6196b683204163efe155 main
laurel-kernel-oss  https://github.com/MiCode/Xiaomi_Kernel_OpenSource.git d3766fc8cda2d96de2850faa9ce58e5a37ea9f9c laurel-r-oss
laurel-kernel-los  https://github.com/LineageOS/android_kernel_xiaomi_sm6125.git 8aaa002bfb7ba1cac2c02dbb42ae0259ef2e47ba lineage-24.0
laurel-device-los  https://github.com/LineageOS/android_device_xiaomi_laurel_sprout.git d389daebe22c2713b09742ab7153535c421ebdeb lineage-24.0
sm6125-common-los  https://github.com/LineageOS/android_device_xiaomi_sm6125-common.git 0e2b2bbfbc218d73a1f9fc17cfb3d82401f06ad9 lineage-24.0
ios-sweet-linux    https://github.com/myh120405/ios-sweet-linux.git   1b2f3a310d22a89d3473cc4d65eea44bdecbec58 main
xnu-linux-toolchain https://github.com/Allenwdk/xnu-linux-toolchain.git 909990e4ec2c6cda30c20cdb23219946918c7fd6 main
hackios-umi        https://github.com/ls9875/hackios-umi.git          6ac5eee39b076faf5c33ee14a9b17558779ee0b4 main
hackios-scion      https://github.com/Scion-Project/scion-kernel.git 73593835ff0ab0b821055b646c187b51883355bd main
ios-sweet-umi      https://github.com/myh982516/ios-sweet-umi.git     952cf3329e24c99adbb08f13fb78afe57f72ffc4 main
ios-topaz-evergo   https://github.com/wlw333554/ios-topaz.git         f6440778080cee3b1b5fef9f4260693c0a8ce86f evergo
ios-redfin         https://github.com/DenialOfGravity/ios-redfin.git  0c4433cf0060e5f0cd8947e558841c113bbad4db main
laurel-mainline    https://github.com/laurel-sprout-mainline/laurel_sprout_mainline.git 2cb8fd07918d6dd07180796da5b75cb491400df9 mainline-6.18-split
UniXNU-tb128fu     https://github.com/xVanTuring/UniXNU-tb128fu.git  a9c3863dedbee6f319bff16d3b609ec6cef409bf main
ArmCpu-tb128fu     https://github.com/xVanTuring/ArmCpu.git          3aba18e46f4277fdf8774d0c06bf71700136995d tb128fu
Adreno610-tb128fu  https://github.com/xVanTuring/Adreno610.git       43848231e83ab219fe0852437dce2d42d41d0fcf tb128fu
AdrenoMetal-tb128fu https://github.com/xVanTuring/AdrenoMetal.git    2ff4be9eabd2b1c1078f2d88e75e84d3d589a465 tb128fu
uefi-tb128fu       https://github.com/xVanTuring/uefi-tb128fu.git    4a8b6e124153e4a7efbccfb04b88ac47c87b269a tb128fu
UniXNU-clover      https://github.com/qine233/UniXNU-clover.git      4c5652ea5ebc3a000acf0510c6663194bd4b52c9 main
uefi-clover        https://github.com/qine233/uefi-clover.git        8d36aac44623d52ccaa2f1456d6e384ecc83f84f main
ios-doha           https://github.com/andrecremo/ios-doha.git        e03fc93ba59634f8c3c491f232917748f931dd9f main
ios-ginkgo         https://github.com/itswill00/ios-ginkgo.git       f882d2606542370ec594e46e5b11f21b65111c51 ginkgo-port
UniXNU-gta4l       https://github.com/gta4lunix/UniXNU-gta4l.git     bc3e47c0cd516dda23296a1e235e6a6125885f05 main
topaz-woa          https://github.com/MakrSas/topaz-woa.git          bfe5c15fd63e0038826d84dcbd2a1ff814d52654 main
ginkgo-mainline    https://github.com/Huabin1010/ginkgo-mainline-linux.git c070fbf7ef08f15647063953e30404eb1a0ee1fd main
arctos-willow      https://github.com/Arctillect-RK/arctos-redmi-note-8t.git ba47e07660019a10c1b01af851115dcf488cfc5b main
Portsmith-iOS      https://github.com/Chromitsune/Portsmith-iOS.git  8794f29410822d2c258ad6abad57b26150a99fed main
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
