# Mi A3: half-done audit (2026-11-01)

Read-only review of `origin/laurel-sprout` at baf7fcb. No code or patch changed. No phone used.
Evidence: `[V]` = read in code or in a phone log. `[I]` = inference. Log names: `boot 20:02` = `logs/laurel-boot-2002.txt`
(the newest boot), `usblog` = `logs/usblog-20261101-165828.txt`. Lines like `2892:164` are lines of the patch file `patches/laurel/xnu/2892-*.patch`.
`0901` = `external/ios-topaz/xnu/patches/0901-topaz-0108-*.patch`.

## 1. Overall state

The owner's feeling is correct. The base system and the GL compositor are real. Most other features stop at "the chip answers".
A `LAUREL X: on` line usually proves that a chip or a firmware answered. It does not prove that the user feature works.

**Nothing after boot 20:02 has run on the phone.** That includes all of 2890-2892 (GPU and CPU clocks), 2895, 2902, 2904-2906,
2910, the camera crash fix and the render fix. No log has `LAUREL GPU CLOCK`, `DDR`, `CPU TOP`, `WIRED`, `SSD`, `USB POLL` or `AKS`. [V]

What truly works on the phone, per the logs [V]:

- Boot to SpringBoard and the UI. Touch. Backlight, with a read-back of the panel value. Keys. USB log and control channel.
- GL compositing on the real GPU: `FD610`, Mesa through OSMesa, in backboardd. Frames show `0 pictures copied out, 1 drawn in place`.
- GPU SMMU stage 1, with a real fence test (`fence at VA ... in 241 us`). No GPU hang line in boot 20:02.
- Metal device and pipeline compile in SpringBoard, PosterBoard, posters and chronod. Their first command buffers complete.
- Wi-Fi joined one time (`joined KERALAVISON_TP`, usblog 19:14:20). The data numbers are in `wifi.md`; I did not derive them again.
- Haptics play. Battery, charger, thermal and CPU governor lines update. RTC line. Bluetooth firmware loads.

What the owner does not have: a camera picture, cellular, a microphone, headphones, an earpiece, sensors, hardware video, GPU above an
unmeasured 300 MHz, and proven smooth frames.

## 2. Half done (ranked by what the owner sees)

| # | Item | Claim | What the code or log really does | Ev. | Sev. | Done needs |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | Camera has no picture | `LAUREL CAMERA: on`; 2773 "camera quality"; photo path built | No frame has shown light. Boot 20:02 at 20:17:27: 132 ms, gain 16x, `above black: mean 0, 1% over 8, top 9`. Usblog `green N above black` = only 0 or 1. Older `mean 64/65` lines are the black level. The `on` line is a CCI ID read. `camera.md:611,627` says cause unknown; code review and self-check: camera.md section 12, 2784 | [V] | High | One boot in a lit room, then VANA or sensor start work if still dark. A frame with light is the only proof |
| 2 | Photo and video never finish | Camera path "built", hooks in | `encoded` = 0 lines in usblog. `the photograph is given` 1 time, with a black frame. mediaserverd crashed 6 times in boot 20:02. Fix fc10042 is not booted | [V] | High | A saved file seen in Photos; video not tried at all |
| 3 | **Part done, not booted** (2786, `liblaurel-cellbar`, `cellular.md` 9: path decision, bars and name in iOS, `part:` line; data, SMS, voice, Settings pane not built) Cellular is a kernel island | `LAUREL CELL: on` | Kernel QMI client 2760 (1243 patch lines) only reads SIM state. `radio off`, `data off`. The root removes CommCenter (`external/ios-topaz/tools/sweet-root-tweaks.py:13,67`). `cellular.md:72` calls the CommCenter path "last / research". iOS can see no SIM, signal or call. In boot 20:02 the line also says `modem shutting down` (2760:402); no doc explains it | [V] | High | Baseband stand-in or own data path; a decision if voice is a goal. The line should not say `on` |
| 4 | **Test prepared, not booted** (mode bug fixed in 2786; pass and fail lines `cellular.md` 10; modem restart not built, reasons 9.5) IPA (mobile data) forced off | "correct off with a reason" | `ipa=0` is in the default boot-args (`scripts/laurel/uefi-image.sh:31-35`). 2780 + 2782 = 2833 patch lines that no normal boot runs. Only phone run: modem assert at 17:01 (`LAUREL IPA: off: modem crashed ... CHID 1 errval 6`). The 2782 fix never ran. A default-off boot-arg conflicts with the CLAUDE.md rule "boot-arg only as a kill switch" | [V] | High | `IPA_TEST=1` boot, evidence in `cellular.md` section 8; then remove `ipa=0` |
| 5 | GPU clock | "GPU acceleration fully" (owner request); 300/600 by demand | Every boot prints `core 300 MHz`. That is a variable with the value 300 (2150:137), not a measurement. No log line has a measured clock. `plan.md:925` says so. 2892 is not booted. It tops at 600; stock top is 950 (`plan.md:929`) | [V] | High | Boot; read `LAUREL GPU CLOCK`; add upper levels after that |
| 6 | DDR not voted | "DDR read and vote rule" | No DDR vote has run on the phone. 2892:136 turns off if the RPM does not follow. 2892:164-165: the AP sends no scaling enable, so a vote may do nothing | [V] code, [I] effect | Med | Boot; read `LAUREL DDR`; then decide on RPM scaling |
| 7 | Frames not smooth | "GPU acceleration" | GPU use is real, but in the 5 boot 20:02 windows of 9 s or more: 25 to 42 fps, median 33. Example: 389 frames, 340 late, 20.8 ms in present + latch. `plan.md:933` says about 9 ms CPU a frame stays | [V] | High | CPU profile of CoreAnimation and the "handing on" step; the clock patches alone will not fix it [I] |
| 8 | Metal gate passes with broken shaders | `LAUREL METAL CLIENTS: on: m2vtest passed` | Gate checks only compute, render and import fixtures (`userland/laurel/metal/metal_gate.c:57,250`). QuartzCore: `kernels 3 ok 4 failed, pairs 13 ok 8 failed`, and the log still says `QuartzCore shaders: m2vtest passed`. Only a crash narrows the list (`:476-491`, `:259`). Reasons: `VertexAttribute 0` x6, `TileAttachments` x4, `ColorAttachment 2` x2 | [V] | Med | Fix 12 refusals in the bridge or make the line honest. What the owner sees from them is [I]: not traced |
| 9 | Metal does not reach the two main GPU users | "Metal everywhere" | List = `* -backboardd -mediaserverd` (`metal_gate.c:56`). The screen is drawn by GL. Camera has no Metal. Clients seen in all logs: system processes and m2vtest; MobileSlideShow and WebKit.GPU 2 opens each; no third-party app | [V] | Med | Test a real Metal app; decide whether the GL/Metal split stays |
| 10 | Camera is CPU only and one sensor | "GPU/ISP path" not claimed, but the owner expects it | CPU ISP (`userland/camera/README.md:22-23`), 5x5 CPU demosaic (`camera_still.c`), no VFE ISP. The kernel finds 4 sensors (`LAUREL CAMERA: on` line). iOS gets rear only (`camera_device.c:12`). Front and ultrawide: no path. No capture audio (`media_hooks.c:210`). Noise reduction skipped (`media_hooks.c:259`). `set (not used)` for settings (`camera_device.c:857,2205`) | [V] | Med | Front camera; a GPU or VFE path after a real picture exists |
| 11 | No hardware video | - | No video decode or encode patch in `patches/laurel/xnu`. `media_hooks.c:274,333`: software HEVC only. `scripts/laurel/root.sh:89`: no HEVC decoder, so wallpapers are converted to PNG at build time. Playback on the phone: not checked | [V] absent, [I] effect | Med | Venus driver + VideoToolbox stand-in, or accept CPU video |
| 12 | **MIC BUILT, NOT BOOTED** (patch 2920, `audio.md` "Microphone"); headphones, earpiece still open | `LAUREL AUDIO: on` | Speaker path + mic path built. `LAUREL MIC: first capture: rms N` will prove samples. Headphones + earpiece need the RX macro, RX SoundWire, MBHC | [V] | Med | Boot; RX path |
| 13 | Bluetooth stops at bring-up | `LAUREL BT: on` | `on` = firmware load + chip answers; bluetoothd connects. I found no pairing or connection line in usblog (one regex only). BT audio plug-in is moved away (`scripts/laurel/root-audio.sh:15`, `bluetooth.md:198`) | [V] code, [I] log | Med | Pair a device on the phone; BT audio |
| 14 | Sensors, fingerprint, GPS | - | No patch in the series by name. `hardware-map.md` and `port-plan.md` have no such item. `userland/fp` and `userland/location` are not used by `scripts/laurel`. `root-brightness.py` turns auto-brightness off for lack of ALS | [V] absent | Med | Plan them or state that they are out of scope |
| 15 | New CPU copy in the window server | "every format converted" (0004) | The fix for blank widgets converts surfaces by CPU in backboardd (`userland/laurel/gpu/patches/0004-*:27,288`), and re-checks once a frame while bound (`:324,445`). `_RB4` = every opaque RenderBox layer. Not booted. The plan already calls the frame CPU-bound | [V] code, [I] cost | Med | Read `contents` lines and the FPS line; a GPU path for `_RB4` if it costs |
| 16 | Crash loops removed, not fixed | "restart-loop jobs out of the root" (191b826) | Boot 20:02, about 15 minutes: `syncdefaultsd` 12, `webbookmarksd` 6, `mediaserverd` 6 crashes, plus backboardd, PosterBoard and driverkitd 1 each. `scripts/laurel/root-tweaks-perf.py:15,20` removes syncdefaultsd (not booted) with the sig 6 cause unknown. `webbookmarksd` is not in that list and still aborts | [V] | Med | Find the reason of the sig 6 aborts |
| 17 | Wi-Fi scans without end when not joined | `scan limit: on` | Boot 20:02: no join; `scan 763` at modem t = 2337 s, one scan about each 3 s. `wifid gets 103` error 6, `sets 383/365/419/COUNTRY_CODE/HOST_AP_MODE` REFUSED. 383 unknown (`wifi.md:147`). The `on` line shows `MAC 00:00:00:00:00:00` (2401:121); en0's MAC source not checked | [V] | Med | Join on the newest build; check battery cost of scans; explain 383 |
| 18 | **FIXED** (`build-honest.md` 4, 5) Root build hides missing features | "skips with a note" | `root.sh:84,88`: no GL or Metal stage = note and exit 0 (`root-add-gpu.sh:24-27`, `root-add-metal.sh:32`). `root.sh:90,92,94,96,103`: `\|\| echo WARNING`. `root.sh:117`: fsck `\|\| true`. `root-flash-test.sh:12` then flashes. No final list of what the root has. No check that kernel and stages are from one build | [V] | Med | Final manifest; the flash script stops if a wanted feature is absent |
| 19 | **FIXED** (`build-honest.md` 1, 2; the make exit code cannot be the test, it is never 0) Failed kernel build can pass | - | `scripts/laurel/kernel-linux.sh:161` `\|\| true`, then `:165-170` checks only that the kernel file exists. The tree stays unless `CLEAN=1` (`:41`). A failed compile with an old `BUILD/` kernel is copied out as new [I: not reproduced] | [V] code, [I] effect | Med | Use the make exit code; compare time stamps |
| 20 | **Listed, not changed** (`build-honest.md` 6) Watchdogs off by default | - | Default boot-args have `wdt=-1` and `launchd_disable_all_timeouts=1` (`uefi-image.sh:31,36-40`). The second hides slow extensions (`metal.md:380`). These are workarounds, not kill switches | [V] | Low | Remove after shader compile time is fixed |
| 21 | GPU fence is polled | "fence" sounds interrupt-driven | No GPU interrupt (2155:29). `gpuWait` looks every 200 us (0901:297). Logged wait 0.5-0.9 ms a frame, so the cost is small | [V] | Low | RBBM interrupt, for power only |
| 22 | **Mostly FIXED** (plan.md, cellular.md, metal-a610.py, NegroniMetal.mm; 2850:9 is right for pass-through, 2851 prints the real value; `m2vtest.c` is in the metal2vulkan submodule: not changed) Stale text | - | `plan.md:911,919` say NOT BOOTED for 2880-2886 and 2872; their lines are in boot 20:02. `cellular.md:4-5` says not booted. `scripts/laurel/metal-a610.py:6,11`: chip 0x06010001 and pass-through (log: 0x06010000, stage 1). 2850:9 says 64 MiB (log: 256 MiB). `NegroniMetal.mm:2,119` A730. `m2vtest.c:2` A640. Most is cosmetic; `IMX789` names in `camera_device.c` are under `LAUREL_CAMERA` switches where they matter (`:64,1611`), not all checked | [V] | Low | Clean up |

## 3. Done, but unproven on the phone

Built or host-tested only. No log line exists. Treat each as unknown, not as working.

| Item | Claim | State | First proof to read |
| --- | --- | --- | --- |
| 2892 GPU 300/600 + MX/CX NOM | built, host test | Never ran. The self-check is real: it measures the clock and a CP fence at 600 (2892:231-257). Risk: a 600 MHz fault on a boot | `LAUREL GPU CLOCK: on` with measured values |
| 2890, 2891 CPU ramp, holds, top line | built, host test | Boot 20:02 has the old governor: Silver floor 1305 MHz (`LAUREL CPUFREQ` rows 4..7) | `LAUREL CPU TOP` |
| 2895 + Mesa 0001, page tables and NULL fix | fixes sig 11 of backboardd at 20:16:15 and `cannot be entered` x16 | Cause in plan is [V] per its author; I saw the crash and the lines, and did not symbolize it | No `cannot be entered` under poster load |
| 0004 + flame/0020, widgets and XR colours | "every format converted" | Not booted. Owner's blank widgets and false colours are open until then. Black wallpaper is [U] in the plan itself | `redwood-gl: contents` lines; the screen |
| Camera crash fix (fc10042) | crash loop ended | Mock tests only | No `CRASH mediaserverd` during Camera |
| 2880-2886 Wi-Fi path | stalls, bars | `on` lines are in boot 20:02, but no join in that boot. So no traffic has crossed them | `wifi.md` test steps, after a join |
| 2872 panel stays awake | black screen fix | `LAUREL PANEL: on` in boot 20:02. Wake not checked by me | Lock and unlock in a log |
| 2902, 2904, 2905, 2906, 2910 | ports, grants | Merged 20:38, no line in any log. 2904 is a software keybag: unknown selectors answer unsupported | `LAUREL SSD/AKS/USB POLL/WIRED` |
| 2302 charge mode, 2700 haptic UI line | built | No line in any log I searched | Their own lines |

## 4. Correctly off, with a reason

| Item | Why this is right |
| --- | --- |
| `-backboardd` in Metal clients | GL owns the window server. Single reason, checked by the plug-in line `not listed ... no Metal device` [V]. But see row 9 |
| `-mediaserverd` in Metal clients | Comment gives a measured reason: 2.6 GB in 9 s, killed (`metal_gate.c:8-10`). Off, correct until the leak is understood. Plug-in now needs CPU copies (row 10) |
| `patches/laurel/parked/2900, 2901, 2907` | Not applied. README has reasons. 2901 is superseded by 2720. 2900 and 2907 have a real value but need a refresh |
| Auto-brightness off | No ALS path. `root-brightness.py` |
| CoreAnimation software fallback in `bbd_wrap.c` | Crash guard only. It did not fire on boot 20:02 [V: `LAUREL BBD: on`, both starts] |

## 5. What the `on` lines prove

| Line | Proof | Not proved |
| --- | --- | --- |
| `GPU SMMU: on` | Fence through stage 1, kernel page above 4 GiB. **Strong** | - |
| `BACKLIGHT: on` | Panel value read back follows. **Strong** | - |
| `METAL: on` (2850:5-10) | Files on root, chip id, GMEM, RedwoodGPU ready | Any draw |
| `METAL CLIENTS: on` | 3 small fixtures | QuartzCore shaders, real clients |
| `GL DRAWN: on` | The feature is present | That seeds are right |
| `WIFI: on` | WMI READY | Join, data, MAC (zeros in the line) |
| `BT: on` | Firmware loaded, chip answers | Pairing, audio |
| `AUDIO: on` | ADSP, amp revision, DMA runs | Sound |
| `CAMERA: on` | CCI IDs | Light, a picture |
| `CELL: on` | SIM state | Anything in iOS, any radio |
| `TORCH: on` | Registers, plug-in opens the device | Light, in this review |

## 6. Checked and not a problem

- `sweetfb_hz=30` in the boot-args is not a frame cap. It paces kernel console frames only (2870:175); the log has 60 fps windows.
- GL is not software: `FD610`, and the GPU time per submission is in the log.
- Fence wait does not spin the CPU: it sleeps 200 us at a time.
- GL copy-out is off in normal frames (`0 pictures copied out`). Refills: 57 of 299 sampled frames, average 99 KB a sample.
- `known-skips.txt` has no skipped patches. `negroni` names in code are ports, not constants, where I read them.

## 7. Not checked

- Applied kernel tree: not built. I read patch files, not the merged result, so patch-on-patch conflicts are not reviewed.
- Every self-check body: only those named in section 5, and several from their header comment and log text, not line by line.
- Turnip and Mesa patches: heads and the lines my searches found, not the full diffs. metal2vulkan and the flame frontend beyond the patches named above.
- `2600`, `2300-2303`, `2700`, `2720`, `2903`, `2910` internals: search hits only. Sandbox grants not reviewed for safety.
- `gpu-userland.sh` firmware step: `build-all.sh` does not run `gpu-firmware.sh`; `gpu-userland.sh:73` only writes a note if the firmware is absent. Effect on a clean machine not tested.
- Owner-visible results not in logs: real sound, torch light, screen content, and Metal effect of the 12 refused shaders.
- Crash symbols. Video playback. Battery drain. Whether Wi-Fi was tried at all in boots 19:34 and 20:02 (a new root may have lost the network).
- Whether boot 20:02 also had 2903's grant line: it is in usblog, not in the capture `laurel-boot-2002.txt`.
