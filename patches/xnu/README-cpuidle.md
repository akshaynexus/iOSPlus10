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
