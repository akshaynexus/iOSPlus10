# USB network: SSH and internet for iOS over the USB cable

With the debug kernel (`negroniusb=2`) the phone is a CDC-ECM USB Ethernet device. The kernel
gives its interface `ue0` the address 192.168.7.2/24 and streams its console to the host at
192.168.7.1 (UDP 5140, [flash-ios16.md](flash-ios16.md) "Debugging: live kernel log over USB").
This document adds, on the same cable:

- a root shell in iOS: **dropbear** SSH on 192.168.7.2:22, **dash** as `/bin/sh`, **toybox** commands;
- **internet for iOS** through the host, only while `scripts/net/share-internet.sh` is on: the host does NAT, iOS uses
  192.168.7.1 as router and 1.1.1.1 / 8.8.8.8 as DNS servers, with rank last (Wi-Fi with a router stays first). See "ue0 and Wi-Fi".

| Path | What |
|---|---|
| `userland/ssh/fetch.sh` | downloads dropbear 2026.94, dash 0.5.13.5, toybox 0.8.15 into `out/ssh/dl/`, checks pinned SHA-256 (+ dropbear's GPG-signed `SHA256SUM.asc`), unpacks to `out/ssh/src/` |
| `userland/ssh/build.sh` | builds everything for iOS arm64 (minos 16.0) into `out/ssh/ios/`, macOS builds into `out/ssh/host/`, signs, checks (macOS + Xcode only) |
| `userland/ssh/localoptions.h`, `entitlements.plist`, `compat/sys/disk.h` | dropbear options, signature entitlements, the one header the iPhoneOS SDK lacks for toybox |
| `userland/ssh/usbnetcfg.c` | our tool: publishes ue0 to configd (router + DNS, rank last). Run by `share-internet.sh`, not at boot |
| `userland/ssh/laurelnet.c` | our tool: the `LAUREL NET:` line in the kernel log (default route, DNS, reachability). On in every root with SSH; kill switch boot-arg `laurelnet=0` |
| `userland/ssh/usbreboot.c` | our tool: sync + reboot, with a reboot mode if the kernel supports one |
| `userland/ssh/oslogstream.m` (+ `oslogstream.entitlements`) | our tool: live unified log on the phone, like `log stream` (iOS ships no `log`) |
| `scripts/net/root-add-ssh.sh` (+ `.py`) | installs all of it into a mounted root (gated by `SSH=1`) |
| `scripts/net/share-internet.sh` | host NAT on/off (macOS pf, Linux iptables/nft) |
| `scripts/net/ssh-phone.sh` (+ `phone-askpass.sh`) | ssh/scp wrapper, `reboot-bootloader`. Login with no setup: repo key, else the stock password |
| `scripts/net/usbnet-check.py` | checks a root: USB has no router or DNS, no boot job, repo key in place (`root-dry-run.sh`) |
| `scripts/net/phone-run.sh` | copy a program or script to the phone, run it, print output + exit code (main test loop) |
| `scripts/net/phone-log.sh` | live unified log over SSH (oslogstream), crash reports (tail, list, show, pull) |

## Build (macOS)

```sh
brew install gnu-sed                       # toybox's build scripts need GNU sed
scripts/bg.sh ssh-build sh -c 'userland/ssh/fetch.sh && userland/ssh/build.sh'
scripts/bg.sh -s ssh-build                 # log: logs/ssh-build.log
```

The build uses all host cores and runs the six configure/make jobs (3 tools x iOS/macOS) at the
same time. Output `out/ssh/ios/`: `dropbearmulti` (dropbear, dropbearkey, dbclient, scp),
`dash`, `toybox` (136 applets, list in `toybox.applets`), `usbnetcfg`, `usbreboot`, `oslogstream`,
`SHA256SUMS`.

## Build (Linux x86_64, 2026-11-01)

```sh
scripts/bg.sh ssh-build sh -c 'userland/ssh/fetch.sh && userland/ssh/fetch-sdk.sh && userland/ssh/build.sh'
```

The same `build.sh`: stock clang compiles (`-target arm64-apple-ios16.0`), the theos toolchain that
`scripts/laurel/kernel-linux.sh` installs (`out/laurel-kernel/theos`, or `THEOS=DIR`) links and checks
(ld64 via `--ld-path`, lipo, otool, nm, strip, llvm-ar/llvm-ranlib for Darwin archives) and signs (`ldid -S`,
XML + DER entitlements). SDK: iPhoneOS16.5.sdk from theos/sdks at a pinned commit (`userland/ssh/fetch-sdk.sh`
-> `out/ssh/sdk/`, sparse clone of one directory; `IOS_SDK=DIR` for another). `out/ssh/host/` then holds Linux
builds (dropbearkey for the host key at install time). Two Linux-host quirks handled in build.sh: toybox picks
`--gc-sections` by the build host's `uname` (the iOS target gets `LDOPTIMIZE=-Wl,-dead_strip` and the Mach-O
strip), and GNU `ar` archives are ignored by ld64.

### Build details

- **dropbear**: one multi-call binary, `--disable-zlib --disable-lastlog --disable-utmp(x)
  --disable-wtmp(x) --disable-pututline --disable-pututxline --disable-pam --enable-bundled-libtom`.
  `localoptions.h`: ed25519 + ECDSA, public-key and password auth compiled in (the launchd job
  turns passwords off with `-s` when a key is installed), no X11/agent forwarding, no SFTP server,
  no MOTD. `DROPBEAR_SVR_DROP_PRIVS 0` because Darwin has no `setresgid()`; that also forces
  unix-socket forwarding off (TCP forwarding `-L`/`-R` stays). No source patch.
- **dash**: `ac_cv_func_strchrnul=no`. The iOS 27 SDK declares `strchrnul()` as iOS 18.4+; with
  libc's version dash would weak-import a symbol iOS 16 lacks (call through NULL). No patch.
- **toybox**: toybox's `scripts/macos_miniconfig` plus `dd diff tr gzip gunzip sync`, minus
  `readahead` (no `posix_fadvise`). `ps`/`top`/`pgrep` need Linux `/proc` and are not built: iOS
  has `/bin/ps`. The iPhoneOS SDK has no `<sys/disk.h>`: `userland/ssh/compat/sys/disk.h` gives
  the two ioctl numbers (same values as macOS). No patch.
- **Checks** (build fails otherwise): each binary is arm64-only, `LC_BUILD_VERSION minos 16.0`,
  has **no weak imports** (a weak import = a symbol newer than iOS 16), and its signature has an
  XML entitlements blob.

### Signing, and what this port's AMFI needs

Every iOS binary is signed ad hoc: `codesign --force -s - --entitlements userland/ssh/entitlements.plist`
(`ldid -Suserland/ssh/entitlements.plist FILE` is the Linux equivalent if you rebuild elsewhere).
The negroni kernel has no real AMFI and no trust cache (slop patches 0025/0035/0036):

- an exec needs a **valid code signature** (ad hoc is fine; page hashes are checked);
- every signed binary **on the root file system** is a platform binary (`/usr/local/bin` is on
  the root volume);
- entitlements come only from the **XML** entitlements blob (DER-only signatures get none).
  Xcode's `codesign` writes both; `build.sh` checks for the XML blob (magic `0xfade7171`).

Entitlements: `platform-application`, `com.apple.private.security.no-sandbox`,
`com.apple.private.security.no-container`, `com.apple.private.skip-library-validation` (as the
reference ports use for their shells), and `com.apple.SystemConfiguration.SCDynamicStore-write-access`
(usbnetcfg writes configd state; configd checks it). `oslogstream` uses
`userland/ssh/oslogstream.entitlements` instead: the same keys without the SCDynamicStore one, plus
`com.apple.private.logging.stream`, `com.apple.private.logging.diagnostic` and
`com.apple.diagnosticd.diagnostic` (diagnosticd checks them; the set ios-flame's `oslog` uses).

## Install into the root (integrator)

`scripts/net/root-add-ssh.sh MOUNTED_ROOT` runs as root on the mounted, writable root (the same
place as `scripts/ios16/root-finish.sh`). It does nothing unless `SSH=1`:

```sh
SSH=1 scripts/net/root-add-ssh.sh "$R"          # e.g. from root-finish.sh; sudo needs: sudo SSH=1 ...
```

What it writes (idempotent; a second run changes nothing):

| Item | Where |
|---|---|
| binaries | `/usr/local/bin/{dropbearmulti,dash,toybox,usbnetcfg,laurelnet,usbreboot,oslogstream}`, links `dropbear dropbearkey dbclient scp` -> dropbearmulti, toybox applet links (not for names that exist in `/bin /sbin /usr/bin /usr/sbin`, e.g. `df`) |
| shell | `/bin/sh` -> `/usr/local/bin/dash` (stock iOS 16 has no `/bin/sh`; an existing file is kept); `/private/etc/shells` += `/bin/sh`, `/usr/local/bin/dash` (dropbear checks the login shell with `getusershell()`); `/private/var/root/.profile` (PATH, PS1) if missing |
| login | `/private/var/root/.ssh/authorized_keys` (0600, dir 0700, root): the repo key `out/ssh/phone_ed25519.pub` (made once with `ssh-keygen`, kept for later images, owner = `SUDO_USER`), and the user's key if there is one: `SSH_PUBKEY=FILE`, else `~/.ssh/id_ed25519.pub`, `id_ecdsa.pub`, `id_rsa.pub` of `SUDO_USER` |
| host key | `out/ssh/hostkeys/dropbear_ed25519_host_key` (made once with the host dropbearkey, kept for later images) -> `/private/etc/dropbear/` (0600); public key -> `out/ssh/known_hosts` |
| launchd | `dev.iosplus10.dropbear` and `dev.iosplus10.laurelnet`; `dev.iosplus10.usbnetcfg` only with `USBNET_INTERNET=1`: plist in `/System/Library/LaunchDaemons/` and the same dictionary in `/System/Library/xpc/launchd.plist` under the `/System/Library/LaunchDaemons/<label>.plist` key (launchd on these ports reads only that cache; ios-flame: a `/Library/LaunchDaemons` key was ignored) |
| configd | `/private/var/preferences/SystemConfiguration/preferences.plist`: service `1F05B0E7-0000-4000-8000-0000000000E0` "USB Ethernet", ue0, manual 192.168.7.2 / 255.255.255.0, PrimaryRank Last, last in the IPv4 service order of the current set, no router and no DNS (`USBNET_INTERNET=1`: router 192.168.7.1, DNS 1.1.1.1 8.8.8.8); `NetworkInterfaces.plist`: ue0 (MAC 02:00:5e:77:ee:02, the phone side in slop patch 0075) |

The jobs:

```
dev.iosplus10.dropbear   /usr/local/bin/dropbear -F -E -p 192.168.7.2:22 -r /private/etc/dropbear/dropbear_ed25519_host_key [-s]
                         RunAtLoad, KeepAlive, ThrottleInterval 10, root, stderr /private/var/log/iosplus10-dropbear.log
dev.iosplus10.laurelnet  /usr/local/bin/laurelnet
                         RunAtLoad, KeepAlive {SuccessfulExit false}, ThrottleInterval 60, log /private/var/log/iosplus10-laurelnet.log
dev.iosplus10.usbnetcfg  /usr/local/bin/usbnetcfg up       (only USBNET_INTERNET=1 at the root build)
                         RunAtLoad, KeepAlive {SuccessfulExit false}, ThrottleInterval 10, log /private/var/log/iosplus10-usbnetcfg.log
```

Logs go to files, not `/dev/console`: in slop's image work, jobs whose output pointed at
`/dev/console` failed to launch (EACCES). `laurelnet` opens `/dev/console` itself for its line, as `metal_gate.c` does ([V] the
`LAUREL METAL CLIENTS:` line reaches the USB log that way).

**Host key: build time, else first boot.** With a host dropbearkey (the macOS build in
`out/ssh/host/`, or `dropbearkey` in PATH on Linux) the key is generated on the host once and
reused for every image, so `out/ssh/known_hosts` stays valid across reflashes. Without one, the
job gets `-R` instead: dropbear generates `/private/etc/dropbear/dropbear_ed25519_host_key` on the
phone at the first connection (that connection is slower), and `ssh-phone.sh` keeps the first key
it sees in `out/ssh/known_hosts.tofu`.

**Login.** No setup: `root-add-ssh.py` makes `out/ssh/phone_ed25519` once and puts its public part on the root; `ssh-phone.sh` and
`phone-ssh.sh` use it. Then key only (`-s`); `SSH_PASSWORD_AUTH=1` allows passwords too. A second key: `SSH_PUBKEY=FILE` or `~/.ssh/id_*.pub`.
Without `ssh-keygen` and without a user key: password logins are on, and the root password is the stock iOS one: `/etc/master.passwd`
in 20H392 has `root:/smx7MYTQIi2M:...`, the DES hash of **`alpine`** ([V] `perl -e 'print crypt("alpine","/s")'`). The script does not change
`master.passwd`. A root built before the repo key (the image of 2026-11-01 21:57: [V] `laurel-full.log`: "no public key found", no `-s`)
takes this password too: `ssh-phone.sh` gives it through `phone-askpass.sh` with no prompt (OpenSSH 8.4 or later; `PHONE_PASSWORD` changes it).
Plain `ssh root@192.168.7.2` on such a root: type `alpine`. `Permission denied (publickey,password)` = the host has no key that fits, and no password came
(no terminal, or a wrong one). This host has no `~/.ssh/id_*` [V], so a plain `ssh` without a terminal always gives this line.

## Use

On the host (the order does not matter; each step waits or can be repeated):

```sh
make usblog                                  # sudo once in tmux: 192.168.7.1 on the link + kernel log
scripts/net/share-internet.sh                # sudo: NAT from the default route (start), then `usbnetcfg up` on the phone
scripts/net/ssh-phone.sh wait                # until dropbear answers
scripts/net/ssh-phone.sh                     # root shell
scripts/net/ssh-phone.sh 'ps ax | head'      # one command
scripts/net/ssh-phone.sh push file.txt /var/root/    # scp -O (dropbear has no SFTP server)
scripts/net/ssh-phone.sh pull /private/var/log/iosplus10-laurelnet.log logs/
scripts/net/ssh-phone.sh net                 # usbnetcfg show: configd's IPv4/DNS state
scripts/net/share-internet.sh status
scripts/net/share-internet.sh stop           # undo NAT and forwarding, `usbnetcfg down` on the phone
```

Plain `ssh root@192.168.7.2` works too (use `scp -O` for copies). `ssh-phone.sh` env:
`PHONE_IP`, `PHONE_USER`, `SSH_KEY`, `SSH_OPTS`, `PHONE_KNOWN_HOSTS`, `PHONE_PASSWORD`. `phone-run.sh` and
`phone-log.sh` use `ssh-phone.sh`, so the same env applies.

### Test loop: phone-run.sh and phone-log.sh

SSH is the test channel for the GPU/Metal/Wi-Fi work: build a probe on the Mac, run it on the phone.

```sh
scripts/net/phone-run.sh -s out/gpu/probe --stage 3     # sign ad hoc (default entitlements), copy, run
scripts/net/phone-run.sh -e my.entitlements -f lib.dylib -f data.bin out/x/test   # own entitlements + extra files
scripts/net/phone-run.sh -k tests/check.sh              # a script; -k keeps it in /private/var/tmp/phone-run
echo $?                                                 # the program's exit code (255 = SSH problem)
```

`phone-run.sh` copies FILE (and each `-f EXTRA`) into `/private/var/tmp/phone-run/` (root volume,
so the kernel treats a signed binary as a platform binary), runs `./FILE ARGS...` there with
every argument shell-quoted, prints stdout/stderr, then removes the files (unless `-k`). `-s`
signs a copy with `userland/ssh/entitlements.plist`, `-e FILE` with other entitlements (codesign
on macOS, `ldid` on Linux). Without `-s`/`-e` it warns about an unsigned Mach-O: the negroni
kernel does not run unsigned code.

```sh
scripts/net/phone-log.sh                         # live unified log (default, error, fault)
scripts/net/phone-log.sh -l backboardd SpringBoard   # + info/debug, only these processes
scripts/net/phone-log.sh -g IOSurface            # only messages that contain IOSurface
scripts/bg.sh phonelog scripts/net/phone-log.sh -l   # long session in tmux (logs/phonelog.log)
scripts/net/phone-log.sh tail                    # print each new crash report as it appears
scripts/net/phone-log.sh crashes                 # list reports, newest first
scripts/net/phone-log.sh crash SpringBoard       # print the newest report whose name has SpringBoard
scripts/net/phone-log.sh pull                    # copy all reports to logs/phone-crashes-<date>/
```

Every mode except `pull` also appends to `logs/phone-log-<date>.txt`. The live mode runs
`/usr/local/bin/oslogstream` (LoggingSupport's live store through diagnosticd, the method of
ios-flame's `oslog`). If the root has no `oslogstream`, `phone-log.sh` follows the crash
reports in `/private/var/mobile/Library/Logs/CrashReporter` instead (`PHONE_CRASHDIR` overrides).
Note: `scripts/ios16/root-tweaks-extra.py` removes the `com.apple.ReportCrash` job, so iOS may
write no crash reports at all. The kernel's `CRASH ...` lines in the USB kernel log
(`make usblog`) are then the crash source.

### How iOS gets internet

1. The kernel puts 192.168.7.2/24 on ue0 (slop patch 0075). Enough for SSH and the log.
2. configd does not configure ue0 by itself: on slop's image v15 the preferences.plist service
   alone gave no DNS and no traffic (slop NOTES.md 2026-10-18); bergamota and ios-flame saw the
   same and fixed it by writing configd's *state* keys. `usbnetcfg up` (run by `share-internet.sh`; at each boot only with
   `USBNET_INTERNET=1`) waits up to 120 s for configd and ue0, then writes `State:/Network/Service/<id>` (`PrimaryRank` Last),
   `.../IPv4` (address, mask, router 192.168.7.1, `InterfaceName` ue0), `.../DNS` (1.1.1.1, 8.8.8.8) and
   `State:/Network/Interface/ue0/IPv4`. IPMonitor then uses ue0 for the default route and DNS, if no other service has a router.
   If no service is primary after 5 s, usbnetcfg adds the default route through a routing socket (IP works then; names need
   IPMonitor's DNS). Never while Wi-Fi is primary. No ue0 within 120 s (USB network off): it exits 0, so launchd does not restart it.
3. The host forwards and NATs 192.168.7.0/24 (`share-internet.sh`).

`share-internet.sh` details: macOS: `sysctl net.inet.ip.forwarding=1`, rule
`nat on <uplink> inet from 192.168.7.0/24 to any -> (<uplink>)` in the pf anchor
`com.apple/iosplus10-share` (the stock `/etc/pf.conf` evaluates `com.apple/*`), pf enabled with
`pfctl -E` and its token. Linux: `net.ipv4.ip_forward=1`, iptables MASQUERADE + two FORWARD
accepts (comment `iosplus10-share`; inserted first so a distro FORWARD policy does not drop
them), or an `nft` table `ip iosplus10-share` without iptables. The old forwarding value, the
uplink and the pf token are saved in `/var/run/iosplus10-share.state`; `stop` restores them.
Nothing survives a host reboot. macOS Internet Sharing is not used: it would put its own DHCP
subnet on the link.

### ue0 and Wi-Fi

Log `logs/laurel-boot-2235.txt` (main checkout), owner: "Wi-Fi is fine, but fast.com and speedtest don't load". Details: `laurel_sprout/wifi.md` "No page loads".
Before this fix, `usbnetcfg up` ran at each boot and put ue0 first. So the phone sent its default route and its DNS (1.1.1.1, 8.8.8.8) to the host, also with Wi-Fi
joined. The host has no NAT unless `share-internet.sh` runs, so nothing came back. Now a normal root does not publish ue0: SSH and the log do not need it.
The next boot says the state itself:

```
LAUREL NET: on: default route en0 via 192.168.1.1, v6 en0 via fe80::1, dns 2 servers 192.168.1.1 8.8.8.8, reachability yes (flags 0x2)
```

`default route ue0`: the USB link has the route (`share-internet.sh` is on, and Wi-Fi has no router). `default route none`, `dns 0 servers`: no service has an address yet.

A root that has the old job, on the running phone, no rebuild: `scripts/net/ssh-phone.sh /usr/local/bin/usbnetcfg down`, until the next boot.

### macOS Local Network privacy

macOS asks per app before a process may open connections to hosts on a local network. Tools run
in a terminal inherit the terminal app's permission. If the terminal app never asks (ios-flame
saw this with Ghostty: no `NSLocalNetworkUsageDescription`), `ssh` fails with
`No route to host` although the link works (the UDP kernel log still arrives). Fix: allow the
terminal app in System Settings > Privacy & Security > Local Network, or use a terminal that asks
(Terminal.app). ios-flame's FlameBridge (`external/ios-flame/tools/flamebridge`, MIT) is a
workaround: a small app with the permission that relays `127.0.0.1:2222` to `192.168.7.2:22`;
then `PHONE_IP=127.0.0.1 SSH_OPTS='-o Port=2222' scripts/net/ssh-phone.sh`.

### Reboot from iOS

`scripts/net/ssh-phone.sh reboot-bootloader` runs `usbreboot bootloader` on the phone and then
waits up to 90 s for `fastboot devices`. `usbreboot` sets the reboot mode through the sysctl
`kern.negroni_reboot_mode` (or bergamota's `kern.sweet_reboot_mode`), syncs and calls
`reboot(RB_AUTOBOOT)`. **The current negroni kernel has neither the sysctl nor a restart
handler** (no `PE_halt_restart` in the slop patches), so `usbreboot` refuses (exit 3) and the
script says so. `reboot-bootloader -f` reboots anyway; the kernel may then stop at `MACH Reboot`.
Then hold Volume Up + Volume Down + Power for fastboot. A kernel patch for the restart path
(PSCI SYSTEM_RESET + the PMIC PON / IMEM reboot reason, as bergamota 0137 does for SDM845) would
make this work; the tool needs no change for it.

## Security notes

- Reachable only on 192.168.7.2:22, the USB link to the host that is plugged in. Not bound to
  other interfaces (en0 has its own address).
- With a key (the default: the repo key): public-key login only. Without a key: root with the publicly known password
  `alpine`; anyone on the link can log in. Use a key.
- `out/ssh/phone_ed25519` (git-ignored) is a private key without a passphrase: root on the phone. Keep it out of git and out of shared images.
- dropbear runs as root, unsandboxed, as a platform binary; the shell can do everything. This
  port has no real iOS security model (AMFI stand-in, permissive sandbox, no SEP), so this is a
  bring-up tool, not hardening. TCP forwarding (`ssh -L/-R`) is on; add `-j -k` to the job
  arguments to turn it off.
- The host key (`out/ssh/hostkeys/`, git-ignored) is a private key: keep it out of git and out of
  shared images. `ssh-phone.sh` uses its own known_hosts files in `out/ssh/`.
- `share-internet.sh` makes the host a router for 192.168.7.0/24 only, until `stop` or a reboot.

## Tested / not tested

Tested on the Mac (2026-10-24, macOS 27, Xcode 27.1, iPhoneOS 27.1 SDK):

- `fetch.sh`: all three SHA-256 pins match; dropbear's `SHA256SUM.asc` signature is good and lists the pin.
- `build.sh`: all 5 iOS binaries build, arm64, minos 16.0, no weak imports, ad hoc signed with
  an XML entitlements blob.
- macOS builds from the same sources and options: dropbear on 127.0.0.1 with `-s`: key login
  works, a different key gets `Permission denied (publickey)`, only `publickey` is offered;
  without `-s` `publickey,password` is offered; `scp -O` works, SFTP-based `scp` does not (expected).
  dash runs scripts; toybox `ls sed grep find tar diff dd gzip ...` work.
- `ssh-phone.sh` against that server: `wait`, a command, `push` (2 files), `pull`, the failure hint,
  strict host-key refusal for an unknown key.
- `phone-run.sh` against that server: a script with an extra file and the arguments `"a b"` and
  `"it's"` arrives intact, exit code 7 comes back, files are removed (kept with `-k`), the warning
  for an unsigned Mach-O.
- `phone-log.sh` against that server (crash folder = a test folder): `crashes`, `crash NAME`
  (exit 1 for no match), `pull`, and the default mode without `oslogstream` falls back to `tail`,
  which printed a report created while it ran. `oslogstream` itself builds and passes the checks.
- `usbnetcfg show` built for macOS reads the dynamic store (the `up` path was not run on the Mac:
  it would change the host's network state).
- `root-add-ssh.sh` on a scratch fake root (as non-root): files, links, modes, plists
  (`plutil -lint`), skip without `SSH=1`, second run identical.

Not tested (no phone in this task): anything on iOS. In particular exec of the signed binaries
under the negroni AMFI, pty login through dropbear, `getpwnam`/`crypt` for the password path,
binding 192.168.7.2 at boot, launchd starting the two jobs from `launchd.plist`, whether
IPMonitor accepts the published state on this kernel (no IOKit network-interface stand-ins like
bergamota's 0110), the route fallback, `share-internet.sh start/stop` (needs sudo; not run), `usbreboot` and
`oslogstream` on the phone (the private LoggingSupport classes and the diagnosticd entitlements
are untested on this port).

## Speed

The link runs at USB high speed. Before patch 0361 the gadget moved one frame per 1 ms poll (1.0-1.2 MB/s);
patch 0361 adds an RX ring and TX batches (patches/xnu/README-usb.md). Counters: `op10tool ctl usbstats`.
Fallback boot-arg: `negroniusb_ring=0`.
