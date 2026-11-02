# Mi A3 iOS 26 first boot: what to read when the panel is black

Date: 2026-11-02. **Nothing here has run on the phone.** Labels: [V] measured here (code, disassembly or a host test), [I] inference, [U] unknown. Lines marked "iOS 16" were seen on this phone on iOS 16 (`logs/usblog-20261101-165828.txt`); on iOS 26 they are expected, not seen.

23F84 has no GL path. If the Metal stack fails, there is no picture. The GPU firmware is on the root since `ios26-parity.md` (hook `gpu-firmware`); before it the kernel said `LAUREL GPU: off` with no firmware. So every diagnosis below works with no screen.

## 1. One command

```sh
make usblog                                      # once; it asks for sudo: tmux attach -t usblog (Ctrl-b d). Gives the host 192.168.7.1, writes logs/usblog-*.txt
scripts/bg.sh ios26-diag python3 -I scripts/laurel/ios26-diag.py   # or: make laurel-ios26-diag
scripts/bg.sh -s ios26-diag 40                   # the state; files in logs/ios26-diag-<time>/
```

First line of the output, for example: `STATE: kernel up, launchd up, SSH up, backboardd loop (7 starts), first Metal error: LAUREL METAL26: off: ...`. The tool only reads: no reboot, no write on the phone. Each step has its own time limit, so a dead phone does not hang it. `--from DIR` reads a folder again.

| File | Source | Needs |
|---|---|---|
| `state.txt` | the summary, one line per stage | |
| `kstate.txt`, `kps.txt`, `ktime.txt` | `ctl state`, `ctl ps`, `ctl time` | USB, kernel; no launchd, no SSH |
| `kernel-log.txt` | `ctl logall`: all of the 4 MiB console ring | USB, kernel. With `usblog` running, it takes the new part of its file |
| `ssh-ps.txt`, `ssh-mount.txt`, `ssh-net.txt` | processes, mounts, `ue0` | SSH |
| `ssh-crashes.txt`, `ssh-launchd.txt` | crash folders, launchd logs, `launchd_cache_loader.log` | SSH |
| `ssh-metal.txt`, `ssh-stats.txt`, `ssh-root.txt` | `/private/var/db/negronimetal`, `kern.laurel_stats`, the audit of the root | SSH |

By hand, with no tool of ours on the root: `out/bin/op10tool ctl ping | state | ps | log | logall | time | bootloader | reboot`. After a panic: `ping`, `log`, `logall`, `reboot`, `bootloader`, `recovery`, `poweroff` still answer.

## 2. Why SSH must start, in code [V code, not run]

### Launchd takes the job

1. Boot-arg `launchd_unsecure_cache=1` is in `scripts/laurel/uefi-image.sh`, which `ios26-image.sh` uses. In 23F84, `/usr/libexec/launchd_cache_loader` is a boot task with `RequireSuccess`. It tests that argument at 0x100000b48 and jumps past `SecStaticCodeCreateWithPath` and the trust check ("cdhash: %s is not in trust cache") to the send of the file. It prints `Using unsecure cache: ...` to `/var/log/com.apple.xpc.launchd/launchd_cache_loader.log`. So `launchd.plist.sig` stops nothing with this boot-arg. **Without the boot-arg the root cannot boot**: the signature does not match, and the kernel has no trust caches. This closes K10 of `ios26-metal.md` for a job in the cache.
2. Job place: key `/System/Library/LaunchDaemons/<label>.plist` under `LaunchDaemons`, the same form as the 691 jobs of 23F84. `/System/Library/LaunchDaemons` is in the `Bootstrap Paths` of the plist inside launchd.
3. New in the job for 23F84: `POSIXSpawnType Interactive` (as `com.apple.configd`), `MinimalBootProfile` true (the key configd and lockdownd have), `EnablePressuredExit` false. Log: `StandardErrorPath /dev/console`: no file in `/private/var`, and dropbear's lines go into the USB log.
4. Launchd has a test "unexpected exec of non-platform binary" at 0x10002f4c8 (`tbnz w8, #26`, `CS_PLATFORM_BINARY` of `csops`), then an abort path. So a job outside the root file system is dangerous. Ours is on the root: see K9.

### K9: the kernel takes an ad hoc file in a platform process

Path of `/usr/local/bin/dropbear` (a link to `dropbearmulti`), xnu-12377 with our series:

| Step | Code | Result for dropbearmulti |
|---|---|---|
| Blob shape | `ubc_subr.c:369`: page shift 12, `PAGE_SHIFT` (12), or 14 with `TOPAZ_4K` | SHA-256, 4096 bytes [V file] |
| Policy | `sweet_amfi_vnode_check_signature` (`sweet_amfi.c:291`) is the only `mpo_vnode_check_signature`. No hash, signer or path check: `CS_SIGNED`, and with `MNT_ROOTFS` also `CS_PLATFORM_BINARY` | Accepted; the iOS root is the root file system |
| Blob | `ubc_cs_blob_add`: `csb_platform_binary = 1` when the flag is set; `verify_code_signature_monitor` is under `CODE_SIGNING_MONITOR`, off | Platform |
| Process | `mach_loader.c:3916` copies the flags; `kern_proc.c:3789` gives `CS_PLATFORM_BINARY` to `csops` | Launchd's test passes |
| Exec gate | `kern_exec.c`: an iOS binary with no spawn platform passes with `unentitled_ios_sim_launch=1`. It prints `exec NAME` | In the boot-args; line seen on iOS 16 as `exec dropbearmulti` |
| Library rule | `F_CHECK_LV` calls `mac_file_check_library_validation`; no policy here has that hook | Allowed. dropbearmulti loads only libSystem from the cache |
| dyld | `__mac_syscall("AMFI", 0x5a)`: allow all | Same answer for every process |

So K9 is **no longer a question of the kernel for these files** [V code]. Every lowered file of the root takes the same path as ours. Differences from the lowered launchd, read from the files [V]:

| | lowered launchd | dropbearmulti |
|---|---|---|
| CodeDirectory flags | 0x2 (`CS_ADHOC`) | 0x0 (`ldid`). The kernel code above does not read it. iOS 16: this file ran |
| CMS slot 0x10000 | empty blob | none |
| Fixups | chained, minos 26.5 | `LC_DYLD_INFO_ONLY`, minos 16.0, sdk 16.5. **dyld 23F84 with opcode fixups: [U], read neither in dyld nor run** |
| Imports | | `ios26-injected-check.py`: 8 of 8 tools, every library and every symbol in the 23F84 cache, 0 instructions newer than ARMv8.0 |

Run it again: `scripts/bg.sh ios26-debug-build scripts/laurel/ios26-debug-build.sh`.

### What SSH needs, and what it does not need

- Needs: kernel, root mount, launchd, and each launchd boot task with `RequireSuccess` [V plist inside launchd 23F84]: `dirs_cleaner`, `mount -P 1`, `mount -P 2`, `cc_fips_test`, `fsck -qL`, `launchd_cache_loader`, `init_data_protection`, `tzinit`. **A failure there ends the boot before any daemon** ("Boot task failed", "Panicking in 3 seconds"): then only the USB command server and the panic hold speak. So SSH cannot help with that stage; `ctl state` can (`bad ... mount[5] rv=0x100`).
- Does not need: SpringBoard, backboardd, Metal, GPU, the keybag (`keybag` is a boot task with `AllowCrash`, no `RequireSuccess`, and dropbear reads no protected file), configd for the address (the kernel sets `192.168.7.2` at the attach of `ue0`), a `/private/var` set up by UI (the key, the home folder and the job are in the image; `dirs_cleaner` cleans only `/tmp`, `/var/run`, `/var/mobile/tmp`, `/var/boot`).
- If configd of 23F84 takes the address away: [U]. The service in `preferences.plist` gives the same address, as on iOS 16. Dropbear exits with no address, and launchd starts it again after 10 s.

### Fallback when launchd refuses

Kernel patch 2951: the USB command server answers `state` and `ps` from a table the exec line and `proc_prepareexit` feed. It needs no process. At 300 s after `exec launchd` with no dropbear: `LAUREL SSH: off: launchd did not start dropbear in 300 s (N execs, M bad exits): op10tool ctl state`. Kill switch `laurelstate=0`. A failure turns off only this table.

## 3. Security

- `dropbear -p 192.168.7.2:22`: bound to the USB address only. **No listener on Wi-Fi.** The self-test fails on any other form. The kernel command server takes frames from `192.168.7.1` on the USB link only.
- Login: the repo key `out/ssh/phone_ed25519` and the host user's public key, **and** the stock iOS password `alpine`: 23F84's `master.passwd` has the same hash as iOS 16 (`/smx7MYTQIi2M`) [V file]. On iOS 16 a root with a key has no password login (`-s`); this root keeps both, because a first boot needs a second way in (`SSH_PASSWORD_AUTH=1`). `SSH_PASSWORD_AUTH=0` at the root build drops it after the first boots.
- No new secret in git. Host key: `out/ssh/hostkeys/dropbear_ed25519_host_key`, made once on the host at the first root build, git-ignored, in the image (never in git). No host `dropbearkey`: `dropbear -R` makes it on the phone at the first connection. `out/ssh/known_hosts` gets the public key. The root image holds a private host key: do not share the image.

## 4. Expected lines, by stage

Read `logs/usblog-*.txt`, or `kernel-log.txt` of the tool. The first 3 rows are on the panel only if USB is not up yet.

| Stage | Expected | If it stops here | Do |
|---|---|---|---|
| 0 Firmware | Panel: UniXNU menu (3 s), `DARWINBOOT: ARM64 va=0xfffffff007004000 pa=0xe1004000`. Host: no USB device | No menu: Mu, the boot image | Photo of the panel. Power + VolDown for fastboot |
| 1 Early kernel | White band; `Darwin Kernel Version 25.5.0`; `LAUREL BUILD: <commit> <n> patches, series <hex>, ios26_4k`; `LAUREL CPU: boot cpu mpidr=0x100`; `LAUREL RAM: on` | `start.s`, 4K tables, `arm_vm_init` (`ios26-kernel.md` section 7) | Photo. Only the panel speaks |
| 2 USB | `LAUREL USB: on: ECM ue0 192.168.7.2, ...`; `LAUREL USB: timer service: on, first tick after N us`; host: interface MAC `02:00:5e:77:ee:01` | `LAUREL USB: off: <reason>`; `timer service: NO tick` (table in `usb-debug.md`) | `op10tool ctl ping` -> `pong`. `ctl state` -> `state early: no ue0 yet` |
| 3 Kernel start | `SWEET PRNG: HMAC-SHA256 registered`; `SWEET AMFI: built-in interface registered`; `SWEET pthread: libpthread-539.100.4 registered`; `SWEET: trust caches unavailable`; `bsd_init: calling ...`; `LAUREL BUILD: image ...`, `LAUREL BUILD: root ... features 3 installed ...: kernel series matches` | The last `bsd_init:` or `kernel_bootstrap_thread:` line names the step. `KERNEL SERIES DIFFERS`: root built for another kernel | `ctl logall` |
| 4 Root and launchd | `SWEET HFS:`, `LAUREL DUALBOOT:` (`dual-boot.md`); `load_init_program: attempting to load /sbin/launchd`; `exec launchd`; `LAUREL STATE: on: ...`; `libignition: ...`; `<Notice>: boot-args = ...` | No `exec launchd`: root mount, or dyld (`CRASH launchd`, then a panic) | `ctl state`: `launchd=no`, `root ...` |
| 5 Boot tasks | `[System Event] ... [Subsystem: launchd] [Event: mount-phase-1] Doing boot task`, also `data-protection`, `mount-phase-2`, `keybag`, ...; `exec mount`, `exec launchd_cache_loader`; `Early boot complete. Continuing system boot.` [string V] | `Boot task failed: ...`, `Panicking in 3 seconds`; or the last `Doing boot task` with no next line | `ctl state`: the `bad` lines |
| 6 Daemons, SSH | `exec configd`, `exec logd`, `exec dropbearmulti`; **`LAUREL SSH: on: dropbear pid P, T s after launchd, on the USB address only`** (iOS 16: 4 s); `LAUREL NET: on: ...` | `LAUREL SSH: off: ...` at 300 s | `scripts/laurel/phone-ssh.sh wait 300`, then `phone-ssh.sh 'ps ax'` |
| 6b Features | `LAUREL NOTCH: on`, `LAUREL CELLBAR: on`, `LAUREL RINGER: on` (syslog and `/var/tmp/laurel-notch.log`), `LAUREL FLASHLIGHT: on`, `exec bluetoothd`, `exec laurel-celld` | One `off` line per feature; each stops only itself (`ios26-parity.md` section 3) | The audit of the root: `ssh-root.txt` |
| 7 Compositor | `exec backboardd`; `NMTL[<pid> backboardd]: ...`; `LAUREL METAL26: on: Metal device ... for the compositor`; `LAUREL METAL26: first frame on a screen surface (...)`; `LAUREL FB CANVAS: first frame on the panel: ...`; `LAUREL METAL26: screen: N of 64 samples lit ...`; `LAUREL FRAME: ...`; `exec SpringBoard` | See section 5 | The tool. `SWEET FPS` prints only with GL: do not wait for it |
| Each stage | `exec NAME` per process; `CRASH name[pid] sig N ...` per crash; from 90 s, `SMP name[pid] ...` for SpringBoard and backboardd every 120 s | | `scripts/debug/crash-symbolize.sh`, `smp-symbolize.sh`: set `DSC` to `~/op10-apple/ios26/23F84-n104ap/lowered/dyld_shared_cache_arm64e` (their default is the iOS 16 cache) |

## 5. The panel is black

Run section 1. Then:

| `state.txt` says | Meaning | Next read |
|---|---|---|
| `no USB device` | Kernel did not reach its USB start, or the phone runs Android, or the cable | Panel photo; stages 0 to 2. No log can help: the boot did not get there |
| `host address missing` | USB is up | `make usblog`; run the tool again |
| `the kernel does not answer` | Interface up, `ud_thread` stuck | `kernel-log.txt` of an earlier run, `logs/usblog-*.txt`, then `log-pull.sh` from Android |
| `kernel PANIC` | Panic hold: text and the log over USB | `panic` row and `kernel-log.txt`; `scripts/debug/panic-symbolize.sh` with the `.unstripped` kernel |
| `no launchd` | Root mount or the first exec | `kernel-log.txt` near `load_init_program` |
| `boot task failed`, `boot tasks stop after X` | launchd stage: no daemon runs | `kstate.txt` `bad` lines. No SSH here |
| `no SSH: launchd did not start dropbear` | Job not read, or launchd still in boot tasks | `kstate.txt` `exec` lines; `LAUREL SSH: off`. `launchd_cache_loader.log` is on the root: read it from Android only after an unmount plan; the kernel lines are what you have now |
| `no SSH: dropbear n=9 x=9 rv=...` | Exec works, dropbear exits | dropbear's lines are in the USB log (stderr on the console); `rv` is the wait status; `CRASH dropbear...` for dyld |
| `SSH up, backboardd not started` | A job before it holds it, or launchd's event | `ssh-ps.txt`, `ssh-launchd.txt` |
| `backboardd loop`, `first Metal error: ...` | The compositor fails and restarts: the expected kind of first failure | `ssh-metal.txt` (`metal.log`, `strikes/`), `crashes` row, `CRASH backboardd`. `ios26-metal.md` section 7 |
| `backboardd running`, no frame on the panel | Device up, no frame: `LAUREL METAL26: ...: no frame on a screen surface` | `ssh-metal.txt`; `LAUREL GPU:` lines; `LAUREL GPU WATCHDOG` |
| `first frame on the panel`, still black | Frame reached the panel: `LAUREL METAL26: screen: 0 of 64 samples lit`, or backlight | `LAUREL BACKLIGHT:`, `LAUREL PANEL:` lines |

Previous boot, when this boot says nothing: from Android, `scripts/laurel/log-pull.sh logs/laurel-pull-$(date +%H%M)` reads the last 1025 blocks of `iosroot` (`SWEETLOG`, needs `ufsrw=1`; the boot-args have it), read-only over adb with root. **Read it before the next iOS boot**: that boot overwrites it within seconds. The layout is `scripts/lib/laurel-layout.sh` and patch 2950 (`LDB_LOG_BLOCKS`); nothing here edits them.

## 6. Back to Android

1. Boot menu (`boot-menu.md`), once a writable menu image is on the phone. The first read-only image has no Android entry: use the next way.
2. Else: `out/bin/op10tool ctl bootloader` (also from a panic), or Power + VolDown; then `fastboot set_active a`, `fastboot reboot`. Exception: after a manual Android update do not use `set_active a` (`dual-boot.md`).
3. With no computer: reboot iOS until the 7 retries of slot b end.

## 7. Root

```sh
scripts/bg.sh ios26-debug-build scripts/laurel/ios26-debug-build.sh    # ksysctl + injected check of all tools (some minutes)
scripts/bg.sh ios26-parity scripts/laurel/ios26-parity-build.sh        # audio, Bluetooth, status bar, cell, flashlight, HEVC, XNUtils + their check (docs/laurel_sprout/ios26-parity.md)
scripts/bg.sh ios26-metal scripts/laurel/ios26-metal-build.sh          # the Metal stage; if absent the root has no compositor, SSH stays
scripts/bg.sh ios26-kernel scripts/laurel/kernel-ios26-linux.sh        # stamp for LAUREL BUILD: root
scripts/bg.sh ios26-root env FORCE=1 scripts/laurel/ios26-root.sh
scripts/bg.sh -s ios26-root 8                                           # read the lines "debug-ios26" and "metal26"
```

The script prints `applied   debug-ios26: ...` near its end. `off debug-ios26: ...`: this root has no SSH. `DEBUG26=0`: the kill switch at build time.

Hook: `debug()` of `ios26-root-spec.py` runs `scripts/laurel/root-debug-ios26.sh` on a stage, before `air()` and `metal()`, with one audit line per item in `report.txt` and `/usr/share/laurel/ios26-root-audit.txt`. `python3 -I scripts/laurel/ios26-root-spec.py --self-test` checks it.

## 8. The crash guards of the start programs, at step 10 of `dual-boot.md`

`laurel-springboard` (`userland/laurel/notch/sb_wrap.c`) and `laurel-cameracaptured` (`userland/laurel/flashlight/cc_wrap.c`) insert our libraries and exec Apple's program. Each start counts in a state file in `/var/tmp`.

| You see | Meaning |
|---|---|
| `LAUREL FLASHLIGHT: off: no crash guard: cannot write /var/tmp/laurel-cc.state` in the USB log, and `LAUREL NOTCH: off: no crash guard: /var/tmp/laurel-sb.state cannot be written: no dylib in this start` in syslog | Expected on the read-only first boot: no writable `/private/var`. With no state file the guard cannot count, so this start has no library, and Apple's program runs. The other hooks stop in the same way. No `off` line of the guard on a writable boot: the file was written |
| `LAUREL NOTCH: off: SpringBoard exited N times within 30 s` | The guard: 3 starts in 30 s of the one before. No library for the rest of this boot |
| `LAUREL NOTCH: ... inserted` again and again, `CRASH SpringBoard[pid]`, over 30 s apart | **The limit of the guard:** a start over 30 s after the one before counts as new. A library that crashes after 30 s is not counted, so launchd keeps restarting it. No fix: a counter of all starts in a boot would also count each respring. To stop it: `notch=0`, `cell=0`, `ringer=0` in the boot-args, or `torch=0`, or `/var/db/laurel/flashlight-off` |

`/dev/console` as user mobile is not a defect: mode 0622 [V xnu `bsd/miscfs/devfs/devfs_vfsops.c:116`]; `NMTL[<pid> backboardd]` lines came that way in `logs/usblog-20261101-165828.txt` [V iOS 16]. `LAUREL NOTCH` lines do not go to the console: syslog and `/var/tmp/laurel-notch.log` only, so on the read-only boot, with no syslogd, they may show nowhere [I]. The kernel's `exec SpringBoard` and `CRASH` lines still show.

## 9. dyld and the setuid helper

Before patch 2957 the kernel answered dyld's AMFI question (`__mac_syscall("AMFI", 0x5a)`) with 0xff for every process, and [V 23F84 `/usr/lib/dyld`: `svc` number 381 (`__mac_syscall`) is there, 327 (`issetugid`) is not] dyld has no other test. So a mobile process could start `powermenu-helper` (root:mobile 4750) with `DYLD_INSERT_LIBRARIES` and run its own code as root before `main()`, so before `caller_allowed()`. **Now: 0 for a process with P_SUGID** (patch 2957, both kernels): dyld then ignores `DYLD_*` and `@` paths there. Other processes keep 0xff: the wrappers above and the GPU's backboardd need it, and they are not setuid. [V] The helper has no `@` path in its load commands. Not run on the phone.

The helper reads files in `/private/var/db/negronimetal/stack`, where backboardd (mobile) writes. The folder is root's, mode 1777. Each read goes through `open_planted()`: no symlink, no FIFO or device, one link only, owner root or mobile, all checked on the open file.
