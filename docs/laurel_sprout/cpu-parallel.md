# Mi A3 iOS 26: what limits parallel work (boot 11)

Date: 2026-11-03. Branch `t3/cpu-parallel-limits`. Owner decision: use all CPU cores fully, do not limit compute or parallel work, no job is removed (`PERF_DROPS=1` is opt-in, default off). The GPU clock is another agent's work.
Evidence: `logs/usblog-20261103-000638.txt`, read-only SSH on the running boot, code of the built tree. **No flash, no adb, no restart. Nothing here has booted.**
Marks: [V] read in a log, code, or measured on the phone. [I] inference. [U] unknown.

## 1. Ranked causes

| # | Cause | Numbers | Fix | Needs | Mark |
|---|---|---|---|---|---|
| 1 | Jetsam kill loops: daemons die at 6-10 MB and restart | At rest ended tasks take 32-35 s of 61-66 s a minute: **53 % of all CPU**. In the storm 197 and 285 s of 461. 52 min: deviceaccessd 278 kills, gamepolicyd 271, liveactivitiesd 204, linkd 34, intents_helper 29. Memory is there: 715 MiB free | Floors in `JETSAM_FLOORS`, commit f3cb706 | New root, or copy the plist + reboot | [V] numbers; [I] that the ended tasks are these loops |
| 2 | Root disk: one UFS slot, one mutex over command and copy; each wait spins a CPU; read-ahead stops its caller | dd on `/dev/rufsroot0`: 16 KiB: 1 reader 40 MB/s, 4 readers 44 MB/s in all. 4 KiB: 13 and 17 MB/s. 1 MiB: 144 MB/s. Pageins 787 MB | 2970, 2971 | New kernel | [V] numbers; gain on the phone [U]: the host test gives 3.4-4.1 times with 4 readers on a fake device |
| 3 | backboardd: the frame waits for the GPU on the CPU (`NEGRONIMETAL_SYNC=1`), though the presenter waits for the same fence | A frame = CPU 9 ms + GPU 25-40 ms. Without the wait: the larger of the two: 34-49 ms -> 25-40 ms, about 20-25 % more frames | commit 8a25c38 | Plug-in file copy, restart backboardd | [V] the wait; [I] the gain; [U] half-drawn frames |
| 4 | Governor: edges only, no cap on a loaded core. 120 ms from idle to the top; 80 ms of it at 300-650 MHz. Gold 14 s a minute at 1401-1804 MHz while the UI moves. Touch held Silver at 1305 MHz | Under load 2016:60, 1804:60 [V] | 2972: 40 ms; touch holds both caps; GPU work holds Gold's | New kernel | [V] rows; [I] gain. Cost: power |
| 5 | SPMI: a waiter for the lock spins with interrupts off, up to 5 ms | Bound from the code | 2973 | New kernel | [V] code; not shown to be the cause of the late CPU |
| 6 | cryptexd: libimage4 panics with no `/chosen/manifest-properties` | 35 crashes in 52 min, each under 1 s: a small cost | Empty nodes, as N104AP has them with zeros, commit b955737 | New boot image | [V] cause; [U] the next property it asks for |

**Expected together [I]:** at rest about half of today's CPU use goes away. Cold starts (boot, an app's first launch) wait less for pages. Not measured until a boot.

### What fills a 6 MB limit

Open question of `ios26-gpu-lag.md` section 4, answered [V `footprint` on the phone]:

| Daemon | Footprint | CoreServices (LaunchServices store) | Page table | MALLOC | `__DATA_DIRTY` |
|---|---:|---:|---:|---:|---:|
| liveactivitiesd | 11 MB | **6,624 KB** | 566 KB | 1,680 KB | 855 KB |
| nehelper | 5,334 KB | **3,136 KB** | 406 KB | 736 KB | 386 KB |
| tccd | 2,261 KB | none | 341 KB | 704 KB | 459 KB |

So a daemon that maps the store is at 5-11 MB before it does any work. Why the region is dirty here and how large it is on a real iPhone 11: [U]. Floors: 24 MB with the store, 16 MB for those that crossed once or twice.

## 2. Found: not a limit

| Item | Evidence | Mark |
|---|---|---|
| Scheduler | `kern.sched: edge`; `hw.perflevel0` 4 Performance 1 MiB L2, `perflevel1` 4 Efficiency 512 KiB L2; `hw.ncpu` 8; `kern.sched_recommended_cores` -1 | [V] |
| P/E use without CLPC | All thread groups prefer the boot pset (Gold). P to E: spill weight 64 us of load. Idle Silver takes any excess: `sched_edge_pset_steal_thread`. Idle Gold pulls foreign threads back. E to P: no spill, but nothing prefers E. CPUs 461 of 480 s busy in the storm: work-conserving | [V] code, numbers |
| QoS | Background threads prefer Gold too, as everything does; a higher QoS preempts them by the per-bucket load. No SFI windows, no CPU limit, no bind. `qos_max_parallelism`: 4 for BG and maintenance, 8 for others. A change (BG to Silver) moves work, adds no capacity: not done | [V] code, [I] |
| Deferred IPI | No `HAS_IPI`: `ml_cpu_signal_deferred_get_timer` 0, so immediate | [V] code |
| Idle states | WFI only (0288 not ported): no long exit | [V] |
| Busy core below max | 2016:60 and 1804:60 under load; thermal caps never acted: 80 C max, cap at 95 C | [V] |
| RedwoodGPU lock | A mutex, not a spin lock. `a submission: 0 us before the lock` in nearly all windows, most 99 us. Held 800 us to 10.7 ms, no one waits | [V] |
| Surface pushes, buffer naming, MDP flips, stats | Under `IOLock` or no lock: interrupts on. `LAUREL` stats parse in a thread | [V] code |
| Console | `printf` drains with preemption on. Scroll holds a ticket lock, with interrupts on. fbcon wraps, no scroll. 10 lines/s: under 0.1 % | [V] code, [I] |
| USB log | 1,000 to 2,241 polls/s; kernel_task 5 s a minute: 1 % of the CPUs. A debug channel: kept | [V] |
| LSE, PAC traps | 570 LSE/s at about 2 us: 0.1 % of a core. FP16: 136 M traps in all, about 270 s [I], only while backboardd draws on the CPU; flat on Metal | [V] counts |
| Rayon, thread limits | No rayon in m2v's runtime; no `RAYON_*`, `TU_DEBUG`, `MESA_*` in `/var/db/negronimetal/env` (2 lines: open time, strikes). Pipeline makings: 4 at a time on 8 threads (`budget.rs`), and compile is not the cost: 3 to 15 pipelines in 14 to 93 ms | [V] |
| Thread QoS in the plug-in | User-initiated for compiles, utility for its own timers only | [V] |
| launchd plists | No CPU limit or `LowPriorityIO` of ours: the root adds floors and drops, nothing else | [V] spec |

## 3. Open

| Item | State | Mark |
|---|---|---|
| Why CPU 5 held interrupts over 12.5 ms | Not found. Panic in boot 11: right after `CRASH deviceaccessd`, `crossed memory high watermark`: a kill loop asks for corpses, so floors remove most of the triggers [I]. In our code only SPMI and kprintf mask interrupts by hand; kprintf draws a line in about 100 us at speed, 700 us at Silver's 300 MHz [I]. Not excluded: TrustZone calls, xnu's own paths. `kern.interrupt_masked_debug_mode` is 0, so no number exists. `LAUREL DEBUG ACK` gives the CPU when it happens again | [U] |
| CPU 4 not alive, boot 6 | Once, 18:49:20 on 2026-11-02: one boot of the 3 in `usblog-20261102-172222` (the logs `ios26-boot6` to `ios26-boot8` are cuts of it). PSCI `CPU_ON rc=0`, no `entered initCPU`, off after 5 s, 7 CPUs for that boot. Boot 11: 8 of 8 alive; the logs of boots 9 and 10 begin after this point [U]. A second CPU_ON would answer ALREADY_ON [I]: no fix made | [U] |
| DDR | `ddr.boot_mhz=1355 ddr.vote_mhz=0`: fixed. Stock Gold 2016 goes with 1804 MHz. A limit on all compute, 25 % bandwidth [I]. Near the GPU clock work: not touched | [V] value, [I] effect |
| UFS gear | 144 MB/s at 1 MiB looks like one HS-G1 lane [I]. The line `LAUREL UFS QUEUE: on:` gives gear and lanes on the next boot. A gear change needs PHY work | [U] |
| Writes | Still one slot, in the caller's thread, by choice: the fence and HFS order stay as they were | [V] |
| DEVELOPMENT kernel | asserts and `lock_stats` are in. Cost [U]. RELEASE gates boot-args and sysctls we use: not tried | [U] |
| GPU wait in the kernel | `delay_for_interval(200 us)`: see `ios26-gpu-lag.md` | [V] |

## 4. Tests [V host]

```
scripts/laurel/test-ufs-queue.sh   16 KiB reads on a fake host: 3.4-4.1 times the rate with 4 readers; off on error, timeout, wrong data; PASS, 3 of 3 runs
real sweet_ufs.c over a RAM disk   42809 checks passed, 0 failed
scripts/laurel/gov-test.sh         top row 40 ms from idle, was 120 ms
ios26-root-spec.py --self-test     passed; floors applied to the phone's plist by hand: every limit raised, none lowered
mkadt.py --donor n104ap            the nodes are in; iOS 16 ADT unchanged
```

Not run: the plug-in was not compiled here (preprocessor nesting checked). Nothing proves the phone.

## 5. Next boot: lines to read

```
LAUREL UFS WAIT: on: ...
LAUREL UFS QUEUE: on: 7 read slots of N, ...; link: gear G, L lanes, mode 0xMM     (a line of `off:` says why)
LAUREL UFS QUEUE: on: last minute: R reads, M MB, U us a read, at most K at once   K > 1 in the storm
LAUREL CPUFREQ: on: OSM governor 40 ms tick, a core full for one tick goes to the cap ...
LAUREL COMPOSITOR SYNC: on: the CPU goes on, the presenter waits for the GPU fence   then look for half-drawn frames; kill switch: file /var/db/negronimetal/sync
LAUREL CPU TOP: 60 s, busy B s of 480 ... ended tasks E                             E far below 32 at rest
```
Kill switches: `ufsqueue=0`, `ufswait=0`, the file `sync`. Bench over SSH (read only): the 4 parallel `dd` of section 1.
