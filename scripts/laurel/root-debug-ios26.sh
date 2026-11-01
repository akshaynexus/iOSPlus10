#!/bin/bash
# The debug path of the Mi A3 iOS 26.5.2 23F84 first-boot root, on a mounted root or a stage (docs/laurel_sprout/ios26-first-boot.md). ios26-root-spec.py debug() calls it. Idempotent.
#   scripts/laurel/root-debug-ios26.sh ROOT      DEBUG26=0: off, one line
# Installs through scripts/net/root-add-ssh.py, the same code as iOS 16, with SSH_IOS26=1: dropbear on 192.168.7.2:22 only (the USB link; no listener on Wi-Fi), dash, toybox, usbreboot, oslogstream, laurelnet,
# the configd service of ue0 (fixed address, no DHCP); and out/laurel/debug/ios/ksysctl (scripts/laurel/ios26-debug-build.sh; no sysctl tool on iOS).
# Login: the repo key out/ssh/phone_ed25519 + the host user's public key + the stock password alpine of 23F84 (the hash is in the donor's master.passwd; this script writes no password). SSH_PASSWORD_AUTH=0: keys only.
# Host key: out/ssh/hostkeys (made once on the host, kept, never in git), else dropbear -R makes it on the phone at the first connection.
# Plain arm64 only. The kernel takes these files: sweet_amfi marks every signature on the root platform (docs/laurel_sprout/ios26-first-boot.md section 2). A root with a trust list needs the hashes in
# /usr/share/laurel/ios26-debug-cdhashes. launchd reads the edited launchd.plist because of the boot-arg launchd_unsecure_cache=1 (scripts/laurel/uefi-image.sh).
# Output: one line "laurel-root: debug-ios26: ITEM: text" per item, for the audit of the root.
set -euo pipefail
R=${1:?usage: $0 ROOT}
REPO=$(cd "$(dirname "$0")/../.." && pwd)
tag="laurel-root: debug-ios26:"
if [ "${DEBUG26:-1}" = 0 ]; then echo "$tag off: DEBUG26=0: no SSH on this root"; exit 1; fi
[ -f "$R/System/Library/xpc/launchd.plist" ] || { echo "$tag off: no launchd.plist in $R"; exit 1; }
MAIN=$(git -C "$REPO" worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')
# SSH_OUT: this folder and no other. Else out/ssh of this checkout, else of the main checkout (a worktree has none of its own)
S=${SSH_OUT:-$REPO/out/ssh}
[ -n "${SSH_OUT:-}" ] || [ -x "$S/ios/dropbearmulti" ] || S=${MAIN:-$REPO}/out/ssh
tools="dropbearmulti dash toybox usbnetcfg laurelnet usbreboot oslogstream"
plain() {
  python3 -I - "$1" <<'PY'
import struct, sys
m, c, s = struct.unpack('<III', open(sys.argv[1], 'rb').read(12))
sys.exit(0 if (m, c, s & 0xff) == (0xfeedfacf, 0x0100000c, 0) else 1)
PY
}
for n in $tools; do
  [ -x "$S/ios/$n" ] || { echo "$tag off: no $S/ios/$n (userland/ssh/build.sh)"; exit 1; }
  plain "$S/ios/$n" || { echo "$tag off: $S/ios/$n is not plain arm64: refused"; exit 1; }
done
export SSH=1 SSH_OUT="$S" SSH_IOS26=1 SSH_PASSWORD_AUTH=${SSH_PASSWORD_AUTH:-1}
# scripts/net/root-add-ssh.sh checks SSH=1; the stage gives its list of stock commands
export SSH_STOCK_NAMES=${STOCK_NAMES:-}
said=$(python3 -I "$REPO/scripts/net/root-add-ssh.py" "$R" 2>&1) || { echo "$tag off: root-add-ssh.py: $(printf '%s\n' "$said" | tail -1)"; exit 1; }
printf '%s\n' "$said" | grep -v '^warning: not root' || true
# one more tool of ours, no SSH needs it
K=$REPO/out/laurel/debug/ios/ksysctl; [ -x "$K" ] || K=${MAIN:-$REPO}/out/laurel/debug/ios/ksysctl
if [ -x "$K" ] && plain "$K"; then
  install -m 755 "$K" "$R/usr/local/bin/ksysctl"
  ks="on"
else
  ks="off: no out/laurel/debug/ios/ksysctl (scripts/laurel/ios26-debug-build.sh); kern.laurel_stats has no reader on this root, the USB log has the same lines"
fi
mkdir -p "$R/usr/share/laurel"
# cdhashes of what this script installed: the input if the kernel ever reads a trust list
paths=$(cd "$R" && find usr/local/bin -maxdepth 1 -type f | sort)
# shellcheck disable=SC2086
python3 -I "$REPO/scripts/laurel/ios26-air-cdhash.py" "$R" $paths > "$R/usr/share/laurel/ios26-debug-cdhashes"
# one audit line each: what a reader of the first boot wants to know
python3 -I - "$R" "$ks" "$tag" <<'PY'
import plistlib, sys
root, ks, tag = sys.argv[1:]
jobs = plistlib.load(open(root + '/System/Library/xpc/launchd.plist', 'rb'))['LaunchDaemons']
d = jobs['/System/Library/LaunchDaemons/dev.iosplus10.dropbear.plist']
a = d['ProgramArguments']
if '192.168.7.2:22' not in a:
    print(f'{tag} off: dropbear is not bound to the USB address: {a}')
    sys.exit(1)
keyp = 'host key from out/ssh/hostkeys' if '-r' in a else 'host key made on the phone at the first connection (-R)'
print(f"{tag} ssh: launchd job dev.iosplus10.dropbear: {' '.join(a)}; {keyp}; USB address only, no listener on Wi-Fi; stderr to /dev/console")
print(f"{tag} login: keys in /private/var/root/.ssh/authorized_keys and password login on{' ' if '-s' not in a else ' NOT '}(stock alpine of the donor's master.passwd; no new secret)")
print(f"{tag} usb network: ue0 192.168.7.2/24 fixed, kernel + configd service; host 192.168.7.1; no DHCP; no default route through USB")
print(f"{tag} tools: /usr/local/bin dropbear dash toybox usbnetcfg laurelnet usbreboot oslogstream; /bin/sh -> dash; ksysctl {ks}")
print(f"{tag} jobs: {len(jobs)} in launchd.plist; launchd_unsecure_cache=1 skips its signature check [V launchd_cache_loader 23F84]")
PY
line="debug-ios26: dropbear on 192.168.7.2:22, ksysctl $ks"
printf '%s\n' "$line" > "$R/usr/share/laurel/ios26-debug-manifest"
