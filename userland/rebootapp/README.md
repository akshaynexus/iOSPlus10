# XNUtils.app (formerly PowerMenu.app)

A home screen app: Metal device status and three buttons (Reboot to Bootloader, Restart, Shut Down).
iOS 16.7.16 (20H392) on the OnePlus 10 Pro. UI: the owner's `main.m`.

Rename (2026-10-25 19:32, owner; build and install scripts follow since 2026-10-27): the app is
`XNUtils.app`, bundle id `dev.iosplus10.xnutils`. The old `PowerMenu.app` (`dev.iosplus10.powermenu`)
is removed by the root hook and by `scripts/net/phone-add-powermenu.sh`. The helper, `pmregister`,
`out/powermenu/` and the `POWERMENU=1` / `powermenu` hook names stay as they are.

## Files

| File | What |
|---|---|
| `main.m`, `Info.plist` | the app (UIKit + Metal), bundle id `dev.iosplus10.xnutils` |
| `XNUtils`, `XNUtils.app/` | the owner's hand build (2026-10-25 19:33); `build.sh` gives the same bytes |
| `entitlements.plist` | app entitlements (same bytes as `userland/ssh/entitlements.plist`) |
| `powermenu-helper.c`, `helper.entitlements` | the setuid-root helper |
| `pmregister.m`, `pmregister.entitlements` | LaunchServices register tool, only for an install on a running phone |
| `build.sh` | macOS + Xcode build into `out/powermenu/` |

## Build

`userland/rebootapp/build.sh` (a few seconds). Output: `out/powermenu/XNUtils.app`,
`powermenu-helper`, `pmregister`, `SHA256SUMS` (it deletes an old `out/powermenu/PowerMenu.app`).
The app name comes from `CFBundleExecutable` in `Info.plist`; the check wants the bundle id
`dev.iosplus10.xnutils`. Checks: arm64 only, minos 16.0, no weak imports,
XML entitlements blob present, `codesign --verify --strict`.

The build is reproducible: two runs give the same bytes. With the owner's first `main.m`, the
output was byte-identical to the owner's hand-built `PowerMenu.app` (2026-10-25). With the XNUtils
`main.m` (flags + `-framework Metal`), the build is byte-identical to the owner's `XNUtils` (unsigned,
sha256 afaaebfa…) and `XNUtils.app` (binary 94288 B, sha256 246c5325…, same `Info.plist` and
`CodeResources`) (2026-10-27). ld puts the
output path into `LC_UUID`, so `build.sh` links in `out/powermenu/build` with a relative `-o`.

## Privileges: why a setuid helper

Note (2026-10-27): the XNUtils `main.m` does not call the helper. Restart and Shut Down call
`reboot()` in the app (uid mobile: [I] no effect, see below). Reboot to Bootloader starts
`/usr/local/bin/usbreboot -f bootloader` as mobile. The helper stays installed for SSH and for a
`main.m` that uses it again.

The app runs as user `mobile` (501). `reboot(2)` needs euid 0 (`suser()` in `bsd/kern/kern_xxx.c`),
and so does the reboot-mode sysctl. So the app's own `reboot()` call did nothing.

Choice: one small setuid-root helper, `/usr/local/libexec/powermenu-helper`, owner `root`, group
`mobile`, mode 4750.

- It accepts exactly one word: `restart`, `shutdown`, `bootloader` (and `check`, which does not
  reboot). It reads no environment variable, opens no file and starts no other program.
- Mode 4750: only root and group `mobile` can run it.
- Caller check: real uid 0 (SSH root) is allowed. Real uid 501 is allowed only when the parent
  process path (`proc_pidpath(getppid())`) is `/Applications/XNUtils.app/XNUtils` (was
  `/Applications/PowerMenu.app/PowerMenu` until 2026-10-27).
- No resident process, no socket, no launchd job, no protocol to parse.

A root launchd daemon with a socket or a notify name gives the same three actions, but it needs a
job in `launchd.plist`, a process that runs all the time, a socket path in `/var` and a protocol.
A notify name cannot check the sender at all. The setuid helper is smaller and its caller check
is the same.

What the kernel does with each request (0210 + 0211 since `local-20261024-191117`; 0213 adds the
reboot mode):

| Button | Helper | Kernel path |
|---|---|---|
| Restart | `sync`, `reboot(RB_AUTOBOOT)` | 0211 `kPERestartCPU`: reason of `kern.negroni_reboot_mode` (default normal = 0), PSCI `SYSTEM_RESET` |
| Shut Down | `sync`, `reboot(RB_HALT)` | 0211 `kPEHaltCPU`: `negroni_power_off()`, PSCI `SYSTEM_OFF` |
| Reboot to Bootloader | set `kern.negroni_reboot_mode=bootloader`, read it back, then as Restart | 0213: `negroni_restart()` writes reason 2 (ABL fastboot), PSCI `SYSTEM_RESET` |

Reboot to Bootloader needs a kernel with patch 0213 (`patches/xnu/README-reboot.md`, "0213").
0213 adds the root-only string sysctl `kern.negroni_reboot_mode` (`normal`, `bootloader`,
`fastboot`, `recovery`). The 0211 restart path uses its reason instead of 0 and logs
`NEGRONI REBOOT: reason bootloader`. The helper writes `bootloader` with `sysctlbyname()`, reads
the value back (a different value: exit 1, no reboot), then calls `sync` and `reboot(RB_AUTOBOOT)`.

Older kernels (before 0213) have no such sysctl. Then the helper exits with code 3 and the app
shows a message (use Volume Up + Volume Down + Power, or `op10tool ctl bootloader` from the
computer). It does not fall back to a normal restart. (The 0210 UDP command `bootloader` is not
a way for the phone itself: a process on the phone cannot reach the USB receive path.)

`reboot(2)` is the direct path (as `usbreboot`): the kernel kills the processes, syncs and
unmounts. Apps do not get a launchd-ordered shutdown.

## Install into a new root

`scripts/ios16/root-finish.sh` calls `scripts/ios16/root-add-powermenu.sh` (`POWERMENU=1` by
default when `out/powermenu/XNUtils.app` is built, `POWERMENU=0` to skip). It installs:

- `/Applications/XNUtils.app`: root:wheel, folders 755, files 644, the executable 755
- `/usr/local/libexec/powermenu-helper`: root:mobile (0:501), 4750 (chown first, then chmod:
  chown clears the setuid bit on Linux)

It deletes `/Applications/PowerMenu.app` if the root has it. It writes nothing under `/var` (the
`var -> private/var` symlink stays).

Registration: nothing more is needed in a new root. The root has no LaunchServices database and
no `LastBuildInfo.plist`, so the first boot registers every app in `/Applications`. No staged-app
list: `/private/var/staged_system_apps` is the input of the data migration for removable Apple
apps, and root-finish.sh moves those into `/Applications` too. installd accepts an app in
`/Applications` as a system app if it has `platform-application` + `no-container` (or
`container-required`); the app has both. If the hook sees an app database (a root that booted
before), it prints a warning: then register on the phone (`phone-add-powermenu.sh --register-only`).
That root's database still lists `PowerMenu.app`; the script unregisters it.

## Install on the running phone (no new root)

`scripts/net/phone-add-powermenu.sh` (SSH root with `SSH=1`, writable root): copies the app, the
helper and `pmregister`, sets owners and modes, unregisters (`pmregister -u`) and deletes the old
`/Applications/PowerMenu.app`, then runs `pmregister /Applications/XNUtils.app`
(`LSApplicationWorkspace registerApplicationDictionary:`, as bergamota's `sweetuicache`) and
`powermenu-helper check`. `--register-only` registers only, `--remove` removes everything.
Not run yet.

## Not tested on the phone

1. The app starts (signature, entitlements, FrontBoard launch).
2. `mount` on the phone: the root must not have `nosuid`. The kernel has `CONFIG_SETUID` (build
   tree) and sets no `nosuid` on the root; there is no `/etc/fstab` in the root.
3. Started by the app (uid mobile): the helper gets euid 0 and the parent path check passes.
   Test with the buttons. Over SSH as root, `powermenu-helper check` tests only the kernel side.
4. Restart and Shut Down end in a reset / power off (0211 paths; `SYSTEM_OFF` is not tested yet).
5. Reboot to Bootloader with a 0213 kernel: `powermenu-helper check` prints
   `bootloader: kern.negroni_reboot_mode` (exit 0); the button ends in ABL fastboot
   (`fastboot devices` shows the phone). Then `fastboot reboot` (the next reason is normal again).
6. The first boot of a new root shows the icon. `pmregister` on a running phone.
