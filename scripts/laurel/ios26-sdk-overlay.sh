# Sourced by kernel-ios26-linux.sh after setup-deps --stage1: the headers of macOS 26.5 that the public SDK lacks, in the overlay
# SDK ($XNU_SDK_PATH, symlinks to the SDK): libplatform (usr/local/include, Kernel.framework platform), libdispatch os/*.h
# for the firehose code. Same list as UniXNU-ios26 scripts/build-xnu-12377.sh. Pinned tags of macOS 26.5 release.json.
_lp=$DEPS/libplatform
[ -d "$_lp/.git" ] || git clone -q --depth 1 --branch libplatform-375.120.2 https://github.com/apple-oss-distributions/libplatform.git "$_lp" 2>/dev/null
_kp=$XNU_SDK_PATH/System/Library/Frameworks/Kernel.framework/Versions/A/PrivateHeaders
mkdir -p "$XNU_SDK_PATH/usr/local/include/kernel" "$_kp"
cp -Rf "$_lp/include/." "$XNU_SDK_PATH/usr/local/include/"
cp -Rf "$_lp/private/." "$XNU_SDK_PATH/usr/local/include/"
rm -rf "$_kp/platform.lp"; mkdir -p "$_kp/platform"; cp -Rf "$_lp/private/platform/." "$_kp/platform/"
mkdir -p "$XNU_SDK_PATH/usr/local/include/os"
for _h in "$DEPS"/libdispatch/os/*.h; do
  { "$DEPS/host/bin/unifdef" -DKERNEL=1 -DOS_FIREHOSE_SPI=1 -DOS_VOUCHER_ACTIVITY_SPI_TYPES=1 -UOS_VOUCHER_ACTIVITY_SPI "$_h" || [ $? -eq 1 ]; } > "$XNU_SDK_PATH/usr/local/include/os/$(basename "$_h")"
done
# availability.pl of AvailabilityVersions-157.2 is a wrapper of ./availability, which reads availability.dsl
cp -f "$DEPS/AvailabilityVersions/availability" "$DEPS/AvailabilityVersions/availability.dsl" "$XNU_SDK_PATH/usr/local/libexec/"
chmod +x "$XNU_SDK_PATH/usr/local/libexec/availability"
export RC_DARWIN_KERNEL_VERSION=25.5.0 RC_ProjectSourceVersion=12377.121.6 TIGHTBEAMC=tightbeamc-not-supported
