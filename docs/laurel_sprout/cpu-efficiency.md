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

## 7. Open

- The 2-minute panic cycle (3050) hides every settled number; the before/after of section 6 needs one boot that stays up through `ios26-autotest.sh run`.
- The P -> E spill weight for the UI buckets (FG, fixed) could rise above 64 us so the render thread waits on gold rather than runs on an A53: after the first numbers.
- `cores` 0 ms on P cores: the tool's struct or the cpu kinds [U].
