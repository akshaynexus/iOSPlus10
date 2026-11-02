# Mi A3 iOS 26: lag and missing GPU drawing, boot 11

Date: 2026-11-03. Branch `t3/ios26-metal-gpu-lag-fix`. Evidence: `logs/usblog-20261103-000638.txt` of the main checkout (first part of the boot: only in the replay after line 6200, all timestamps 00:09:06). **Fixes ran on the host only. No flash, no adb, no SSH.**
Marks: [V] read in a log, code or disassembly, or run here. [I] inference. [U] unknown.

## 1. Ranked causes

| # | Cause | Numbers | State | Mark |
|---|---|---|---|---|
| 1 | GPU time per frame is the cap: a long submission takes 25 to 86 ms, and in backboardd the frame waits for it (`NEGRONIMETAL_SYNC=1`) | 7 to 17.5 fps on Metal; section 3 | Not fixed. Clock: section 5 | [V] numbers, [I] cap |
| 2 | Every wait for the GPU was a busy loop of system calls: wrong clock in the deadline | 3,910,567 polls, 1 real wait, in 32 windows of 5 s; up to 468,161 in one window | **Fixed**, commit 7adaaf3 | [V] |
| 3 | CPUs 96 % busy: 277 to 290 tasks, boot storm, daemons with no use here | 461 s of 480 in a minute; ended tasks 197.5 s and 284.6 s | **Partly fixed**: 33 jobs out, commit 5f153dc. Who the ended tasks were: [U] | [V] numbers |
| 4 | RenderBox effects have no pipeline: `specializedName` was dropped. Icons lose masks, glow and clamped edges | 13 lines in the replay, over iconservicesagent and SpringBoard | **Fixed**, commit b811ece | [V] host chain, [U] pixels |
| 5 | GPU pool runs out: buffers go to scattered pages, which need a cache push | Pool 376 -> 12 MB free; surface pushes 1,868 -> 20,617 per 5 s; CPU per submission 356 us -> 6,977 us | Not fixed | [V] numbers, [I] link |
| 6 | iconservicesagent dies at its 15 MB inactive limit, with a Metal device of 15 to 20 MB | 3 kills | **Fixed**, commit 5f153dc | [V] |

**Expected gain, all [I]:** the fence fix and the job drops free about 15 to 30 % of the CPUs while the GPU is busy. Metal on Home and lock after the boot storm: from 7-17 fps to about 18-28 fps, limited by cause 1. With 745 MHz (section 5, not done): about 22-34 fps. Not 60.

## 2. Each refusal, and what the UI loses

| Refusal | Where | What the UI loses | Fix |
|---|---|---|---|
| `render pipeline 'custom_effect:clampToEdges_v1'`, `'primitive_custom:glow_v1'`, `'primitive_custom:simplifiedShapeAwareGradientMask_v1'`: `Compile(NeedsInput(LinkedFunction { symbol: "custom_fn" }))` | iconservicesagent, SpringBoard, 13 lines in the replay (once per reason per process, so the real count is higher) | **The picture.** These 3 effects are in `IconRendering.framework/default.metallib` [V]: masks, glow, edges of icons [I what each draws] | `m2v-ios26/0001`, `flame-ios26/0002`. [V 23F84] `RB::Device::RenderPipelineEntry::Loader::load_custom_fn` and `RB::Function::load_function`: `setName:` effect, `setSpecializedName:` `@"custom_fn"`. Our frontend threw the name away. IOS-26-Hot 0102 has the same fix on its older translator |
| `heap texture: OutOfMemory(Heap)`, `first heap texture refused: fmt 65 125x125, heap 196608 bytes, 131584 used` and 4 more | iconservicesagent, SpringBoard | **Nothing.** [V] `RB::RenderFrame::alloc_texture`: asks its heaps in turn, a nil goes to the next (`cbnz x0` at 0x196ae46c8), then `RB::Device::alloc_shared_heap` makes a new heap. Each logged case leaves less than one aligned block: 131584 used of 196608 at 64 KiB is 65024 bytes left [I alignment] | None. The line reads worse than it is. A second nil at 0x196ae4738 would lose a texture; the log cannot tell it from the first |
| `binary archive: ... InvalidFile`: RenderBox `archive.metallib`, IconRendering `binary.metallib`, SiriUICore `archive.metallib`, QuartzCore `default.metallib` | every Metal process | **Nothing in the picture.** AGX code only, or a fat file (`metal-libs.tsv` [V]). CA tests the nil [V `ios26-backboardd.md`]; RenderBox goes on to compile [V log order]. Cost: compile at first use: 20 to 93 ms at the first frame, 818 ms once in SpringBoard [V] | None |
| `not listed ...`: backboardd (2), WidgetRenderer_Default, chronod, cameracaptured | | Backboardd: already fixed, c811ee5. The others have a CPU path by design | None |

Test: `scripts/bg.sh rb-effects scripts/ios26/test-renderbox-effects.sh`. RenderBox's stage + IconRendering's effect, real runtime, real Turnip + ir3 for FD610 through drm-shim:

```
ok    custom_effect:clampToEdges_v1
ok    primitive_custom:glow_v1
ok    primitive_custom:simplifiedShapeAwareGradientMask_v1
FAIL  control-no-name  render pipeline: Compile(NeedsInput(LinkedFunction { symbol: "custom_fn" }))
rb-effects: PASS
```

The control gives the phone's refusal to the byte. Limit: zeros stand in for RenderBox's state constant (uint4, index 0, `setConstantValue:type:0x24 atIndex:0` [V]), so the 11 fragment instructions are not the real cost [U]. Pixels: [U].

## 3. What a Metal frame costs

Windows of the Metal phase, backboardd pid 66 [V]:

| Window | Submissions | Long ones (> 4 ms) | GPU us each | Busy | CPU us per submission | Named per submission | Pool free MB | Surface pushes |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 64 | 42 | 33,314 | 38.7 % | 358 | 645 | 169 | 751 |
| 2 | 160 | 117 | 25,888 | 80.2 % | 356 | 713 | 145 | 1,868 |
| 3 | 102 | 72 | 31,517 | 64.1 % | 477 | 1,084 | 125 | 1,645 |
| later | 42 | 26 | 65,937 | 52.6 % | 778 | 1,885 | 99 | 833 |
| later | 47 | 28 | 85,762 | 78.1 % | 2,943 | 1,848 | 12 | 10,488 |
| last | 71 | 48 | 39,338 | 54.5 % | 6,977 | 1,811 | 26 | 20,617 |

| Question | Answer | Mark |
|---|---|---|
| GPU cost by pass | **Not in the log.** Only a time per submission. A submission holds about 8.8 to 14 command buffers | [U] |
| Whose GPU time | Not only backboardd's. With backboardd off Metal, clients still take 15 to 53 % busy and 50 to 60 ms per long submission (SpringBoard, iconservicesagent, WebKit.GPU) [V windows of pid 395]. So the frame's share is less than these numbers. Much of it is the first drawing of icons [I] | [V] + [I] |
| Tile mode | Not in the log. No `TU_DEBUG`: Turnip's autotune picks per pass [V env, `tu_autotune.cc`]. Its rule counts bandwidth, not the 36 tiles of a 132 KiB GMEM [V code, I count]. AdrenoMetal measured GMEM against sysmem on an A740: 17.8 and 17.1 ms mean: no real gain [its log]. Hot's `nocb` does not exist in Mesa 25.0.7 [V]. The bench exists: XNUtils, `tumode` | [U] for the A610 |
| Pipeline compiles | Not the cost. 3 to 15 pipelines in 14 to 93 ms at the first frame; shader cache hits after the first boot [V] | [V] |
| IOSurface copies | None in the path: direct scanout; `0 to 5 IOSurfaces taken` per window, 140 to 584 us each [V] | [V] |
| CPU in a submission | Grows 20 times as the pool empties: cause 5 | [V] |
| Pipeline cost per pixel | Median fragment 91 instructions; at 1 SP and 600 MHz one full-screen layer of that is about 20 ms [I, section 8 of `ios26-metal.md`]. Two or three layers fill a frame. This is the plain reason | [I] |

Reference notes: Hot's runtime patches 0009 to 0014 (keep final pass, fewer allocations per draw, keep draw lists, skip rebinds) do not apply to our 219f013: 1 to 11 files fail each [V `git apply --check`]. They save CPU per draw [their report]. A port is a real next step, but only after a phone number shows encode time matters. Hot 0016 `tile_store_fits` (a tile store writes 16x4 blocks past a row): not in 219f013 [V grep]; it applies to a written padded texture over a buffer: not seen in boot 11 [U].

### Cause 2: the fence wait

- [V log] `a wait for submission 3, which is not done, until 20.779097000 s, asked for at 39.349633385 s: over before it began`. Boot 10: 23.466266 s at 42.024740 s. The lag is 18.56 to 18.57 s in both.
- [V code] `negroni_drm.c`: `fence_wait_until` makes the deadline with `CLOCK_MONOTONIC`. The kernel (`millisecondsUntil`) reads `mach_continuous_time`. `timeout_ms` and Turnip's `get_abs_timeout` already use `CLOCK_MONOTONIC_RAW` for this reason; this one path did not. An old note in `notes.md` said the two are the same counter [I]; that was wrong.
- Result: the kernel saw a past deadline and answered at once. `fence_wait_until` saw time left and asked again. **Each thread that waits for the GPU spun at full speed for the whole job.** The iOS 16 log has the same: 18,142,426 of these against 43,021 real waits [V `usblog-20261101-165828`], so this fix also helps iOS 16.
- Test: `scripts/laurel/test-fence-wait.sh c811ee5` runs the real functions, cut from the file, against a copy of the kernel's rule, for a 39 ms job: this tree 1 system call that sleeps; control 3,900 system calls, none sleeps.
- The wait in the kernel is still `delay_for_interval(200 us)`: 5,000 looks a second, each cheap. A sleep woken by the `CACHE_FLUSH_TS` IRQ (kernel need K7) is better; not done.

## 4. Daemons and limits

| Group | Jobs (out of `launchd.plist`, `ios26-root-spec.py`) | Why | Mark |
|---|---|---|---|
| Loops | deviceaccessd, gamepolicyd, security.cryptexd, driverkitd, watchdogd, softposreaderd | 19, 18, 13 crashes and more in 3 minutes. Each life is about 1 s of each 10 s, so together at most 0.5 of a core [V times] | [V] |
| IOS-26-Hot's list | nfcd, seld, factory.NFQRCoded, biometrickitd.pearl, nanoregistryd, nanoregistrylaunchd, nanoprefsyncd.2, nanobackupd, cloudpaird, modelcatalogd, generativeexperiencesd, siriinferenced, sirittsd, callintelligenced, PerfPowerServices, PerfPowerServicesExtended, perfpowermetricd, biomed, biomesyncd | No hardware or no client here. Hot removes them on 23F84 and reports Home and Settings | [self-reported] |
| On-device learning | fitnessintelligenced, intelligenceplatformd, intelligenceflowd, intelligencecontextd, intelligencetasksd, knowledgeconstructiond, servicesintelligenced, batteryintelligenced | FitnessIntelligence 28.4 s and 20.3 s a minute [V]. An A13 has no Apple Intelligence [I]. **No report on any phone** | [U] effect on clients |

Kept on purpose: `KEEP_FOR_PARITY` in the spec, checked by the self-test: Wi-Fi, audio, Bluetooth, cameracaptured, videocodecd, sharingd, mediaplaybackd, dasd, healthd, searchd and the UI. dasd (17 to 20 s a minute), healthd (13 to 18 s), searchd (11.5 s) are first-boot work and they serve system apps [I]. **What stops [I]:** Siri voice, NFC and Wallet taps, Settings > Battery charts, Watch pairing, AirPods cloud pairing, and suggestions from on-device learning. Find My, Wallet, Screen Time stay on the root. Whether a client waits on a missing service: [U]: the first boot tells. `PERF_DROPS=0` at the root build keeps all 33. wdt: the boot-args have `wdt_test=no_user_checkin` [V `uefi-image.sh`], so no user check-in is needed with no watchdogd.

**Watermark limits: not wrong because of the page size.** [V host] `ios26-user-emu.sh PROGRAM --start-cost`, real dyld + lowered cache, at `main()`:

| Program | Instructions to main() | KiB written, 4 KiB pages | KiB written, 16 KiB pages |
|---|---:|---:|---:|
| deviceaccessd | 33,451,743 | 1,000 | 1,504 |
| gamepolicyd | 28,880,560 | 976 | 1,472 |
| liveactivitiesd | 30,057,297 | 1,140 | 1,728 |
| linkd | 32,259,548 | 1,012 | 1,520 |

So 4 KiB pages make a start **smaller** by a third, and a start is about 1 MiB of a 6 MiB limit and about 30 M instructions (15 to 30 ms [I]). The limits are Apple's: `com.apple.jetsamproperties.N104.plist`, and 6 MB for a daemon with no key (driverkitd has only a priority there, 6 MB in the log) [V]. What takes a daemon past them after `main()`: [U]. `triggered unnest of range 0x202000000->0x204200000` prints for most processes (146 lines): that costs page tables, 68 KiB for 34 MiB [I], not the difference. So: drop what has no use, raise only what stays. Floors: `JETSAM_FLOORS`, iconservicesagent inactive 96, linkd 32, liveactivitiesd 24, intents-helper 24, watchlistd 16, managedappdistributiond 16, nehelper 16.

Memory is not short system-wide: `memorystatus_available_pages` 183,000 x 4 KiB = 715 MiB at the kills [V]. XNU has 3,264 MiB of the 6 GB (patch 2100) [V].

## 5. GPU clock: yes, the kernel limits it to 600 MHz

- [V] `LaurelGpuDcvs.cpp` (2892): only `rcg_set(0x101c, SRC_GPLL0, div)` with div 2 or 1: 300 or 600 MHz. Nothing programs the GPU's own PLLs.
- [V] Stock table `trinket-gpu.dtsi`, `gpucc-trinket.c`: 950, 900, 820, 745, 600, 465, 320 MHz. Above 600 it uses `GPU_CC_PLL0_OUT_AUX2 / 2`. Rails: 745 needs CX NOM, 820 NOM_L1, 900 HIGH, 950 HIGH_L1; PLL up to 2 GHz needs MX NOM.
- [V] The kernel already holds MX + CX at NOM for the boot. So **745 MHz needs no new rail vote**: 24 % more clock. Stock bus level 9 at 745. DDR reads 1355 MHz now. Thermal in boot 11: GPU 58 to 60 C, limit 90 C: room.
- Demand: `clock 588 to 600 MHz over the window` while busy [V]. `300 MHz 37 s, 600 MHz 22 s` a minute follows the load; it is not the limit.
- **Not done here.** It needs PLL0 programming and a clock read on the phone; the host cannot prove it. Next kernel step: level 2 in `LaurelGpuDcvs.cpp`: PLL0 at 1490 MHz, source `GPU_CC_PLL0_OUT_AUX2`, same self-check (`clock_right`, CP fence, watchdog back to 600), one `off` line on failure. GPU time 39 -> 31 ms [I].

## 6. Not fixed, next

1. Clock 745 MHz: section 5.
2. Pool: why backboardd + clients take 380 of 512 MB when one submission names 123 to 145 MB [U]. Hot reports 416 to 593 of 944 MB at 2.5 times our pixels, so ours is high. To read over SSH: kept buffers, m2v's 8 MB blocks, per-process devices.
3. Sync: with `NEGRONIMETAL_SYNC=1` a frame is CPU + GPU, not the larger of the two. The kernel has `topaz_surface_drawn` for the same job. Boot 11 shows `14 us GPU fence` after SwapEnd, so the kernel's wait is free now [V]. Removing the user wait needs a phone test for half-drawn frames.
4. Bench: XNUtils `tumode` sysmem / gmem and `hot` stack, per `ios26-metal.md` 10.5.
5. Who the ended tasks are: `LAUREL CPU TOP` names only live tasks. Read `ps` over SSH in the first 3 minutes.

## 7. Next boot: lines to read

```
RedwoodGPU: N waits of M us, K over before they began        K near 0, N large (boot 11: 1 wait, 3.9 M over)
LAUREL CPU TOP: 60 s, busy B s of 480                        B below 461, no FitnessIntellige
NMTL[.. iconservicesagent]: pipelines ...                    no line refused ... custom_fn
SWEET FPS: ... frames in ...                                 backboardd on Metal, after the first 3 minutes
```

Root audit: `applied launchd drop crash and kill loops of boot 11`, `applied jetsam floors`.
