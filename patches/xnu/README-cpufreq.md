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
