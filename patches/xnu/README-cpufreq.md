# CPU frequency governor (patch 0284)

Status 2026-10-26: written, built in the full set (`kernel-cpugov5` job, image `out/ios16-cpugov`). Not run on
the phone (it was off). Marks: **[V]** seen in source, DT, log or build. **[I]** inference.

| Patch | Files | What |
|---|---|---|
| `0284-negroni-cpufreq-governor.patch` | `bsd/dev/negroni_cpufreq.c` | a 100 ms kernel thread steps the EPSS row of each cluster from the busy share of its cores |
| | `bsd/dev/negroni_adreno.c` | `cpu N/N/N MHz` at the end of the `NEGRONI GPU WATCH` line (`negroni_cpufreq_mhz_line()`) |

Applies after slop 0096/0098 and after 0280 (its `negroni_cpufreq_cap()` hook stays the thermal upper bound).

## Before 0284

- [V] slop 0096/0098: at boot each domain is raised once to the top row not above `negronicpufreq_mhz`
  (default 3200, above every row) and never changed; a domain is never set below the row ABL left.
- [V] Boot 0097 (slop NOTES.md 2026-10-22): ABL rows d0 12, d1 17, d2 20. With the 2400 cap of 0096 the
  kernel set d1 row 15 (2342 MHz) and d2 row 14 (2400 MHz), both below the ABL rows, and the boot ran
  (SpringBoard, Safari). 0098 then stopped the lowering because ABL's rows were higher than the cap, not
  because of a fault.
- [V] The top rows: d0 (A510 x4) row 14 = 1785 MHz, d1 (A710 x3) row 17 = 2496 MHz, d2 (X2) row 20 =
  2995 MHz. The whole tables (MHz per row) are not in a log here; 0284 prints them at boot
  (`NEGRONI CPUFREQ: dN table (R rows, MHz): ...; ABL row A`).
- [V] 0280 `negroni_cpufreq_cap(mhz)` never goes below the ABL row: for d1/d2 (ABL row = top row) the
  thermal CPU cap of 0280 changes nothing. 0284 keeps that rule (see "Floor").

## Rows and MHz

| Domain | Cores | ABL row | Top row (0096) | Other rows seen |
|---|---|---|---|---|
| d0 | A510 x4 (cpu 0-3) | 12 [V] | 14 = 1785 MHz [V] | - |
| d1 | A710 x3 (cpu 4-6) | 17 [V] | 17 = 2496 MHz [V] | 15 = 2342 MHz [V] |
| d2 | X2 x1 (cpu 7) | 20 [V] | 20 = 2995 MHz [V] | 14 = 2400 MHz [V] |

[V] = boot 0097 log (slop NOTES.md 2026-10-22: `d0 row 12->14 1785 MHz, d1 17->15 2342 MHz, d2 20->14
2400 MHz`) and boot 0100 (`keeps ABL rows d1 2496 / d2 2995 MHz`). Each value is 19.2 MHz * lval (93, 122,
130, 125, 156). The full tables are in the EPSS hardware, not in any source on disk (no OnePlus/Linux file
has them: grep of out/src for 1785600/2995200 finds only a charger file) [V]. The MHz of the rows between
are not known yet; 0284 prints each table at boot (`dN table`).

## Registers, cross-checked [V]

OnePlus kernel `out/src/op-kernel/drivers/cpufreq/qcom-cpufreq-hw.c`, `cpufreq_qcom_epss_std_offsets`
(lines 104-110): ENABLE 0x0, FREQ_LUT 0x100, VOLT_LUT 0x200, PERF_STATE 0x320, CYCLE_CNTR 0x3c4,
DOMAIN_STATE 0x020 (the OSM table at lines 96-101 has PERF_STATE 0x920 / CYCLE_CNTR 0x9c0: not this SoC).
Row decode (lines 495-506): `src = [31:30]`, `lval = [7:0]`, freq = `xo_rate * lval` when src != 0, else
`cpu_hw_rate` = alternate clock / 2 (line 656, `CLK_HW_DIV 2`); the table ends at the first repeated
frequency (line 516). 0284 reads the rows the same way (`read_table()`: 19.2 MHz * lval, or 300 MHz for
src 0 [I: the alternate clock is GPLL0 600 MHz]). Domain bases 0x17d91000/92000/93000 and
`qcom,lut-row-size = <0x04>`: `out/live.dts` node `qcom,cpufreq-hw` (`qcom,cpufreq-hw-epss`), with the
`dcvsh0..2_int` interrupts (LMh) that 0284 does not use.

## The busy measure [V]

In the bsd build `struct processor` is opaque (the fields are `MACH_KERNEL_PRIVATE`), so 0284 calls two plain
C symbols: `cpu_to_processor(cpu_id)` (`osfmk/arm/cpu_common.c:706`) and `processor_cpu_load_info(p, ticks)`
(`osfmk/kern/processor.c:652`, prototype declared in the file). The latter adds the CPU's user, system and
idle ticks (`hz_tick_interval` = 10 ms) into `ticks[CPU_STATE_*]`, from `processor->pr_recount` through
`recount_processor_usage()` (`osfmk/kern/recount.c:972`, `ru_user_time_mach` + `ru_system_time_mach` and the
idle time). It is the function `host_statistics(HOST_CPU_LOAD_INFO)` sums into `cpu_ticks[]`
(`osfmk/kern/host.c:518`). busy % = (user + system + nice) * 100 / (all ticks) over the last 3 samples
(300 ms): a 10 ms tick on a 100 ms window would be 10 % steps with a 2-tick truncation error.


`cpu_id` and `phys_id` come from `ml_get_topology_info()->cpus[i]`; `phys_id` maps to the EPSS domain
(`domain_of()` of 0096: core 0-3 d0, 4-6 d1, 7 d2). The busy of a domain is the busiest core of the domain
(one busy thread raises its cluster).

## Policy

Every 100 ms, per domain, with `row` the EPSS PERF_STATE row we asked for last (a mutex keeps the governor
thread and the 0280 thermal thread from writing at the same time):

- (`negronicpufreq_hi` is clamped to 1..100, `negronicpufreq_lo` to at most hi - 1.)
- busy > `negronicpufreq_hi` (70 %): +1 row, up to the cap. The low-counter resets.
- busy < `negronicpufreq_lo` (30 %) for 3 ticks in a row (300 ms): -1 row, down to the floor.
- between: the row stays, the low-counter resets.
- Then the bounds hold: `row <= cap`, `row >= floor`. The write happens only on a change.

Cap: the smaller of `negronicpufreq_mhz` (boot) and the thermal cap of 0280 (`negroni_cpufreq_cap()`:
a row above a new cap is lowered at once, and the governor's `dom_cap_row` moves).

Floor (the lowest row the governor goes to): **the ABL row of each domain, always** (0098 rule).
`negronicpufreq_floor_mhz=N` can only raise the floor (to the highest row not above N MHz); a value below
the ABL row prints `dN negronicpufreq_floor_mhz=N is row R, below the ABL row A: floor stays A`.

The configured floor is kept in `cfg_floor_row`. A thermal cap (0280) sets the floor now to
`min(cfg_floor_row, cap row)`, so the configured floor comes back when the cap goes up again.

How a row below the ABL row is prevented (three checks, [V] in the code):

1. `gov_start()`: `floor = ABL row`, then `max(floor, row of negronicpufreq_floor_mhz)`.
2. The cap: `raise_domain()` sets `cap row = max(top row under negronicpufreq_mhz, ABL row)`;
   `negroni_cpufreq_cap()` (0280) keeps `top >= ABL row`. The floor is clamped to the cap, so it stays >= ABL.
3. `wr_perf_state()`, the one function that writes PERF_STATE after boot (governor and thermal cap), raises any
   row below `dom_abl_row[d]` to it before the write.

Effect with the boot 0097 ABL rows [I: 0284 prints the live rows]: d0 moves between rows 12..14, d1 and d2 do
not move (ABL row = top row). So the governor alone does not cool d1/d2; the LMh hardware throttle still does
(the `lmh N` value in the log line shows its limit). To lower d1/d2 a later patch must drop the 0098 rule;
boot 0097 ran d1 row 15 and d2 row 14 without a fault [V], which is evidence for that change, not a test of it.

## Boot-args

| Arg | Default | Meaning |
|---|---|---|
| `negronicpufreq_gov` | 1 | 0 = the one-shot raise of 0096/0098, no thread |
| `negronicpufreq_floor_mhz` | 0 (off) | raises the floor to the highest row not above N MHz; never below the ABL row |
| `negronicpufreq_hi` / `_lo` | 70 / 30 | the busy marks in % (`lo` is forced below `hi`) |
| `negronicpufreq`, `negronicpufreq_mhz` | 1, 3200 | as before (0096/0098) |

## Log lines

- `NEGRONI CPUFREQ: dN table (R rows, MHz): 300,...,1785; ABL row A` once per domain at start.
- `NEGRONI CPUFREQ: governor on (d0 rows 12..14 (M..1785 MHz), d1 rows 17..17 (2496..2496 MHz), d2 rows
  20..20 (2995..2995 MHz); up > 70%, down < 30% for 300 ms, tick 100 ms)`.
- `NEGRONI CPUFREQ: d0 N MHz busy N% lmh L | d1 N MHz busy N% lmh L | d2 N MHz busy N% lmh L` after a row
  change (at most one line a second: the state at that time, not each step) and once a minute (600 ticks). `N MHz` = the row asked for; `lmh L` = DOMAIN_STATE [7:0] * 19.2 MHz,
  the LMh limit (qcom-cpufreq-hw.c line 143, `dcvsh_freq_limit_show`); L below N = the hardware throttles.
- `NEGRONI CPUFREQ: governor off (negronicpufreq_gov=0): the rows stay` with gov=0.
- `NEGRONI CPUFREQ: domain N (C cores): row A -> B (cap M MHz)` from the thermal cap (0280), unchanged.
- `NEGRONI GPU WATCH ... | <thermal line> | cpu 1785/2496/2995 MHz` (the rows asked for d0/d1/d2).

## Risks

- No row below the ABL row (see "Floor"). If a boot is unstable: `negronicpufreq_gov=0` (the old one-shot).
- The busy counters: `recount_processor_usage()` brings the idle time up to date at each read, but the
  user/system time of a running thread counts only at its next context switch or quantum end
  [V osfmk/kern/recount.c:972; `thread_quantum_expire()` calls `recount_switch_thread()` at osfmk/kern/priority.c:146]:
  the lag is at most one quantum (10 ms).
- The thread reads 8 processors every 100 ms (a few hundred ns each) [I]: no measurable load.
- The 100 ms up-step from the floor (12) to the top (14) of d0 takes 2 ticks = 200 ms [I]. Raise `negronicpufreq_hi`/lower the tick if the UI stutters.

## Test (next boot)

1. Boot `out/ios16-cpugov`; check the `table` and `governor on` lines (rows and MHz per domain, the ABL rows).
2. Idle on the lock screen a minute: the minute line should show d0 at its floor (row 12) and busy < 30 %;
   compare `lmh` with the row MHz.
3. Open an app: `d0 ... MHz` lines go up within 1 s, then back down.
4. Compare `NEGRONI THERMAL` cpu C and the battery mA line (0271/0272) against the `ios16-pwr` boot.

## 0291: the floor option `negronicpufreq_floor=abl|lut` (2026-10-26)

Status: built in the full set (`pwr-build`), **not booted**. Default `abl` = the 0284 behaviour.

- `lut`: the lowest row of d1 (A710) and d2 (X2) is row 0 of their EPSS LUT instead of the ABL row (d1 17, d2 20:
  their top rows, boot 0097/0100 [V]). The governor can then step them down to the LUT minimum at idle, and the
  thermal cap (0280/0283, `negroni_cpufreq_cap(0)` = "deepest") really lowers them. d0 (A510, the boot cluster)
  keeps its ABL row (12) in both modes [I: no evidence for d0 below its ABL row].
- The three checks of 0284 use `dom_min_row[]` (ABL row, or 0 with `lut`): the floor (`gov_start`), the cap
  (`raise_domain`, `negroni_cpufreq_cap`) and `wr_perf_state()`.
- The LUT rows: [V] the hardware only (no source lists them); 0284 prints them at boot (`dN table (R rows, MHz):
  ...; ABL row A; floor row F (...)`). No 0284 boot has run yet, so the MHz of row 0 of d1/d2 are not known
  [I: 300 MHz class, the src 0 row of `read_table()`].
- Evidence for the change (audit item 2, section "Before 0284"): boot 0097 ran d1 row 15 (2342 MHz) and d2 row 14
  (2400 MHz), both below their ABL rows, through SpringBoard and Safari without a fault [V slop NOTES.md 2026-10-22].
  That is evidence, not a test of row 0.
- Owner decision: `lut` is opt-in per test image (for example `scripts/battery/build-pwr-image.sh pwr-lut
  "<args> negronicpufreq_floor=lut"`); the default stays `abl` until a boot shows the lowest rows run stable.
- New line: `NEGRONI CPUFREQ: floor lut (negronicpufreq_floor=lut): d0 row 12, d1 row 0, d2 row 0 (ABL rows 12/17/20)`.
- Risk [I]: the A710/X2 at their lowest row with a high load: the governor needs 100 ms per row up (18-21 rows to the
  top = ~2 s); lower `negronicpufreq_hi` or keep `abl` if the UI stutters.


## 0395: NEGRONI CPUPERF, core placement and a WALT/schedutil port (2026-10-27)

Status: written, compile-checked (`scripts/kernel/compile-one.sh` on a STAGE=0 tree with 0001-0390: `sched_prim.c`,
`negroni_cpufreq.c`, `negroni_cpuperf.c`, `negroni_touch.c` OK, no new warning). Not built in a full kernel. Not booted.

| Patch | Files | What |
|---|---|---|
| `0395-negroni-cpuperf.patch` | `osfmk/kern/sched_prim.c` | placement: a perf thread takes an idle A710/X2 first, other threads an idle A510 first |
| | `bsd/dev/negroni_cpuperf.c` (new, GPL-2.0-only) | perfcontrol client: busy time per CPU, WALT window demand, schedutil clock, input/frame boost, self-check |
| | `bsd/dev/negroni_cpufreq.c` | the governor thread runs the CPUPERF policy (20 ms) instead of the 0284 step; 0284 stays the fallback |
| | `bsd/dev/negroni_touch.c` | `negroni_cpuperf_input()` next to the 0389 `negroni_input_boost()` call |
| | `bsd/conf/files` | `negroni_cpuperf.c` |

Applies after 0389 (its `negroni_touch.c` line is the context of the touch hunk) and after 0284/0291.

### What the scheduler was [V]

- `config/MASTER.arm64`: `SCHED_BASE = config_sched_traditional config_sched_multiq config_clutch ...`. The build
  log has `-DCONFIG_CLUTCH -DCONFIG_SCHED_MULTIQ`, no `CONFIG_SCHED_EDGE`, no `__AMP__`.
- `pexpert/pexpert/arm64/board_config.h` (NEGRONI): `MAX_CPU_CLUSTERS 1`, so `__ARM_AMP__` is undefined.
- slop `tools/mkadt.py` (the ADT): every `cpu` node has `cluster-id 0` and `cluster-type 0` ("homogeneous
  CLUSTER_TYPE_SMP, not AMP"). There is one pset with 8 equal CPUs. QoS has no effect on the core kind.
- `choose_processor()` (osfmk/kern/sched_prim.c): an idle hint (the last CPU) wins, else `lsb_first(idle map)`, the
  lowest idle CPU. A realtime thread takes the lowest available CPU, busy or idle. So a woken thread goes to an
  A510 (cpu 0-3) when one is idle. The A710/X2 get work only when all four A510 are busy.
- Log `logs/usblog-20261027-171256.txt` (negronicpufreq_floor=lut): 2151 CPUFREQ lines, mean busy d0 56 %, d1 30 %,
  d2 18 %. d0 is the busiest domain in 84 % of the lines. The 0284 step (+1 row per 100 ms at > 70 %, -1 row per
  300 ms at < 30 %) then keeps d1 at 633 MHz and d2 at 806 MHz most of the time.

### Why not the Edge/AMP scheduler

A real AMP setup needs `MAX_CPU_CLUSTERS 3`, `cluster-type` 'E'/'P' in the ADT and the Edge scheduler. That code
expects Apple cluster IDs in MPIDR Aff1 (Qualcomm puts the core number there: slop 0065), per-cluster IPI/CTRR and
CLPC recommendations. That is a big risk for the RAM boot. 0395 keeps the SMP Clutch scheduler and only changes
which idle CPU is chosen. [I] A later patch can try AMP.

### Placement (osfmk/kern/sched_prim.c)

- perf thread: a user thread with `base_pri >= 37` (BASEPRI_USER_INITIATED: QoS USER_INITIATED, USER_INTERACTIVE,
  foreground app main threads at 47), or any realtime user thread. Kernel threads are never perf threads for the
  idle-CPU choice; the realtime rule below (an idle P core first) applies to every realtime thread, kernel ones too.
- `negroni_pick_cpu()` replaces `lsb_first(idle_primary_map)`: perf thread -> idle P core (cpu 4, 5, 6, then 7),
  other -> idle A510. With no idle CPU of that kind: any idle CPU, as before.
- `negroni_check_idle_hint()`: an idle hint of the wrong kind is replaced only when a CPU of the right kind is idle.
- Realtime: an idle P core, else any idle CPU, before the stock "lowest available" rule (which preempts).
- During an input boost the threshold is 31 (BASEPRI_DEFAULT), the analog of WALT `sched_boost_on_input`.
- `negroni_sched_pmask = 0` = the old behaviour. It is set only after the CPUPERF start passes.

### Android source and the mapping

Sources (pinned, sparse, `scripts/setup/fetch-cpuperf-sources.sh`): OnePlusOSS android_kernel_oneplus_sm8450 @ e9da5922
(`kernel/sched/walt/*`, `kernel/sched/cpufreq_schedutil.c`) and android_kernel_modules_and_devicetree_oneplus_sm8450 @
835109f6 (`vendor/oplus/kernel/cpu/sched/frame_boost/*`). GPL-2.0-only; `LICENSES/GPL-2.0.txt`, THIRD_PARTY_NOTICES section 9.

| Android (file: function / tunable) | Ours (`negroni_cpuperf.c`) | Value |
|---|---|---|
| walt.c `update_cpu_busy_time()` window busy (prev_runnable_sum) | `cp_oncore()`/`cp_offcore()`: exact on-core time per CPU (perfcontrol callouts; the idle thread has urgency NONE) | - |
| walt.c `sched_ravg_window` (20 ms at init; DEFAULT 16 ms) | window = governor tick `CP_WINDOW_MS` | 20 ms (100 ms dark) |
| walt.c `scale_exec_time()` (busy * cur/max freq) | work kHz = busy % * clock of the domain (row, or LMh limit when lower) | - |
| walt.c `sched_ravg_hist_size`, `WINDOW_STATS_MAX_RECENT_AVG` | demand = max(last window, mean of 5 windows), per CPU; domain = max of its CPUs | 5 |
| cpufreq_walt.c `walt_map_util_freq()` (1.25 * util, TARGET_LOAD 80) | want = demand * 100 / 80 | 80 % |
| cpufreq `cpufreq_driver_resolve_freq()` RELATION_L | `row_at_or_above()` in negroni_cpufreq.c | - |
| cpufreq_walt.c `hispeed_load` (DEFAULT 90) / `hispeed_freq` (0, set by vendor init) | busiest CPU >= 90 % -> at least `cp_hispeed_khz` | d0 none, d1 1555, d2 1401 MHz (ours) |
| cpufreq_walt.c `rtg_boost_freq` DEFAULT cpu0 1000000 / cpu4 768000 / cpu7 0 | a work interval from the domain in the last 50 ms | 1000 / 768 / 0 MHz |
| OPLUS frame_boost (late frame raises frame-group util) | work interval finished after its deadline -> hispeed 100 ms | 100 ms |
| cpufreq_walt.c `up_rate_limit_us` / `down_rate_limit_us` (0) | none; the 5-window mean makes the slow way down (~100 ms) | 0 |
| input-boost.c `input_boost_freq[]` (0, set by vendor init) | `cp_input_khz` | d0 none, d1 1555, d2 1401 MHz (ours) |
| input-boost.c `input_boost_ms` (sysctl default 40) | `CP_INPUT_BOOST_MS` | 150 ms (ours: 40 ms is 2 of our windows) |
| input-boost.c `MIN_INPUT_INTERVAL` 150 ms | `CP_MIN_INPUT_MS` | 150 ms |
| input-boost.c `sched_boost_on_input`, boost.c / walt.h `task_boost_policy()` SCHED_BOOST_ON_BIG | placement threshold 37 -> 31 while the input boost runs | - |
| core_ctl.c (core isolation), walt_lb.c, `pl` / `nl` predictive loads | not ported | - |
| vendor init (init.kernel.post_boot-*.sh, perfd/powerhint) | not in the pinned trees [V: `git ls-tree` of both repos] | - |

The values marked "ours" are not from the trees: the post_boot/powerhint files are not open source there.

### Bounds and power

- The row is the lowest row at or above `want`, then `<= dom_cap_row` (negronicpufreq_mhz and the 0280 thermal cap),
  `>= dom_floor_row` (ABL row, or row 0 of d1/d2 with 0291 `negronicpufreq_floor=lut`). `wr_perf_state()` is the
  one writer, as before. With the default `abl` floor d1/d2 stay at their top row (the floor is the top row): only
  `lut` lets them go down, so CPUPERF changes the d1/d2 clock only with `lut`. Placement works with both.
- LMh: the clock of the window is min(row, LMh limit). CPUPERF does not fight LMh.
- Display off (`negroni_display_asleep`, 0382): window 100 ms, no input/frame/rtg boost, d1/d2 at most 1209 MHz
  (never below the floor).

### Self-check and kill switches

- `negronicpuperf=0`: all of 0395 off; `negronicpuperf_place=0`: placement off, the clock policy stays.
- Start: the three EPSS domains mapped with tables, every cpu_id < 16, at least one A510 and one A710/X2 CPU.
- 500 ms later: the perfcontrol callouts must have run on some CPU. Else CPUPERF unregisters, turns placement off
  and 0284 runs.

### Log lines

- `NEGRONI CPUPERF: on (WALT/schedutil port: window 20 ms, history 5, target load 80%, hispeed 90% -> d1 1555/d2 1401 MHz,
  input boost 150 ms -> d1 1555/d2 1401 MHz + placement pri 31, frame boost 100 ms; dark: window 100 ms, d1/d2 cap 1209 MHz;
  placement on: P mask 0xf0 (pri >= 37, RT), E mask 0xf)`
- `NEGRONI CPUFREQ: governor on (d0 rows 12..14 (1574..1785 MHz), d1 rows 0..17 (633..2496 MHz), d2 rows 0..20 (806..2995 MHz);
  policy CPUPERF 0395, window 20 ms)` (the 0284 text when CPUPERF is off).
- `NEGRONI CPUFREQ: d0 N MHz busy N% lmh L | d1 ... | d2 ...`: unchanged format; busy = busiest CPU of the last
  20 ms window (was 300 ms); at most one change line a second, and a minute line.
- `NEGRONI CPUPERF: inputs N, frames N (late N), placed on P N / on E N, ticks: boost d1 N d2 N, hispeed d0 N d1 N d2 N, dark N`
  once a minute (counts since boot; "placed" = only placements where the old rule would choose another CPU).
- One of `NEGRONI CPUPERF: off: negronicpuperf=0 | negronicpufreq=0 | negronicpufreq_gov=0 | the EPSS domains 0-2 are not
  all mapped | N CPUs (1..16 supported) | no A510|A710/X2 cores in the CPU map | the scheduler made no perfcontrol callout
  in 500 ms; the 0284 governor runs`.

### Expected effect [I]

- UI threads (QoS >= USER_INITIATED) run on cpu 4-7. With `lut`, d1 goes from 633 MHz to its demand in one 20 ms
  window (no 100 ms step per row); a touch puts d1/d2 at >= 1555/1401 MHz for 150 ms.
- Background and kernel threads stay on the A510 when one is idle.
- More time on the A710/X2 costs power. The display-off cap and the A510-first rule for non-perf threads limit it.

### Risks for the RAM boot

- The callouts run at every context switch with interrupts off. They do a few loads and stores per call [V source].
- `sched_perfcontrol_register_callbacks()` was never called in this kernel before (no CLPC). Version 2 sets only
  offcore/oncore/work_interval_notify; the others keep the defaults [V machine_routines_common.c:173].
- If a hang or slow UI appears: `negronicpuperf=0` (back to 0284), or `negronicpuperf_place=0`.
- The placement threshold (31 during an input boost, else 37) is set again from `cp_boost_until` in every window, so a
  boost that a window did not see, or a reset that raced a new touch, cannot leave it at 31 (review fix).
- The busy read can count a short piece twice when a callout runs between two loads; it is clamped to the window.
- [I] If CoreAnimation does not use work intervals on iOS 16, `frames` stays 0 and only rtg/frame boost is unused.
