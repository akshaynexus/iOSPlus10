# Mi A3 iOS 26: CPU efficiency toward 60 fps (laurel 3070, 3071)

Date: 2026-11-07. Branch `laurel-sprout` (owner's order: one branch, one worktree). Marks: [V] read in a log, in code, or measured; [I] inference; [U] unknown.
Scope: the CPU side only. Stuck-CPU panics are 3050-3059 (another agent), the GPU path 3060-3069, the metal2vulkan benches a third agent.

## 1. What the phone showed before any change (kernel `da6a24b881`, 386 patches, series `f4839e9f8e64bf57`; `logs/usblog.log` 05:14-05:31) [V]

The phone rebooted every 2 minutes (`LAUREL WDOG: bark: no pet for 12 s`, silent CPU 5: the 3050 work), so every minute measured here is
the boot storm. No settled minute exists in this log.

| Item | Numbers | Reading |
|---|---|---|
| Boot cadence | `LAUREL BUILD` at 05:21:03, 05:23:03; the UI at +60 s; the bark at +110 s | every minute below is minute 1 of the UI |
| CPU use | `LAUREL CPU TOP: 60 s, busy 367-372 s of 480`: SpringBoard 42-46, chronod 14-23, launchd 15-18, kernel_task 12-13, locationd 9, iconservicesagent 13, backboardd 9-10, biomed 10; ended tasks 14-19 | 76 % of 8 CPUs; the storm, not the UI |
| Kill loops | 0 `CRASH` lines in the boot 05:21:03-05:22:55; no daemon exec'd more than twice but bluetoothd (6) | the jetsam floors of `cpu-parallel.md` hold; ended tasks are the storm's short helpers [I] |
| Gold rows | `LAUREL CPUFREQ: on: gold MHz:seconds in the last minute: 300:0 2016:59` | at the cap all minute |
| Silver rows | `silver ... 300:7-10 ... 1804:44-46` | at the cap 3/4 of the minute, 300 only when idle |
| 2996 | `LAUREL TIMER COALESCING: on: the kernel's timer coalescing is off ...` (05:15:15) | on [V] |
| 2997 | `LAUREL TOUCH FAST: on: a sample every 4 ms at priority 92 ...` (05:15:15) | on [V] |
| 3020 | no `LAUREL CPU MOTION` line in any log; the patch is in the 386 (`out/laurel-kernel-ios26/patches/3020-...`) | the line prints at `laurel_cpufreq_start`, before the USB console ring of the boot is kept (the `LAUREL CPUFREQ: on: OSM governor` start line is missing the same way). Proof must come from `ksysctl kern.laurel_stats` `cpu.hold=motion` during a server animation: not read yet (phone in the panic cycle, then in fastboot under another agent) [U] |
| Emulated words | `LAUREL EMU: counts pac=65277 lse=33938 fp16=910382` in the first UI minute, and `pac=65635 lse=32960 fp16=810601` in the next boot | **FP16: 15,000 words a second**, about 2 us each [I, `ios26-userland.md`]: about 3 % of one gold core, plus the pipeline cost of a trap. The counts say nothing about where: laurel 3070 |
| Console volume | 919 lines in the 52 s of a UI boot minute: exec 184, SWEET 168, LAUREL 132, NMTL 105, IOK 88, RedwoodGPU 67, apple80211 45 | 18 lines/s; at 100-700 us a line [I, `cpu-parallel.md`] under 1.3 % of one core. Not worth a feature now |
| Traps per CPU | `LAUREL WDOG: bark: cpu 3 ... 1,063,060 in all` (class 0x15 = SVC), cpu 4 787,363, cpu 6 784,552 | syscalls, 110 s of boot: normal |

## 2. Scheduler facts read in the code [V `osfmk/kern/sched_clutch.c`, `thread_group.c`, `recount.c`, `SweetCPU.cpp`]

- `kern.sched: edge`, 2 psets: boot pset = gold (pset 0, `PSET_AMP_P`), silver pset 1 (`PSET_AMP_E`); `__AMP__` on (`SWEET.h: __ARM_AMP__ 1`).
- Without CLPC, **every thread group prefers the boot pset for every QoS bucket**: `sched_clutch_bucket_group_init` writes `sched_boot_pset->pset_id`. No thread, kernel or user, prefers silver.
- The edge matrix is set in `sched_edge_cpu_init_completed`, called by `SweetCPU.cpp` (`ml_cpu_init_completed()` after every CPU came alive, before launchd): P -> E weighted spill (64 us, steal allowed), **E -> P no spill, no steal**. So silver runs only what gold spills when gold's queue is 64 us ahead, and what an idle silver steals.
- The UI's threads (SpringBoard main pri 47, backboardd render pri 54, touch pri 92) sit in the FG / fixed-priority buckets; the storm's daemons mostly in default, utility and background.
- rusage `ri_user_ptime` (P-core time, `laurel-autotest cores`) comes from `recount` with `RCT_TOPO_CPU` and `_topo_cpu_kinds[]` from the ADT `cluster-type`; `cores` read 0 before: the cause is in the tool or in the kinds [U, not this work].

## 3. laurel 3070: `LAUREL EMU SITES` (post/9026)

The emulator keeps every site it serves (128 slots, 4 probes per pc): process name, user pc, the pc with the task's dyld cache slide off, the word,
the class, a count. After each `LAUREL EMU: counts` line (once a minute): `LAUREL EMU: sites: fp16 N PROC pc 0x.. unslid 0x.. word 0x..; ...; other N;
U of 128 slots`: the 4 hottest sites of that minute. `scripts/laurel/ios26-emu-sites.py logs/usblog.log` sums the lines and names the cache image
and offset (`out/ios26/dsc-images.txt`). Cost per served word: one hash, up to 4 loads, one add. Kill switch `laurelemusites=0`.
Host test `scripts/laurel/test-emu-sites.sh` PASS (the real header: counts, probes, other, top-4 order, deltas, comm cut, unslid, 8 threads).
Then: a site in a hot path gets its own answer: a lowering of those words in the root (as PAC and LSE: `scripts/ios26/lower-userland.sh`, each FP16
form needs its own NEON sequence) or a switch that steers the library to its ARMv8.0 path. Nothing is lowered yet: the sites are not known.

## 4. laurel 3071: `LAUREL SCHED PLACE` (post/9027)

As CLPC on an iPhone: the utility and background buckets prefer silver; fixed-priority, foreground, user-initiated and default keep gold. The E -> P edge
takes the same weighted spill as P -> E, so an idle gold still pulls silver's excess and no job or QoS is limited to a cluster (owner 2026-11-03: use
all cores fully). Set once in `sched_edge_cpu_init_completed`, applied to the thread groups that exist (migrate running and runnable), and taken by
every later thread group at `sched_clutch_bucket_group_init`. Line: `LAUREL SCHED PLACE: on: utility and background threads prefer pset 1 (4 CPUs),
fixed-priority, foreground, user-initiated and default threads pset 0 (4 CPUs); an idle cluster takes the other's excess (spill weight 64 us both
ways); N thread groups set`. Kill switch `laurelschedplace=0`. Host test `scripts/laurel/test-sched-place.sh` PASS.
Expected [I]: in the storm, gold's queues lose the UT/BG part of the daemons' work, so SpringBoard's and backboardd's threads wait less and spill to
silver (an A53 at 1804 MHz, about half an A73's speed per clock) less often; silver's 300 MHz seconds fall. Not expected: less total CPU.
Both patches compile with the tree's own flags (`compile_commands.json`, `-fsyntax-only`, 0 errors). **NOT BOOTED.**

## 4b. First boots with 3070 and 3071 (kernels 43eed8b7b8 390 patches 06:10, 8c7f0143db 394 patches 06:36; the phone still reboots every 2-4 min) [V]

The sites lines came: `scripts/laurel/ios26-emu-sites.py logs/usblog.log`:

| count (7 minute lines) | class | process | unslid pc | word | image |
|---:|---|---|---|---|---|
| 31,417 | pac | audiomxd | 0x2a34dea80 | `retab` | libsystem_m.dylib+0xa80 |
| 20,031 | lse | laurel-springboard | 0x1bd968354 | `cas x8, x9, [x30]` | libdispatch.dylib+0x29354 (one of the 10 LSE words with x30 the lowering leaves) |
| 11,265 | fp16 | backboardd | 0x183f1eaa8 | `fcmp h0, h1` | QuartzCore+0x4daa8 |
| 7,447 + 7,439 + 4,627 | lse | logd | root binary | `cash`, `swpl` | logd (root, not lowered) |

**The FP16 storm is not these.** `LAUREL EMU: counts` went `fp16=34,941` (06:36:42), `5,912,620` (06:37:43), `22,908,768` (06:38:43): **17 M FP16 words
in one minute, 280,000 a second**, about 0.6 of a core at 2 us a word [I]. In that minute `LAUREL CPU TOP` had iconservicesagent 65 s, dasd 33 s,
StocksWidget 22 s, FitnessWidget 15 s, modelcatalogd 13 s; the first sites table (128 slots, 4 probes) was full and the storm's sites fell to
`other`. [I] The icon and widget rendering (CoreGraphics / vImage half-float paths, 2,762 + 2,335 FP16 sites in the cache) is the FP16 hot path, not
the compositor. 3070 now keeps 512 slots, 8 probes, and counts the words with no slot per class; one line per site. The next boot names the sites.
Other readings of those minutes: gold `1804:60`, silver `1612:60` (a cap one row under the top: thermal, or the 3051 margin of the wdog agent; [U]);
`LAUREL CPU TOP: busy 407 s of 480` (85 %) in the storm minute, 251 s the minute after.

## 4c. Boot 06:45 with 3070 (512 slots) and 3071, kernel of `scripts/laurel/snap-build.sh cpu` (series HEAD 06:44, image 430bc5ec) [V]

Both features are on: `kern.laurel_stats` state lines `LAUREL SCHED PLACE on ...` and `LAUREL EMU SITES on ... 512 slots, 8 tried per pc`
(the boot lines print before the console ring is kept; the stats sysctl keeps them). `LAUREL CPU MOTION on` is there too: 3020 runs [V].

The FP16 hot path, named (`LAUREL EMU: site` lines of the first two UI minutes):

| minute | class | count | process | unslid pc | word | where |
|---|---|---:|---|---|---|---|
| 1 | fp16 | 503,357 | iconservicesagent | 0x184368938 | `fcmp h2, h0` | CoreGraphics+0xa6938 |
| 1 | fp16 | 122,403 | iconservicesagent | 0x184368940 | `fcmp h2, #0.0` | CoreGraphics+0xa6940 |
| 1 | pac | 21,561 | audiomxd | 0x2a34dea80 | `retab` | libsystem_m+0xa80 |
| 1 | lse | 13,709 | locationd | root binary | `ldaddal x9, x8, [x8]` | locationd (root, not lowered) |
| 2 | lse | 27,797 | locationd | root binary | `ldaddal` | same |
| 2 | fp16 | 20,446 + 20,446 | backboardd | 0x183f1eaa4, 0x183f1eaa8 | `fmov h1, #1.0`, `fcmp h0, h1` | QuartzCore+0x4daa4 |
| 2 | lse | 5,781 | laurel-springboard | 0x1bd968354 | `cas x8, x9, [x30]` | libdispatch+0x29354 |

`fp16` counts: 687,012 in minute 1, +65,472 in minute 2. The 17 M-word minute of boot 06:36 did not come back on this boot (iconservicesagent 65 s
there, under 10 s here: the icon cache was warm [I]). No slot this minute: `pac=236 lse=4005 fp16=755`, 495 of 512 slots used (locationd and logd
have hundreds of LSE sites each: the root binaries are not lowered).

**The CoreGraphics site** (`dsc-image.py ... fn CoreGraphics 0x184368938`): a half-float (RGBA16F) pixel blend loop: `ldr h`, `fcvt s, h`, `fcvtl`,
`fmla`, `fcvtn`, `str d`, and two FP16 words per pixel: `fcmp h2, h0` (alpha against a limit) and `fcmp h2, #0.0`. Everything else in the loop is
ARMv8.0. So the icon storm's cost is 2 traps per pixel, about 4 us a pixel at 2 us a trap.

**Decision on a lowering [I, numbers V]:** `fcmp hN, hM` and `fcmp hN, #0.0` are the simplest FP16 forms: `fcvt s16, hN; fcvt s17, hM; fcmp s16, s17`
(exact: half to single loses nothing, NZCV is the same) with two S registers spilled below the red zone, in the trampoline frame the LSE lowering
already has (`tools/op10tool/src/a64.rs`: `lse_trampoline`, `TRAMP_FRAME` 176 bytes, the x30 stub when x30 is live). Gain: 625,000 traps in the
first UI minute of a warm boot (1.2 s of CPU, 2 % of a core), up to 17 M (34 s, 0.6 of a core) in the minute an icon cache is rebuilt. It is a
boot-storm cost, not a frame cost: the compositor's own FP16 is 41,000 words a minute (0.1 s). Not done in this round; it needs a lowering run over
the cache and a new root (hours, the shared phone). The recipe is above; the sites lines of every boot say whether it is still worth it.

**Frames in the storm (home-swipe of the autotest, 06:47, 30-60 s after SpringBoard):** `motion ended: 37 frames in 670 ms` (55/s), `90 in 1499`
(60/s), `151 in 2515` (60/s) [V]. Earlier Home loops were 13-17 frames/s (`ios26-default-speed.md`), but other agents' GPU and metal2vulkan changes
landed in between: not a measure of 3071 alone [I].

**3071 before/after in the only window that exists (minute 1 of the UI, storm):** CPU TOP busy 367 s before, 366 s after; silver rows `300:7-10` then
all at its cap both times (the cap is 1612 now: `LAUREL CPU MARGIN`, patch 3051 of the watchdog agent, holds the top row back). No settled window:
the phone still reboots every 2-4 minutes (3050 work). The `cores` line (runnable ms of SpringBoard and backboardd) came empty: `toybox ps` on this
root prints no pid column the script can read (awk is not on the root; a sed form is in, not yet proven) [U].

## 4d. The FP16 `fcmp` lowering, a real feature of the root build (`a64-lower` rule `fp16`, 2026-11-07 afternoon)

Owner's order: implement it while the phone is off. Done in `tools/op10tool/src/a64.rs` (`fp16cmp_decode`, `fp16cmp_trampoline`, `trampoline_for`),
`lower.rs` (the sites join the LSE plan: same zones, same slots, same `bl` or x30 stub, the verify pass accepts `fp16 fcmp -> bl/b`), `a64test.rs`
(the qemu self-test runs every form natively on `-cpu max` and through the trampoline on `-cpu cortex-a53`: every V register, NZCV, FPSR, x30
and the red zone must match).

| Item | What | Mark |
|---|---|---|
| Forms | `fcmp Hn, Hm`, `fcmp Hn, #0.0`, `fcmpe Hn, Hm`, `fcmpe Hn, #0.0` (C7.2.70, opcode2 00000 / 01000 / 10000 / 11000). The cache has 7,821 sites in 279 unique words, the root Mach-O files 100 | [V census] |
| Trampoline | `sub sp, #176; stp q, q, [sp]; stp x16, x17, [sp, #32]; mrs x17, fpcr; tbz w17, #26, conv; and x16, x17, #~AHP; msr fpcr, x16; conv: fcvt s, h (x1 or x2); fcmp(e) s, s or s, #0.0; tbz w17, #26, out; msr fpcr, x17; out: ldp x16, x17; ldp q, q; add sp; ret`. Two Q scratch registers from v16-v19 that are not the operands. 13 or 15 words, 2 or 3 for the LSE frame's spill slots (48 bytes: 32 for the Q pair, 16 for x16/x17) | [V code, unit test] |
| Why exact | every half value is a single value, so `fcvt s, h` + `fcmp s` gives the same NZCV and the same cumulative FPSR flags (a signaling NaN raises Invalid in the conversion as it would in the half compare; a quiet NaN raises it only under `fcmpe`, in the single compare) | [V self-test: 304 cases, 0 mismatches] |
| FPCR.AHP | bit 26 makes a conversion read the half in the alternative format (no infinity, no NaN) while the half compare stays IEEE: the trampoline clears AHP around the conversions when it is set, and puts it back. Tested with AHP on and off | [V self-test] |
| FPCR.FZ16 | bit 19 flushes a denormal half input of `fcmp h` but not of a conversion (FPUnpackCV). On a CPU without FEAT_FP16 (the Kryo 260, cortex-a53) the bit is RES0: no program here can set it, so the trampoline needs no flush path. The first draft had one; the self-test showed `-cpu cortex-a53` dropping the bit, which proves the point | [V self-test, I ARM ARM] |
| Kill switch | `A64_FP16=0 scripts/ios26/lower-userland.sh`: the rule set becomes `pac,rcpc,lse,sysreg,slide`, the words stay for the kernel emulator (LAUREL EMU) | [V script] |
| Root audit | feature `fp16-cmp-lowered` in `ios26-root-spec.py`: reads `lower-report.md` of the lowered tree; `applied` with the site counts, `off` when the rule was off or the report is older | [V self-test of the spec, 43 of 43] |
| Self-check of the lowering | `a64-selftest` reads `lse-words.txt` (now with the FP16 words) and runs every real word; `a64-verify` replays dyld's and the kernel's checks and accepts an FP16 site only as a branch to a stub or trampoline head on cortex-a73-decodable code | [V] |
| Not lowered | `fccmp h` (211 sites), `fmov h, #imm` (one word, 3,600 sites: `movi` would set the other lanes differently), the arithmetic forms: they stay with the emulator. The next sites lines say whether one of them is hot | [V census] |

**LSE in the root binaries (logd 27 sites, locationd 92, 5,460 in 16 files): not done.** They are left because the file's `__TEXT` has no free
run of 64 zero bytes left after the first 2,230 + 303 sites of locationd took 8,204 of its 8,208 free bytes (`macho-lowered.tsv`). The frame fits;
the space does not. More space means growing `__TEXT` and moving every later segment and the code signature: a Mach-O re-layout, not this
round. Cost on the phone: locationd 14,000-28,000 traps a minute, logd 15,000 (0.03-0.06 s of CPU a minute). The libdispatch `cas x8, x9, [x30]`
(5,800 a minute in SpringBoard) is one of the 10 x30 words the stub scheme cannot serve: same answer.

## 5. Tools

| Tool | What |
|---|---|
| `scripts/laurel/cpu-place-read.sh [SECONDS] [NAME]` | under the phone lock: `kern.laurel_stats` (rows, `cpu.hold`), busy % per CPU per second (0-3 gold, 4-7 silver), CPU / P-core / runnable ms of SpringBoard and backboardd, then the last minute lines (CPUFREQ, CPU TOP, EMU counts and sites, SCHED PLACE, CPU MOTION) -> `logs/cpu-place-NAME-DATE.txt` |
| `scripts/laurel/ios26-emu-sites.py LOG...` | the hottest emulated sites over a log, with the cache image |
| `scripts/laurel/ios26-autotest.sh run`, `ios26-sample-bins.py`, `ios26-speed.sh` | the scenario, the thread samples, the wake-up and clock measures (unchanged) |

## 6. What the next boot must show

| Line | Before | After |
|---|---|---|
| `LAUREL SCHED PLACE: on: ...` | none | the line, N thread groups |
| `LAUREL EMU SITES: on: ...`, then `LAUREL EMU: sites: ...` a minute | none | the 4 hottest sites; `other` near 0 |
| `LAUREL CPUFREQ: on: silver ...` in a UI minute | `300:7-10 ... 1804:44-46` | 1804 seconds not lower (silver now carries UT/BG by preference) |
| `cpu-place-read.sh`: `cpus` rows in the Home loop | [U] | gold 0-3 not at 100 while silver 4-7 idles |
| `cores`: runnable ms of SpringBoard, backboardd over 10 s | [U] | lower than before on the same scenario |
| `ksysctl kern.laurel_stats` `cpu.hold` in a server animation | [U] | `motion` (proves 3020) |

## 7. Open (updated 06:50)

- The 2-4 minute panic cycle (3050) hides every settled number; the before/after of section 6 needs one boot that stays up through `ios26-autotest.sh run`. Until then the sites lines, the state lines and the storm minutes are the evidence.
- The FP16 `fcmp h` lowering is in (section 4d); its first root is built when the phone is back for the flash.
- The P -> E spill weight for the UI buckets (FG, fixed) could rise above 64 us so the render thread waits on gold rather than runs on an A53: after the first numbers.
- `cores` 0 ms on P cores: the tool's struct or the cpu kinds [U].
