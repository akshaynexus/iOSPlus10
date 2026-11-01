# Sourced by the Mi A3 iOS 26 kernel scripts (kernel-ios26-linux.sh, ios26-series-tree.sh). Needs $REPO, $OUT, $EXT (lib/env.sh).
# Work tree: out/laurel-kernel-ios26/ (own tree; the iOS 16 build in out/laurel-kernel/ is not touched).
# Toolchain recipe as scripts/laurel/kernel-linux.sh: external/ios-sweet-linux/linux + stock clang + the theos cctools,
# with the versions of macOS 26.5 (distribution-macOS release.json macos-265) and the MacOSX 26.1 SDK.
W=$OUT/laurel-kernel-ios26
XNU_TAG=xnu-12377.121.6
XNU_TAG_SHA=ac9718fb1af618d5ce8678d0dc6e8a58f252216f
SDK_VER=26.1
SDK_SHA256=beee7212d265a6d2867d0236cc069314b38d5fb3486a6515734e76fa210c784c
KDK_URL=https://github.com/dortania/KdkSupportPkg/releases/download/25F84/Kernel_Debug_Kit_26.5.2_build_25F84.dmg
KDK_SHA256=faef4393becf65c88a2791770904909babf1826d23d2ea478bf878a6417851ab
MAIN=$(git -C "$REPO" worktree list --porcelain | sed -n '1s/^worktree //p')
# ref NAME: external/NAME of this checkout, or of the main checkout (a worktree has no reference repos)
ref() {
  if [ -e "$EXT/$1" ] && [ -n "$(ls -A "$EXT/$1" 2>/dev/null)" ]; then echo "$EXT/$1"
  elif [ -e "$MAIN/external/$1" ]; then echo "$MAIN/external/$1"
  else echo "ios26-env: missing external/$1: scripts/setup/get-references.sh $1" >&2; return 1; fi
}
SWEETLINUX=$(ref ios-sweet-linux)
TOPAZ=$(ref ios-topaz)
mkdir -p "$W/dl" "$W/deps" "$W/logs" "$W/src" "$W/cache"
# linux/: a fresh copy each run, with our versions
rm -rf "$W/linux"
cp -R "$SWEETLINUX/linux" "$W/linux"
rm -f "$W/linux/fixes/"*.patch
sed -i -e "s|xnu-8796.141.3|$XNU_TAG|g" -e "s|1b191cb58250d0705d8a51287127505aa4bc0789|$XNU_TAG_SHA|" \
  -e "s|MacOSX13.3|MacOSX$SDK_VER|g" -e "s|XNU_SDK_VERSION:-13.3|XNU_SDK_VERSION:-$SDK_VER|" \
  -e 's|MACOS_VERSION:-13.5|MACOS_VERSION:-26.5|' -e "s|XNU_SRC:-\$TOP/xnu-src/\$XNU_TAG|XNU_SRC:-\$TOP/src/xnu|" "$W/linux/env.sh"
sed -i "s|MacOSX13.3|MacOSX$SDK_VER|g" "$W/linux/bin/iig"
sed -i -e "s|releases/download/13.3/MacOSX13.3|releases/download/$SDK_VER/MacOSX$SDK_VER|g" -e "s|MacOSX13.3|MacOSX$SDK_VER|g" "$W/linux/setup-sdk.sh" "$W/linux/setup-deps.sh"
sed -i "s|arm64-apple-macos\${XNU_SDK_VERSION:-13.3}|arm64-apple-macos\${XNU_SDK_VERSION:-$SDK_VER}|" "$W/linux/bin/xnu-clang"
# flags only Apple's clang knows, new in xnu-12377
sed -i 's/-fapple-kext-vtable-verify|-Wno-vla-cxx-extension) ;;/-fapple-kext-vtable-verify|-Wno-vla-cxx-extension|-mno-implicit-sme) ;;/' "$W/linux/bin/xnu-clang"
# Apple clang never registers static destructors in a kext or kernel; stock clang does on Darwin, through ___cxa_atexit
sed -i 's/extra=(-fno-use-cxa-atexit)/extra=(-fno-use-cxa-atexit -fno-register-global-dtors-with-atexit)/' "$W/linux/bin/xnu-clang"
grep -q 'mno-implicit-sme' "$W/linux/bin/xnu-clang" || { echo "ios26-env: cannot edit xnu-clang" >&2; return 1; }
# makedefs (macos-265 versions); libfirehose for cortex-a53 as in kernel-linux.sh (the Kryo 260 traps on LSE at the first log write)
sed -i -e 's|5d9baee345b3bc72b26c71adc65f94f2d5e9ced2|AvailabilityVersions-157.2|' \
  -e 's|a641558f447659d90ad002ef0ee6f0212273fbfc|libdispatch-1542.100.32|' \
  -e 's|xnu-clang -arch arm64 -c -Os -mkernel -nostdinc -fno-builtin|xnu-clang -arch arm64 -mcpu=cortex-a53 -c -Os -mkernel -nostdinc -fno-builtin|' "$W/linux/setup-deps.sh"
# 12377 headers test XNU_KERNEL_PRIVATE with #ifdef in places: the kext view is "not defined", not 0
sed -i 's/-DXNU_KERNEL_PRIVATE=0 //' "$W/linux/setup-deps.sh"
sed -i 's|-I$XNU_SDK_PATH/usr/local/include/kernel \\|-I$XNU_SDK_PATH/usr/local/include/kernel -idirafter $XNU_SDK_PATH/usr/include \\|' "$W/linux/setup-deps.sh"
grep -q 'idirafter' "$W/linux/setup-deps.sh" || { echo "ios26-env: cannot add the SDK include path for libfirehose" >&2; return 1; }
grep -q 'mcpu=cortex-a53 -c -Os -mkernel' "$W/linux/setup-deps.sh" || { echo "ios26-env: cannot set -mcpu for libfirehose" >&2; return 1; }
# the links setup-deps makes in linux/bin: linux/ is new on each run
ln -sfn xnu-clang "$W/linux/bin/xnu-clang++"
[ -e "$W/theos/toolchain/linux/iphone/bin/ld" ] && ln -sfn "$W/theos/toolchain/linux/iphone/bin/ld" "$W/linux/bin/ld64"
# iig: the Python rewrite of xnu-linux-toolchain generates .h and .iig.cpp from the .iig of this tree (12377 has .iig files
# that no SDK ships as generated headers: iokit/Tests/TestServices)
cp "$(ref xnu-linux-toolchain)/toolchain/iig" "$W/linux/bin/iig"
python3 -I "$REPO/scripts/laurel/ios26-iig-fix.py" "$W/linux/bin/iig"
export TOP=$W THEOS=$W/theos MACHINE_CONFIG=SWEET KERNEL_CONFIG=${KERNEL_CONFIG:-DEVELOPMENT} JOBS=$NPROC MACOS_VERSION=26.5
export DEPS=$W/deps XNU_SRC=$W/src/xnu PATCHES_DIR=$W/patches KDKROOT=$W/kdk
. "$W/linux/env.sh"
# TOP and the rest come back from env.sh with our values
