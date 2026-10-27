# CPU idle states (patch 0288, `negronicpuidle`, kernel default 0)

Status (2026-10-26): written, built (see the end), **not booted**. Build-only: the phone runs Android.

## Before 0288 [V code]
- `machine_idle()` -> `Idle_context()` -> `cpu_idle()` (osfmk/arm64/cpu.c): `cpu_idle_notify` is NULL (NegroniCPU does not
  set `processor_idle`), `platform_cache_idle_enter()` is empty on non-Apple parts (osfmk/arm/caches.c), then a plain
  `WFI`. No PSCI CPU_SUSPEND anywhere; PSCI is used only for CPU_ON (NegroniCPU.cpp), SYSTEM_RESET/OFF (negroni_reboot.c).
- XNU already has the deep-idle return path: `cpu_machine_idle_init()` sets every core's `cpu_reset_handler` to
  `resume_idle_cpu`; a core that resets in idle goes reset vector -> `resume_idle_cpu` -> `start_cpu` (MMU, stacks) ->
  `arm_init_idle_cpu` (current thread, CNTKCTL, TLB, CNTV_CTL) -> `cpu_idle_exit(TRUE)` -> `Idle_load_context` (the idle
  thread's registers, saved on its kernel stack by `Idle_context`).

## The phone's states [V out/live.dts]
| Node (live.dts line) | Cores | idle-state-name | arm,psci-suspend-param | entry / exit / min-residency (us) |
|---|---|---|---|---|
| silver-c4 (735-744) | cpu@0..300 (`cpu-idle-states = <0x04>`, 512-588) | rail-pc | 0x40000004 | 800 / 750 / 4090, local-timer-stop |
| gold-c4 (746-755) | cpu@400..700 (`<0x0d>`, 600-673) | rail-pc | 0x40000004 | 600 / 1550 / 4791, local-timer-stop |
| cluster-d4 (757-765) | psci cluster-pd `domain-idle-states` (1264-1272) | l3-off | 0x41000044 | 1050 / 2500 / 5309 |
| cluster-e3 (767-775) | same | llcc-off | 0x4100c344 | 2700 / 3500 / 13959 |

- `psci { compatible = "arm,psci-1.0"; method = "smc"; }` (1217-1219) with cpu-pd0..7 -> cluster-pd: the hierarchical
  (OS-initiated) layout of Linux cpuidle-psci-domain.c. The params are in the extended StateID format (bit 30 power-down,
  StateID bits 27:0; the cluster params contain the core's 0x4).
- `timer@17420000` "arm,armv7-timer-mem" (1344-1357): frame 0 at 0x17421000, interrupts GIC_SPI 8 (physical) and 6
  (virtual); frames 1-6 disabled. Linux's broadcast timer for the `local-timer-stop` states.
- No `qcom,lpm-levels` node in this kernel generation: the 5.10 OnePlus kernel uses cpuidle-psci + the qcom-lpm governor
  (drivers/cpuidle/governors/qcom-lpm.c) and `qcom,lpm-cluster-dev` (live.dts 10573-10576).

## Linux reference (out/src/op-kernel, `scripts/setup/fetch-gpur-cpuidle-sources.sh`) [V code]
- drivers/firmware/psci/psci.c:578-592 `psci_1_0_init`: OSI supported -> "Default to PC mode" (SET_SUSPEND_MODE PC).
- drivers/cpuidle/cpuidle-psci-domain.c:223-264: OSI is switched on only for the hierarchical domains; cpuidle-psci.c:192-193.
- drivers/cpuidle/dt_idle_states.c:81-82: `local-timer-stop` -> CPUIDLE_FLAG_TIMER_STOP (tick broadcast around the state).
- cpuidle-psci.c:52-102: `cpu_pm_enter()` (GIC CPU interface state, timers) -> `psci_cpu_suspend_enter(state)`.

## What 0288 does
Files: `osfmk/arm64/negroni_cpuidle.c` (new, `osfmk/conf/files.arm64`), `osfmk/arm64/cpu.c` (two hooks),
`osfmk/arm64/sleh.c` (the wake-timer IRQ), `pexpert/arm/pe_fiq.c` (SPI enable/route), `iokit/Kernel/arm/NegroniCPU.cpp`
(init after all cores run).
- `negronicpuidle=0` (default): one line `NEGRONI CPUIDLE: level 0: WFI only`, nothing else changes (no SMC, no mapping).
- `=1`: PSCI probe (VERSION, FEATURES(CPU_SUSPEND): bit 1 = extended StateID must be set, else WFI only; bit 0 = OSI, logged
  (PSCI 1.0, Linux include/uapi/linux/psci.h PSCI_1_0_FEATURES_CPU_SUSPEND_PF bit 1, PSCI_1_0_OS_INITIATED bit 0);
  FEATURES(SET_SUSPEND_MODE) logged). Platform-coordinated mode is kept. In `cpu_idle()` the WFI becomes
  `negroni_cpuidle_idle()`: if the next timer deadline (`rtcPop`) is at least the core's residency away (silver 4090 us,
  gold 4791 us), `CPU_SUSPEND(0x40000004, entry = negroni_secondary_entry PA, context = cpu)`, else WFI.
  A return = no power-down (counted `returned` / `denied`; INVALID_PARAMETERS disables that state on that core).
  The power-down comes back through XNU's path above; `cpu_idle_exit(TRUE)` first calls `negroni_cpuidle_resume()`:
  `PE_init_cpu()` (GICR wake + ICC_* registers, as Linux gic_cpu_sys_reg_init) and `setPop(rtcPop)` (the timer compare).
- `=2`: + the cluster params (0x41000044 at >= 5309 us, 0x4100c344 at >= 13959 us). In PC mode the firmware enters the
  cluster state only when every core of the cluster asked for it; a core alone gets its own power-down.
- Wake timer (`negronicpuidle_bcast`, default 1): frame 0's CNTACR0 set to all (as Linux), its CNTP compare = the
  earliest (deadline - exit latency) of the cores that are down (+ the measured CNTPCT - CNTVCT offset), INTID 40 routed
  by GICD_IROUTER to that core. The IRQ (sleh.c) IPIs every core whose time came and re-arms. A frame that does not
  answer as expected (CNTTIDR, CNTACR readback, CTL) -> WFI only.
- Guard: 3 power-downs in a row shorter than the residency -> the next 8 idles of that core are WFI.
- `negronicpuidle_mask` (default 0xff): the cores that may power down (bisect a bad core type: 0x0f = A510s only).

## Boot-args
| Boot-arg | Default | Meaning |
|---|---|---|
| `negronicpuidle` | 0 | 0 = WFI only (one log line, no SMC); 1 = core rail-pc (0x40000004) when the next deadline is >= the residency; 2 = + cluster l3-off / llcc-off |
| `negronicpuidle_mask` | 0xff | the cores (bit per logical CPU) that may power down; 0x0f = the A510s only |
| `negronicpuidle_bcast` | 1 | the frame-0 timer wakes cores that are down; 0 = no wake timer (tests only: a core may oversleep its timer) |

## Log lines
- `NEGRONI CPUIDLE: PSCI version 1.x, CPU_SUSPEND features 0x.. (extended StateID, OSI ...), SET_SUSPEND_MODE ...`: expected 0x2
  or 0x3 (bit 1 extended StateID; bit 0 OSI)
- `NEGRONI CPUIDLE: wake timer frame 0 at 0x17421000: CNTTIDR .. CNTNSAR .. CNTACR0 .. CTL .., CNTPCT - CNTVCT = N ticks: usable, INTID 40`
- `NEGRONI CPUIDLE: level 1, cores 0xff (of 8), entry 0x..., wake timer on; silver param 0x40000004 (exit 750 us, residency 4090 us), gold ...`
- After 10 s, then every 60 s, per core and state: `NEGRONI CPUIDLE: cpuN state S param 0x40000004 (silver-c4 rail-pc)
  entered N times (+N in 60 s): resumed N (+N), returned N, denied N (last rc R), short N, down N ms (N%), bcast wakes N`
  and `NEGRONI CPUIDLE: wake timer: N interrupts, armed yes|no, target cpuN`.

## Measurement
1. Idle %: the 0284 line (`NEGRONI CPUFREQ: d0 N MHz busy N% ...`, WATCH `cpu N/N/N MHz`): busy % should not change
   (idle stays idle); `down N%` of each core shows how much of the idle time is power-down.
2. Battery current at idle, screen off, 5 min: the 0271/0276 battery line (ibat) with `negronicpuidle=0` vs `=1` vs `=2`.
3. Latency: UI touch response and the FB STAT `late ticks` must not get worse (exit latency 750-1550 us, 2500-3500 us for
   the cluster states).

## Risks [I]
- A wrong param or a firmware that does not return to the entry point hangs a core; the watchdog is off (`wdt=-1`), so
  nothing reboots. That is why the kernel default stays 0 for this first build; the test image `out/ios16-gpur` has `=1`.
- Gunyah (the hypervisor under XNU, `NEGRONI_VTIMER_INTID` 19 is its virtual timer PPI) traps the SMC and implements PSCI
  for the VM: it may answer FEATURES differently, may keep the vCPU's virtual timer running across the suspend (then the
  wake timer is only a second source), or may not give the frame-0 timer / SPI 40 to the VM (then `NOT USABLE` -> WFI).
- State the reset path does not restore: PMU/KPC (not used on NEGRONI), debug registers (arm_debug_set(NULL) is in
  arm_init_idle_cpu), coresight (none in the ADT).
- A timer deadline that moves earlier while a core is down (a timer armed on that core from another core) is caught only
  by an IPI: XNU sends one when it enqueues a timer for a remote core's queue? [I: not checked]; the 60 s line's `short`
  and `bcast wakes` numbers show unexpected wakes, missed ones show as late timers (FB `late ticks`, UI stalls).

## Build
- 2026-10-26 18:21: kernel `out/kernel/local-20261026-125146` (sha256 8f1af35996a7ca6347fbd582630db17369831de58b1af736265884b527c0e9b2).
- 2026-10-26 18:47 (with 0298): kernel `out/kernel/local-20261026-131716` (sha256 7804fca89c4e08e9a1a75f9bc3ba70e3be9171442c6e09d50072afa5ce80332a),
  image `out/ios16-gpur` (boot_a 526eba93e7e6b7a20e56ba767ea26fc2c011fde4e7cd22a46a4d28b491b3d066, `negronicpuidle=1`).
- 2026-10-26 23:14 (review fix F1: FEATURES bit 1 = extended StateID, bit 0 = OSI; F3 `dc cvac` of the core record): kernel
  `out/kernel/local-20261026-174403` (sha256 dfa9a8a550ecc79d89b7478f1c3217850b55efb9c8cacd124893cf26346e887e), no image. The earlier
  kernels read the bits swapped: there `negronicpuidle=1` would fall back to WFI.
- compile-one: negroni_cpuidle.c, cpu.c, sleh.c, pe_fiq.c, NegroniCPU.cpp: 0 errors. Not booted.

## 0383: cluster states as Linux (OSI), RPMh sleep/wake sets, sleep statistics (2026-10-27, power kernel agent)

### Findings
- [V logs] Every logged boot ran WFI only: logs/bootlog-3..13 and the usblogs have only `NEGRONI CPUIDLE: level 0`.
  The boot-args of bootlog-3..13 have no `negronicpuidle`. The usblog-20261026-233816 boots at 02:02/02:04/02:06 had
  `negronicpuidle=1`, but they were the flat-battery reboot loop (about 2 min each, early lines not captured, no
  60 s line). No log shows a PSCI probe line, a residency line or a stats line.
- [V Gunyah source, quic/gunyah-hypervisor hyp/vm/psci_osi + psci_common, fetched by
  `scripts/setup/fetch-rpmh-sleep-sources.sh` to out/src/gunyah] XNU runs as the HLOS VM. Gunyah answers
  FEATURES(CPU_SUSPEND) = 3 for the HLOS (OSI + extended StateID), starts the VM in PC mode, and puts Gunyah itself
  into OSI with the firmware. A vCPU in WFI stays "active" in the aggregation: `psci_osi_handle_idle_yield` does no
  CPU_SUSPEND while an affine vCPU is active. So with WFI only, the physical core only clock-gates: no core
  power-down, no L3 off, no APSS collapse.
- [V Gunyah source] CPU_SUSPEND with a power-down state: the vCPU blocks, Gunyah picks the shallowest state of the
  affine vCPUs; the last core of the cluster gets the cluster state = the shallowest over all VM groups. PC mode: the
  VM's cluster state = the shallowest system-level request of all its vCPUs (so 0288 level 2 is valid). OSI: the
  request is checked per level; a cluster request while another vCPU is active = DENIED (-3). SET_SUSPEND_MODE(OSI)
  is DENIED while another vCPU is inside a suspend state. After a power-down the vCPU is warm-reset to the entry point.
- [V live.dts + log] apps RSC DRV 2: `qcom,tcs-config` = ACTIVE 3, SLEEP 2, WAKE 2, CONTROL 0, FAST_PATH 1 = TCS 0-2,
  3-4, 5-6, 7; 8 TCS x 16 commands (`config=0x800c8104`); `solver=0x4010100` (bit 24 = 0: no HW solver, so the SW must
  write the SLEEP/WAKE sets; Linux does it at the cluster-pd PRE_OFF, rpmh_rsc_pd_cb, because rsc@17a00000 has
  `power-domains = <cluster-pd>`). negroni_rpmh.c before 0383 wrote only ACTIVE TCS.
- [V Linux rpmh.c is_req_valid] Linux writes a request to the sets only when sleep != wake. With Linux rules all our
  current votes have sleep == wake: rails (qcom,set = 3), ARC (rpmhpd non-AO), BCM (icc tag 0 = ALWAYS; BT/FP QUP votes
  are real bandwidth, not keepalive). So the missing sleep sets are NOT the main blocker. The main blocker is that the
  APSS never collapses (above). [I] Votes left in DRV 2 by UEFI cannot be seen (the ACTIVE TCS read idle with enable 0
  at our first use).
- [I] Wake sources in llcc-off/AOSS sleep: the PDC (live.dts pdc-ranges) is not programmed by XNU; SPI 8 (the frame-0
  timer) is not in the PDC map. Gunyah keeps the vCPU timers. If an interrupt that is not PDC-routed cannot wake the
  APSS from the deepest state, devices answer late. That is why llcc-off has its own boot-arg, default off.
- [I] Busy pollers (USB, glink, watch threads, other agents' work) wake cores often; residency 5.3 ms (l3-off) and
  14 ms (llcc-off) need idle gaps that long on all 8 cores.

### What 0383 does
Files: `osfmk/arm64/negroni_cpuidle.c`, `bsd/dev/negroni_rpmh.c`.
- `negronicpuidle=3`: SET_SUSPEND_MODE(OSI) at start, before any core suspends (Linux psci_set_osi_mode). The last
  core (all other cores inside CPU_SUSPEND, bit mask `ci_down_mask`) passes the cluster param when the earliest
  deadline of all cores is at least the cluster residency away (Linux genpd next wakeup). Other cores pass 0x40000004.
  DENIED -> counted, then 4 idles core-only. Switch refused or OSI not offered -> level 3 works as level 2 (PC).
- Level 2/3: before any cluster param, `negroni_rpmh_sleep_ready()` must be true (RPMh lock free, no ACTIVE or
  fast-path TCS busy, sets current); else the core param ("rpmh busy").
- `negronicpuidle_llcc=1` allows llcc-off (0x4100c344); default 0 = l3-off only.
- RPMh: a read-only dump of all 8 TCS at first use (`NEGRONI RPMH: 0383 TCSn ...`); a cache of each ACTIVE command;
  `negronirpmh_sleep` 0 (default, nothing written) / 1 (Linux rules: only sleep != wake, today 0 pairs: proves the
  path) / 2 (+ every ARC vote sleep level 0, every BCM vote sleep 0 = commit, not valid). Rails stay on in sleep
  (Wi-Fi/BT/USB PHY/touch need them; Linux qcom,set = 3). WAKE = ACTIVE value with response; written WAKE first, SLEEP
  last; on a write error the SLEEP enables are cleared; if that also fails, cluster states stay off.
  The sets are written in thread context after a changed vote (the APSS is awake then), not in the idle path.
  If the boot chain left SLEEP/WAKE commands, nothing is written (line says so).
- Stats (read-only, every 60 s, `negronicpuidle_stats` bits: 1 AOP rpmh stats, 2 DDR stats, 4 CPUSS counters;
  default 7 at level >= 1, 0 at level 0; at level 0 a given value starts a stats-only thread = WFI baseline).

### Boot-args (new)
| Boot-arg | Default | Meaning |
|---|---|---|
| `negronicpuidle=3` | (0) | 2 + OS-initiated mode, the last core picks the cluster state |
| `negronicpuidle_llcc` | 0 | 1 = allow llcc-off (cluster-e3, the APSS RSC sleep) at level 2/3 |
| `negronicpuidle_stats` | 7 at level >= 1, else 0 | 1 AOP rpmh stats, 2 DDR stats, 4 CPUSS hw counters |
| `negronirpmh_sleep` | 0 | 1 Linux sleep/wake rules, 2 + ARC/BCM sleep 0 |

### Log lines
- `NEGRONI CPUIDLE: SET_SUSPEND_MODE(OSI) rc 0: OS-initiated mode` (or `PC mode kept` / `OSI not offered`).
- `NEGRONI CPUIDLE: level 3, cores 0xff ..., cluster l3-off 0x41000044 (>= 5309 us), llcc-off ...`
- `NEGRONI CPUIDLE: rpmh sleep stats at 0x...` and `DDR stats at 0x...: magic 0xa1157a75, N entries`.
- every 60 s: the 0288 per-core lines (state 2 = l3-off, state 3 = llcc-off), then
  `NEGRONI CPUIDLE: cluster (OSI): last-core chances N, l3-off picks N, llcc-off picks N, too short N, rpmh busy N, denied N`,
  `NEGRONI RPMH: 0383 sleep/wake sets on|off, mode M, N cached votes, N sleep+wake pairs written, flushes N ...`,
  `NEGRONI CPUIDLE: rpmh stats (aosd = AOSS sleep / XO off, cxsd = CX collapse): aosd count N (+N) time N ms (+N ms), cxsd ..., ddr ...`,
  `NEGRONI CPUIDLE: ddr stats: lpm0x.. N (+N) ...`,
  `NEGRONI CPUIDLE: cpuss hw counters (...): C4 cpu0 N (+N, res +N) ... D4 cluster0 N (+N, res +N)`.
  [I] record names `aosd`/`cxsd`/`ddr` are the usual AOP names; the line prints the 4 characters it reads.

### Phone test plan (RAM boot, `fastboot boot`, one step at a time)
1. Baseline: `negronicpuidle=0 negronicpuidle_stats=7`, screen off 5 min. Expect the stats lines; aosd/cxsd `+0`
   (WFI only). `not readable` in the start lines: Gunyah does not map that region for the VM (no panic, the region
   stays off).
2. `negronicpuidle=1`: PSCI line with `CPU_SUSPEND features 0x3`, per-core `down %` > 0, C4 counters rise.
3. `negronicpuidle=3`: `SET_SUSPEND_MODE(OSI) rc 0`; cluster line: l3-off picks rise with the screen off, denied low;
   D4 counter rises.
4. `negronicpuidle=3 negronicpuidle_llcc=1`: llcc-off picks rise; watch aosd/cxsd `+N` with the screen off 5 min, and
   USB/touch/BT response after wake.
5. `+ negronirpmh_sleep=1`, then `=2`: the RPMh dump lines, `sleep/wake sets on`, pairs written (0 for mode 1,
   QUP/camera/ARC votes for mode 2), aosd/cxsd counts vs step 4, battery current (0271 line) vs step 1.
Bisect: any hang -> drop the last added arg. `negronicpuidle_mask=0x0f` limits power-down to the A510s (no cluster
states then in OSI).

### Risks
- [I] A wrong cluster param or a lost wake in llcc-off hangs the phone (wdt off): llcc and RPMh sleep are separate,
  default-off args.
- [I] Stats MMIO (0xc3f0000, 0x178c8000, 0x178cc000) is read by Linux in the same HLOS VM. ss_start reads the first
  and the last word of each region with the 0297 try-accessor first (`negroni_mmio_try_rd32`); a refused region is
  logged as `not readable` and stays off, no panic. (The everything image has `negronicpuidle=1`, so the stats are
  on there by default.)
- [I] `negronirpmh_sleep=2` drops camera BCM/ARC and QUP votes while the APSS sleeps: camera streaming and BT/FP UART
  RX during APSS sleep may fail. Mode 1 writes nothing today.
- [I] OSI races with a waking core give DENIED; bounded by the 4-idle backoff.

### Review (2026-10-27, Opus review agent): 3 fixes in the patch
- OSI last core: the down bit is now set with one atomic `fetch_or` before the pick, and the pick uses the old mask.
  Before, the bit was set after the pick: two cores that go idle together (coalesced timers) both saw the other one
  up, and the cluster stayed on for that idle period. Now exactly one core sees every other bit. A core whose pick
  gives WFI clears its bit at once (a cluster request in that window gets DENIED -> 4-idle backoff, as before).
- Stats: try-accessor probe of each region (see Risks); no panic when Gunyah does not map a region.
- RPMh flush failure: the WAKE enables are cleared too (SLEEP first). Before, a WAKE command left enabled was never
  rewritten and would send a stale value at each APSS wake, over a later ACTIVE vote for the same resource.
- Checked, no change: idle path takes no lock (rh_lock only loaded; bc_lock is the 0288 spin lock), no allocation,
  no printf; params 0x40000004 / 0x41000044 / 0x4100c344 = live.dts (Qualcomm composites, the same in OSI and PC);
  Gunyah DENIED (-3) on an OSI race, INVALID_PARAMETERS (-2) only from the platform validation; a power-down
  CPU_SUSPEND that is not BUSY always comes back through the entry point (Gunyah `vcpu_warm_reset` in `psci_suspend`),
  so 0383 adds no new resume path: level 3 uses the 0288 resume path, which has not run on the phone yet (test plan
  step 2 first). TCS 0-2/3-4/5-6/7 = tcs-config; MSGID, WAIT 0, enables, invalidate as Linux.
- [I] Not checked (closed code): the Gunyah platform StateID validation in OSI mode, and the APSS wake source in
  llcc-off (Gunyah/PDC). If the first RPMh dump shows inherited SLEEP/WAKE commands, do not use `negronicpuidle_llcc=1`:
  the hardware would send the boot chain's sets at the APSS sleep.

### Build
- 2026-10-27 16:42 (job `k0383`, all patches/xnu incl. 0384, only the 4 usual dxb skips): kernel
  `out/kernel/local-20261027-111225` (sha256 0a0f433450f4452cb430c6c00d715cb8853a118667b2dbf0e673349fa097498b). compile-one: negroni_cpuidle.c,
  negroni_rpmh.c 0 errors. Not booted.
