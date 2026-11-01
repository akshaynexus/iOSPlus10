# Mi A3: XNUtils, the system app with live stats (2026-11-01)

Owner: "Build and install XNUtils as a system app, and extend it to show more info and stats." Branch `t3/laurel-xnutils`. Built, host-tested, dry-run on a copy, **NOT RUN ON THE PHONE**.
Labels: [V] read in source, a binary or a log; [H] host test; [I] inference; [U] unknown.

## 1. What it is

| Part | Place on the phone | Source |
| --- | --- | --- |
| App (UIKit, no Metal) | `/Applications/XNUtils.app`, `dev.iosplus10.xnutils` | `userland/laurel/xnutils/{main.m,list.m,vc.h,stream.m,Info.plist,mkicon.py}` |
| Helper, setuid root | `/usr/local/libexec/powermenu-helper`, root:mobile 4750 | `helper*.c`, `collect*.c`, `report*.c` there |
| Register tool | `/usr/local/bin/pmregister` | `userland/rebootapp/pmregister.m` |
| Kernel data | `kern.laurel_stats` | `patches/laurel/xnu/2911-laurel-stats.patch` |
| Root step | `XNUTILS=0` skips | `scripts/laurel/root-xnutils.sh` |
| Build | `build-all.sh` runs it | `scripts/laurel/xnutils-build.sh` |
| Host test | | `scripts/laurel/xnutils-test.sh` |

The OnePlus version stays as it is in `userland/rebootapp` (macOS + Xcode, negroni boot-arg and Adreno 730 text, other files).

## 2. Functions checked for this phone

| Function | On negroni | Here | Evidence |
| --- | --- | --- | --- |
| Restart | `reboot(RB_AUTOBOOT)` | same; kernel 2003 | [V] `SweetPlatformExpert.cpp`: `kPERestartCPU`. Not run |
| Shut down | `reboot(RB_HALT)` | same; kernel 2003 | [V] `kPEHaltCPU`. Not run |
| Bootloader | `kern.negroni_reboot_mode` | `kern.laurel_reboot_mode` = `bootloader`, read back, restart (2018: IMEM + PON reason) | [V] `laurel_reboot.c`. Not run |
| Restart UI | kill `/usr/libexec/backboardd` | **also `/usr/libexec/real/backboardd`**: the wrapper execs it. The old check found no process here | [V] `root-add-gpu.sh`, `bbd_wrap.c` |
| Metal switch | `*`, probes, off | **Auto**, All, Probes, Off. See below | [V] `metal_gate.c`, `root-add-metal.sh`; [H] |
| GL switch | `/var/db/negronigl/clients` | **new file** `/private/var/db/laurelgl/off`, read by `bbd_wrap.c` at each start of backboardd. The negroni file has no reader here | [V] `bbd_wrap.c` had boot-args only; [H] the helper's side |
| GL for apps, glFinish | NegroniGL files | **removed**: no GL for apps on this port (`metal.md` 8) | [V] |
| Metal device card | `MTLCreateSystemDefaultDevice` | **removed**: the app must not need Metal. State comes from the kernel and files | owner |
| Layout | 34 pt title, fixed margins, no launch screen | table with no fixed width, safe area from UIKit, `UILaunchScreen` (else iOS gives the app a small 320 x 480 frame [I]) | `rtc-statusbar.md`: 360 x 780 pt, 38 + 29 pt |

Metal modes: `auto` writes the gate's mark and the probes to `clients` and `clients.local`, removes `gate` and `off`; the gate decides at the next boot (`m2vtest`). `all` = own list `* -backboardd`, the gate leaves it alone. `probes` = own list. `off` = the off file.
If t3/laurel-mediaserverd-metal changes the gate's wide list, change `XT_METAL_WIDE` in `collect.h` with it.

Registration [V negroni, I here]: `root.sh` makes a new root: no LaunchServices store, no `LastBuildInfo.plist`, so lsd's first seed registers every app in `/Applications` with no Setup step, as for the 32 apps of `root-system-features.py`. Owner saw this path work on negroni (notes "XNUtils rename", the phone showed the app of the root).

Without Metal [V by `xnutils-build.sh`]: neither the app nor the helper links Metal or OpenGLES. No blur, no bar, no symbol image. Drawing is UILabel + UITableView, composed by backboardd. The build stops on a Metal link.

## 3. Data

Nearly all values exist only as console lines, and the console ring (4 MiB, `sweet_ufs.c`) holds them already. So 2911 adds no hook to the print path:

- `bsd/dev/laurel_stats.c`: the read-only sysctl. It takes the new ring bytes at each read, and in the log thread that wakes every 10 s anyway, so boot lines stay after the ring wraps.
- `bsd/dev/laurel_stats_core.h` + `laurel_stats_lines.h`: the table, plain C, the host test compiles this same text. 112 state slots (`LAUREL X[/sub]`: last line wins, never pushed out), 128 line slots (tag + first 3 words without a digit; last line + count; oldest pushed out), 32 crash slots, 40 device slots (`NMTL[.. name]: device`, `RedwoodGPU: client`). 112 KiB of BSS [H sizeof], a read allocates 119 KiB for its time.
- 14 or more digits in a row become `#`: an ICCID, IMSI or IMEI cannot leave the table.
- Live values from variables the drivers keep: `laurel_thermal_stats`, `laurel_gpu_dcvs_stats`, `laurel_wifi_stats`. No register read, no new poll, no new thread.
- Kill switch `laurelstats=0`; then `off: boot-arg laurelstats=0`, the system goes on. The sysctl is readable by every user: it holds what the USB log holds (the Bluetooth address, for example), not more.

Cost [I, not measured]: scan = new bytes only. Log thread idle = one mutex + a compare every 10 s. First read after boot = at most 4 MiB of bytes if the log thread never ran.

The helper's `stream` verb runs only while the app is visible: one report for each byte the app writes every 2 s. It ends when the app closes the pipe (hidden, or killed). No timer in the helper. Per report: one sysctl, about 100 `proc_pidinfo`, one registry read, a few files. [I] under 1 % of one core; read `Top by CPU now` and `LAUREL CPU TOP`.

| Section | Rows | Source |
| --- | --- | --- |
| Kernel | version, boot-args, uptime, console read | sysctl |
| GPU | busy, measured core, level now, level time, submissions, work per submission, pool free, SMMU, fault count, host pages, DDR, watchdog | `kern.laurel_gpu`, `RedwoodGPU:` 5 s lines, `LAUREL GPU CLOCK` minute line, `gpu.level_mhz` |
| Metal | state, gate + reason, mode, both lists, gate record, strikes, shader cache files + KiB; each process with a device: running or exited, opens, pipelines + cache hits | `LAUREL METAL*`, files, `NMTL[...]` |
| GL | state, switch file, FPS, frame time, redwood-gl frame line | `LAUREL BBD`, `SWEET FPS`, `redwood-gl: frame` |
| Display | panel level, backlight, power mode, wake count, owner refusals, canvas, handoff | `LAUREL BACKLIGHT/PANEL/FB *` |
| CPU | per cluster MHz + busy + cap, hold, per core %, minute tables, top tasks now, kernel top line | `laurel_thermal_stats`, `host_processor_info`, `proc_pidinfo` |
| Thermal | CPU + GPU sensor, last line | same |
| Memory | free, active, inactive, wired, compressor, swap, jetsam pressure + level, wired guard, top by memory | `host_statistics64`, `vm.swapusage`, `kern.memorystatus_*` |
| Battery | %, mA, mV, C, charging, cycles, charger, JEITA zone | registry of `IOPMPowerSource` (SweetBattery's 10 s sample), `LAUREL CHARGER: on: SMB5 usbin` |
| Wi-Fi | band, channel, width, mode, rx + tx rate, RSSI, bars, throughput now, frames, drops by reason, scans, scan limit, band choice, path | `laurel_wifi_stats`, `getifaddrs` |
| Bluetooth | chip, firmware, address, iOS side | `LAUREL BT` |
| Cellular | SIM 1, SIM 2, mode, radio, data, IPA | `kern.laurel_cell/ipa`, `LAUREL CELL` |
| Camera | state, last stream, frames + fps, exposure, VFE errors, session, focus, memory | `kern.laurel_camera*`, `LAUREL CAMERA` |
| Audio, RTC, Storage | ADSP state, frames in; time + RTC line; root free + SSD line | lines, `statfs` |
| Crashes | per process: count, last signal, reason | `CRASH` lines |
| All LAUREL features | every state line, off first | S slots |

A value nobody has is `not available`. A line's age shows after it (`12 s ago`); a value read now has no age. A state with no line is grey (`none`).

## 4. Build results

- `xnutils-build.sh` [V]: no compiler warning, 0 instructions newer than ARMv8.0 in all 3 binaries, thin arm64, minos 16.0, XML entitlements blob present, no Metal or GL link.
- Kernel [V]: see the numbers in `docs/plan.md`; 0 LSE, no warning in the changed files.
- `xnutils-test.sh` [H, ASan + UBSan]: the patch's table + the report on `test/sample.log`, and on a real log with `scripts/laurel/xnutils-test.sh logs/laurel-boot-2002.txt`: crash table = system-features.md 2.4 (syncdefaultsd 12, webbookmarksd 6, mediaserverd 6, driverkitd 1, PosterBoard 1, backboardd 1); pool, FPS, devices, panel level read from real lines. Input cut at 7 bytes gives the same report. Long digit run masked. The helper's file verbs on a folder in a user namespace: all Metal modes, `gl`, `strikes-clear`, bad verb 2, not root 5, no sysctl 3.
- `root-dry-run.sh` [V]: on a copy of the stock 20H392 files: jobs + apps PASS, XNUtils PASS. As the user, so no owners and no setuid bit; `root.sh` does these as root.

## 5. Not proven until the phone runs it

1. The app starts and shows on the home screen after the first seed (the icon too).
2. The setuid helper gets euid 0 from the app, and its parent check passes. Root has no `nosuid` [V negroni README], not seen here.
3. The registry read, `proc_pidinfo`, `host_processor_info`, and the kernel's AMFI stand-in with a setuid + entitled binary.
4. Restart, shut down, bootloader through the helper. USB `reboot` works [V]; this path is new.
5. Layout: row heights, safe area, the segmented control's width at 360 pt.
6. Kernel 2911 under real load: lines cut by another CPU's output are possible; a state line can read oddly until the next one. Every parse failure gives `not available`.
7. Long IOLog lines stop at 255 bytes [V boot 19:34]; a row whose label sits after that place stays `not available`. Wi-Fi does not need the line: it reads the variables.
8. `Compressor`: the row is `compressor_page_count` pages; `In the compressor` is uncompressed bytes at their source [V header].

## 6. Test steps

1. Build: `scripts/laurel/build-all.sh`; root: `sudo scripts/laurel/root.sh`, log line `root-xnutils: on: ...`; flash needs the owner: `scripts/laurel/root-flash-test.sh`. The boot image holds kernel 2911: `uefi-image.sh`.
   Running phone over SSH, no new root (kernel 2911 still needs a new boot image): `POWERMENU_OUT=out/laurel/xnutils/flat SSH_PHONE=scripts/laurel/phone-ssh.sh scripts/net/phone-add-powermenu.sh`.
2. Boot. Log: `LAUREL STATS: on: ...`, `sysctl -n kern.laurel_stats | head` over SSH gives `v=1`.
3. Home screen: XNUtils icon, with no Setup step. Open it. Expect the title, switches, actions, a status line `Live, every 2 s`, then 18 lines with a coloured dot.
4. SSH: `/usr/local/libexec/powermenu-helper report`: the same content as text. `powermenu-helper check`: `caller ok; bootloader: kern.laurel_reboot_mode`.
5. Open each section. Compare: GPU busy with `RedwoodGPU:` in `make usblog`, RSSI with Settings, battery % with the status bar, `syncdefaultsd` etc. in Crashes.
6. Press Home for 1 min. In the log, `LAUREL CPU TOP` must not list `powermenu-helper`; `ps ax` over SSH must not show it. Back in the app: it is there again.
7. Metal: choose Off, Restart UI: `Metal` turns red with `the off file exists`; the app still draws (the owner's rule). Then Auto + reboot: `LAUREL METAL CLIENTS: on: ...`.
8. GL: switch off, Restart UI: `LAUREL BBD: off: ... exists (the GL switch of XNUtils)`, software renderer. Switch on, Restart UI.
9. Copy report: paste it into Notes. Share report: the sheet opens.
10. Actions, one each: Restart; Reboot to bootloader (`fastboot devices`, then `fastboot reboot`); Shut down.

## 7. Expected lines

```text
LAUREL STATS: on: kern.laurel_stats reads the console ring (112 state + 128 line slots), no work in the drivers
exec XNUtils                                 (at each start of the app)
LAUREL BBD: off: /private/var/db/laurelgl/off exists (the GL switch of XNUtils): no GL loader, software renderer     (only with the switch off)
```

Root build: `root-xnutils: new root: the first LaunchServices seed registers /Applications/XNUtils.app`, `root-xnutils: on: ...`.
Fallbacks: `laurelstats=0` (kernel), `XNUTILS=0` (root). Remove on a phone: `scripts/net/phone-add-powermenu.sh --remove` with the environment of step 1.
