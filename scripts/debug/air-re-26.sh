#!/bin/bash
# What iOS 26.5.2 23F84 (N104AP) needs for AirDrop and AirPlay: read from the donor images and the dyld cache, for docs/laurel_sprout/ios26-airdrop.md. Read-only.
#   scripts/bg.sh air-re-26 scripts/debug/air-re-26.sh      -> out/air-re-26/ (git-ignored: Apple text)
#   scripts/debug/air-re-26.sh dis IMAGE                    -> out/air-re-26/IMAGE.s (ipsw disassembly of one cache image)
# Needs: out/bin/ipsw (scripts/setup/get-ipsw-cli.sh), apfs-fuse (Linux) or hdiutil (macOS), python3, the tree of scripts/ios26/sysos-tree.sh.
# Same questions as scripts/debug/air-re.sh for 20H392, so the two can be compared. Nothing from the images runs.
set -euo pipefail
here=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
APPLE=${APPLE:-$HOME/op10-apple}
D=$APPLE/ios26/23F84-n104ap
T=$D/tree
W=$here/out/air-re-26
IPSW=${IPSW:-$here/out/bin/ipsw}
DSC=$T/cache/dyld_shared_cache_arm64e
mkdir -p "$W/jobs" "$W/ent" "$W/str"

if [ "${1:-}" = dis ]; then
  "$IPSW" dyld disass "$DSC" --image "$2" --quiet --color=false > "$W/$2.s" 2> "$W/$2.err" || tail -3 "$W/$2.err"
  wc -l "$W/$2.s"
  exit 0
fi

MNT=$here/out/air-re-26/mnt
mkdir -p "$MNT/os" "$MNT/sys"
case "$(uname -s)" in
Linux)
  apfs-fuse "$D/os/094-55773-107.dmg" "$MNT/os"
  apfs-fuse "$D/os/094-56417-109.dmg" "$MNT/sys"
  OS=$MNT/os/root SYS=$MNT/sys/root
  unmount() { fusermount3 -u "$1" 2>/dev/null || fusermount -u "$1"; } ;;
Darwin)
  hdiutil attach -readonly -nobrowse -mountpoint "$MNT/os" "$D/os/094-55773-107.dmg" >/dev/null
  hdiutil attach -readonly -nobrowse -mountpoint "$MNT/sys" "$D/os/094-56417-109.dmg" >/dev/null
  OS=$MNT/os SYS=$MNT/sys
  unmount() { hdiutil detach "$1" >/dev/null; } ;;
esac
trap 'unmount "$MNT/os" || true; unmount "$MNT/sys" || true' EXIT

# launchd jobs: the cache file (if any), and each plist that names a relevant service
ls -la "$OS/System/Library/xpc/" > "$W/xpc-ls.txt" 2>&1 || true
for f in launchd.plist; do [ -f "$OS/System/Library/xpc/$f" ] && cp "$OS/System/Library/xpc/$f" "$W/$f"; done
for dir in "$OS/System/Library/LaunchDaemons" "$OS/System/Library/NanoLaunchDaemons" "$SYS/System/Library/LaunchDaemons"; do
  [ -d "$dir" ] || continue
  ls "$dir" >> "$W/jobs-ls.txt"
  for p in "$dir"/*; do
    case "$(basename "$p")" in
      *sharing*|*wifip2p*|*rapport*|*airplay*|*AirPlay*|*mediaserver*|*wifid*|*WirelessRadio*|*mDNS*|*nearby*|*bluetoothd*|*wifianalytics*|*coreduet*|*mediaremote*|*audiomxd*|*audioanalytics*|*fairplay*|*timed*|*tccd*)
        cp "$p" "$W/jobs/" ;;
    esac
  done
done
# entitlements + strings of each daemon (Apple text, out/ only)
python3 -I "$here/scripts/debug/macho-ent.py" "$T/root" "$W/ent" usr/libexec/sharingd usr/libexec/wifip2pd usr/libexec/rapportd usr/libexec/airplayd \
  usr/sbin/mediaserverd usr/sbin/mDNSResponder usr/sbin/wifid usr/sbin/bluetoothd usr/libexec/nearbyd \
  System/Library/PrivateFrameworks/AirPlaySenderKit.framework/XPCServices/AirPlaySenderService.xpc/AirPlaySenderService \
  Applications/AirPlaySenderUIApp.app/AirPlaySenderUIApp System/Library/Audio/Plug-Ins/HAL/AirPlayHalogen.driver/AirPlayHalogen
for f in os/usr/libexec/sharingd os/usr/libexec/wifip2pd os/usr/libexec/rapportd os/usr/libexec/airplayd os/usr/sbin/mDNSResponder os/usr/sbin/mediaserverd os/usr/sbin/wifid os/usr/sbin/bluetoothd; do
  [ -f "$T/root/$f" ] || continue
  b=${f##*/}
  [ -s "$W/str/$b.txt" ] || strings -a -n 5 "$T/root/$f" > "$W/str/$b.txt"
done
# the images of the cache, one strings + one imports file each
"$IPSW" dyld image "$DSC" > "$W/images.txt" 2>/dev/null || true
for image in AirPlaySender APTransport AirPlaySupport AirPlayReceiver AirPlaySync MediaExperience CoreUtils Sharing IO80211 WiFiPeerToPeer DeviceToDeviceManager WiFiAware Network; do
  [ -s "$W/str/$image-str.txt" ] || "$IPSW" dyld macho "$DSC" "$image" --strings > "$W/str/$image-str.txt" 2>/dev/null || true
  [ -s "$W/str/$image-load.txt" ] || "$IPSW" dyld macho "$DSC" "$image" --loads > "$W/str/$image-load.txt" 2>/dev/null || true
  echo "$image: $(wc -l < "$W/str/$image-str.txt") strings, $(wc -l < "$W/str/$image-load.txt") load lines"
done
# text of the whole cache, for the keys that move between images
if [ ! -s "$W/dsc-strings.txt" ]; then
  LC_ALL=C strings -a -n 6 "$DSC" "$DSC".[0-9][0-9] | grep -aiE 'airplay|bonjour|_raop|_airdrop|awdl|wifi-aware|wifiaware|D2D|wifip2p|sessionProtocolOverride|BrowseAllInterfaces|RegisterAllInterfaces|DiscoverableMode|IO80211VirtualInterfaceRole|AirLink|IOTimeSync' > "$W/dsc-strings.txt" || true
fi
wc -l "$W/dsc-strings.txt" "$W/jobs-ls.txt"
ls "$W/jobs" | wc -l
