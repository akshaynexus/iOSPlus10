# Mi A3: a build must never look good when a part is missing

Owner request, 2026-11-01. Closes rows 18, 19 and 22 of `half-done-audit.md`. Row 20 (watchdogs) has a decision table here; nothing changed there.
Labels: [V] read in code or logs, or run here. [I] inference. Host test: `scripts/laurel/build-honest-test.sh` (fake tree, no sudo, no phone).

## 1. What the linker lines in the kernel build are

Every good kernel build log has 2 `clang++: error: linker command failed` lines, and make ends with `Error 2`. Both are normal [V build.log of the 20:56 build, lines 2228, 2948, 3635, 6487]:

| Step of `external/ios-sweet-linux/linux/build-with-iig.sh` | Log | Result |
| --- | --- | --- |
| Round 0: make -k, no iig output | line 2228 `linker command failed` | undefined DriverKit symbols |
| Round 1: stubs from the linker's list | line 2948 `linker command failed` | the next set of undefined symbols |
| Round 2: more stubs | line 3635 `built kernel at` | a kernel; every DriverKit wrapper answers unsupported |
| Round 3: wrappers with an `_Impl` forward to it, relink | line 6487 `built kernel at` | the real kernel |
| After each round: `check_all_exports` in `config/Makefile` | `make: *** Error 2` | always fails: "exported name not in import list" |

So: **the kernel was new, not stale.** The 2 lines are a harmless step. The make exit code cannot be the test, as audit row 19 proposed: it is never 0.

The audit's guess (a failed compile copies an old `BUILD/` kernel out as new) cannot happen as written: `apply-xnu.sh` deletes the whole xnu tree at the start of each run [V]. But 3 real holes were there:

1. `kernel-linux.sh` ended its build step with `|| true` and looked only for the file.
2. Round 3 can fail after round 2 worked. Then the round 2 kernel stays, and `built kernel at` is already in the log. `build-with-iig.sh` then exits 0 with a kernel whose DriverKit wrappers are all "unsupported". If a compile stops round 3, make prints no linker line at all.
3. `uefi-image.sh` took `out/laurel-kernel/out/kernel...4k` with no check. After a failed kernel run, that is the old kernel.

## 2. What now proves a kernel

`scripts/laurel/build-stamp.py` (called by `kernel-linux.sh`). After the build, in this order; each failure is one `kernel-linux: FAILED: ...` line and nothing is copied to `out/`:

- `build-with-iig.sh` exit 0 and a non-empty kernel file;
- the file's time is after this run's start;
- the file is newer than the last stub round (`OSObject.iig.cpp` is touched just before each make): this closes hole 2;
- the last `built kernel at` comes after the last `linker command failed`; the count of linker lines is printed;
- the file holds the exact text `LAUREL BUILD: <commit> <n> patches, series <hash>, <pages>`;
- the series of the patches this run copied equals the series in the repo now, and no patch is newer than the kernel (a patch edited during the run is named).

Series = sha256 of kind + name + contents of every topaz and laurel patch, stage script, Linux fix and `known-skips.txt`, first 16 hex digits. `<commit>` gets `-dirty` when `patches/laurel`, `scripts/*` or `userland` differ from HEAD. Only then the kernel gets `kernel.development.sweet.4k.stamp`.

`uefi-image.sh` refuses a kernel without a good stamp (`build-stamp.py kernel-check`: stamp present, sha256 right, embedded line present, series = patches in the repo now). `KERNEL=path` by hand needs only its own stamp, for an older kernel on purpose. The image gets `laurel-uefi-boot.img.stamp` and the ADT property `/chosen laurel-image-build`.

## 3. Boot lines (kernel patch 2912, `bsd/dev/laurel_build.c`)

```
LAUREL BUILD: 1a2b3c4d5e 293 patches, series c8d95a7d925628a6, 4k
LAUREL BUILD: image 1a2b3c4d5e 20261101T155328Z kernel-series c8d95a7d925628a6 fd 68fda27c: kernel series matches
LAUREL BUILD: root 1a2b3c4d5e 20261101T160000Z kernel-series c8d95a7d925628a6 features 12 installed 12 off 0 missing 0: kernel series matches
```

| Line | Source |
| --- | --- |
| first | generated header, written after the patches; the kernel-linux.sh check looks for this text |
| image | ADT, `mkadt.py --build-stamp`, from `uefi-image.sh` |
| root | first line of `/usr/share/laurel/root-manifest` |

`: KERNEL SERIES DIFFERS` = that part was built for another kernel. `no stamp: ...` = an old image or root. The first line also prints early in `bsd_init`, for a panic dump. All three print at the root mount and again 30 s later, because a capture can start late (boot 20:02: its first lines are from after the root mount). The patch only reads the ADT and one file. Kill switch: `laurelbuild=0`. The owner asked for this line, so it is not a probe under the CLAUDE.md rule.

Read it in `boot-test.sh`'s state lines, or `grep 'LAUREL BUILD' logs/...`. Compare with `kernel-linux: boot line:` and `uefi-image: boot line:` of the build.

## 4. Root: one table, no silent skip

`root.sh` now has this order: preflight, mkiosroot, tweaks, `root-features.sh`, table, fsck, input check, sparse image, seal.

- **Preflight** (`root-manifest.py preflight`): before anything slow. Each wanted feature's stage files exist and are newer than their sources, and the kernel stamp matches. It prints the inputs: `laurel-root: input script:scripts/laurel/root.sh <hash>`, one line each. A failure says the build command and the switch.
- **Table** (`root-manifest.py finish`): the state comes from the files in the root, not from what a step said. The reason comes from the step's log. Printed at the end, written to `/usr/share/laurel/root-manifest` (0644, plain text: first line, `feature<TAB>name<TAB>state<TAB>detail`, `input<TAB>name<TAB>hash`, `status`), and to the sidecar `$APPLE/laurel-ios16-root.manifest`.

```
laurel-root: feature     state      detail
laurel-root: gpu         installed  /topaz/lib/libOSMesa.8.dylib sha256 ...
laurel-root: hevc        off        HEVC=0
laurel-root: camera      missing    .../camera-imx586-qtech.isp; root-camera: WARNING: no colour tuning for the qtech module...
laurel-root: 9 installed, 1 off by their own switch, 1 missing: camera
```

| Feature | Switch | Stage | Must be in the root |
| --- | --- | --- | --- |
| gpu | `GPU=0` (new) | `out/laurel/gpu/root` | Mesa, libtopaz-gl, libtopaz-inject, real/backboardd, wrapper, zap firmware |
| metal | `METAL=0` | `out/metal/stage`, gate from the gpu stage | bundle, Turnip, clients, gate |
| hevc | `HEVC=0` | `out/laurel/hevc/HEVCH8.videodecoder` | the decoder |
| audio | `AUDIO=0` | `out/laurel/audio` | plug-in, VirtualAudio, D22 tunings, UI sounds, ringtones |
| bluetooth | `BT=0` | `out/laurel/bt` | stand-in, bluetoothd job |
| camera | `CAMERA=0` | `out/laurel/camera/{ios,lib}` | plug-in, a 586 sensor library, both lens libraries, both colour tunings, capture services |
| flashlight | `TORCH=0` | its own plug-in only with `CAMERA=0` | one owner |
| statusbar | `STATUSBAR=0` | none | provider key |
| notch | `NOTCH=0` or `STATUSBAR=0` | `out/laurel/notch/root` | dylib, start program, SpringBoard job |
| cell | `CELL=0`, or `NOTCH=0`, or `STATUSBAR=0` (`laurel-springboard` inserts it) | `out/laurel/cell/root` | dylib, SpringBoard job |
| brightness | `BRIGHTNESS=0` | none | `BKEnableALS` false |
| xnutils | `XNUTILS=0` | `out/laurel/xnutils/root` | app, helper (setuid, checked as root), pmregister |
| ssh | `SSH=0` | `out/ssh/ios` | dropbear, its job |

New rule: **SSH is wanted by default.** Before, a Linux root silently had no SSH, because nothing built `out/ssh/ios` [V: the main checkout had no `out/ssh`]. `build-all.sh` now builds it (passed on this host, 2026-11-01).

Exit 1 when a feature is missing: no sparse image, the sidecar says `status failed`. Only the feature's own `NAME=0` leaves it out. A new feature: one `feature` line in `root-features.sh`, one row in `FEATURES` of `root-manifest.py`, one stage line in `build-all.sh` (XNUtils came this way; a failed XNUtils build was a warning before).

`fsck ... || true` is gone: `root-fsck.sh` repairs, verifies, and accepts only the known `Volume header needs minor repair` note of Linux fsck_hfs. A dirty volume stops the run.

`build-all.sh` builds all of it (also GPU firmware when absent, audio, Bluetooth, SSH, the flashlight plug-in with `CAMERA=0`), fetches the toolchain first on a clean machine, names every failed stage, makes no boot image after a failure, then runs the same preflight. A failed HEVC build is now a failure.

## 5. Flash path and the race

`root-flash-test.sh`: stages (`preflight`) before the sudo prompt, then `root.sh`, then `root-manifest.py flash-check` before the phone is touched. flash-check requires: image exists, sidecar `status ok`, image size and time as sealed, no feature missing, every input hash (stages, scripts, patches) as when built, kernel stamp good, root and boot image for the same kernel series. It prints root, image, boot image and kernel. `STALE_OK=1` flashes anyway and lists the problems.

Direct `flash-root.sh` with the default image needs `status ok`; a named image has no check. An image from an older `root.sh` has no sidecar: flash-check refuses it unless `STALE_OK=1`. So does an image from `root-audio.sh --image`.

**The race** (a script changed during a run): `root.sh`, `build-all.sh` and `root-flash-test.sh` now have their body in `main()`, because the shell reads a function whole, so an edit of the running file does nothing. Scripts called later still read the new text, so `root.sh` hashes them at start and again before the sparse image; a change is `laurel-root: FAILED: script:... changed during this run` and no image. `build-all.sh` does the same for `patches/laurel`, `scripts/laurel`, `userland`. Do not edit scripts in the main checkout during a run: use a worktree.

Also fixed: `sudo` drops the environment, so `AUDIO=0 root-flash-test.sh` never reached `root.sh`. It now passes the switches (`root-manifest.py switches`).

## 6. Watchdogs that are off by default

Nothing was changed. Facts first, then what can be turned on. None of these can reset the phone: on this port nothing can.

| Name | What it turns off [V] | Why it is off | What a hang does now | Turn it on? |
| --- | --- | --- | --- | --- |
| `wdt=-1`, effect 1 | `interrupt_masked_debug_mode` = OFF (`osfmk/arm/arm_init.c:498-502`; default PANIC, `SCHED_HYGIENE_DEBUG` in `config/MASTER`): no panic when interrupts stay masked too long | came with the base ports; drivers here spin with interrupts masked [I] | A long masked section is only slow. A core stuck masked stays stuck, with no panic | **Not as PANIC** [I: a boot panic until each driver is fixed]. `interrupt-masked-debug-mode=1` (trace) needs `wdt=-1` gone; not tried, it only writes a trace |
| `wdt=-1`, effect 2 | `zone_exhausted_timeout` = -1 (`osfmk/kern/zalloc.c:9753-9755`; default `zet` 5000 ms): no panic when a zone stays full | same | A full zone blocks its callers forever: a silent freeze, no log | **Low risk: add `zet=5000`** to the boot-args. `wdt=-1` keeps effect 1 [V: the `zet` check at `zalloc.c:9753`]. A freeze from a full zone becomes a panic with a USB dump. It fires only when a zone stays full for 5 s. Not booted |
| `wdt_test=no_user_checkin` | `watchdogd` exits at start [V disasm 20H392, notes.md]: "detected testing boot-args to not run" | no reset path exists; a watchdogd crash panics (`_PanicOnCrash`, topaz 0040) | Nothing checks user space. A hung backboardd or launchd keeps the phone up with a frozen screen. `op10tool ctl` still answers (USB thread is in the kernel) | **No gain.** `SweetWatchdog.cpp` accepts every check-in and never fires, so running watchdogd can only add a panic risk |
| `launchd_disable_all_timeouts=1` | [V launchd 20H392, `metal.md` 380] extension check-in kill (5 s); SIGTERM to SIGKILL 3 s becomes 600 s; shutdown limit 30 s becomes none | device open + first pipelines take over 5 s at 300 MHz (boot 18:45: AegirPoster 10 starts, none finished) | A hung extension stays until jetsam or a reboot. A service that hangs in its exit delays a stop by up to 600 s, and a reboot from iOS has no limit. `op10tool ctl reboot` does not wait | **After a measure, not now.** Boot with `LAUNCHD_TIMEOUTS=1 scripts/laurel/uefi-image.sh` after 2890-2892 run. Pass = no `extension check-in timeout` line in a whole boot. 2890-2892 have not booted |
| `SweetWatchdog` (topaz 0040, 0045), `/arm-io/wdt no-pmu` | the IOWatchdog service arms nothing | no driver for the SM6125 APSS WDT (`hardware-map.md`: 0xf017000, not done) | **A kernel hang is forever**: no reset, no log. Hold Power + Vol Down | **The only real fix**: a driver with a kick thread, then a hang resets the phone. New work, risk of reset loops. Not in this change |

Still on, for reference: GPU watchdog 2155 (3 s), `FBLaunchWatchdogScale 3` (scaled, not off), haptics motor 1 s, charger NTC 30 s. A kernel panic goes to the USB panic hold and stays there; `op10tool ctl bootloader` takes it out.

The rule in CLAUDE.md ("a boot-arg only as a kill switch") is not met by `wdt=-1` and `launchd_disable_all_timeouts=1`, or by `ipa=0` (audit row 4). They are recorded here as known exceptions, each with its exit.

Recommendation: add `zet=5000` in the next boot image after one normal boot of the 2890-2892 kernel, so a new panic has one cause to look at. The owner decides.

## 7. Limits

- Real run, 2026-11-01: `build-all.sh` passed with all stages (commit 66d75a4f47). An earlier run stopped at the Metal stage, with no new boot image, as it should.
- `sudo root.sh` itself was not run. The dry run covers the same steps on a copy with real stages, except mkiosroot, fsck and img2simg (`scripts/laurel/root-dry-run.sh`; empty folders stand in for the UI sounds, ringtones and tunings).
- No boot: the 3 boot lines have not been seen on the phone. The kernel compiles and holds the first line; the ADT holds the second.
- The kernel series does not cover the compiler, the SDK or `kernel-linux.sh` itself.
- A stage is judged by its files and times. A stage script that exits 0 with an old file newer than its sources passes.
- Mu (FD): `build-all.sh` needs the file; it does not check it against `patches/laurel/mu`. The FD's hash is in the image line.
