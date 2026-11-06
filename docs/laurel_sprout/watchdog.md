# Mi A3: APSS watchdog and stuck-CPU report

Date: 2026-11-03. Branch `t3/mi-a3-watchdog-stuck-cpu-audit`. Patches: `patches/laurel/xnu/2986-laurel-wdog.patch` (both kernels), `patches/laurel/xnu-12377/post/9015-laurel-wdog-sleh.patch` and `9016-laurel-debug-ack-late-cpu.patch` (iOS 26). Host test: `scripts/laurel/wdog-test.sh`.
Marks: [V] read in a log or code, or built. [I] inference. [U] unknown. **Nothing here has booted.**

## 1. Why

[V `logs/usblog-20261103-071332.txt`] Boot with kernel 353 patches: `LAUREL RPM SCALE: on` at 13:45:52. The log stops at 13:46:59 in `SWEET SURF: SpringBoard create id 47`. No panic. `op10tool ctl ping` has no pong. No SSH. USB stays enumerated. Only the Power button resets it. The last `LAUREL THERMAL` line: CPU 76.4 C, both clusters 100 %. The last `LAUREL CPU TOP`: busy 376.1 s of 480: this is 8 CPUs x 47 s, the first window of a boot, not a lost CPU [I].

## 2. Hardware and owner

| Item | Value | Mark |
|---|---|---|
| Node | `qcom,wdt@f017000`, `reg 0xf017000 0x1000`, `interrupts <0 3 0>, <0 4 0>` (bark SPI 3 = INTID 35, bite SPI 4), `qcom,bark-time 11000`, `qcom,pet-time 9360`, `qcom,ipi-ping`, `qcom,wakeup-enable` | [V trinket.dtsi:1188] |
| Registers | `RST 0x04`, `EN 0x08` (bit 0 enable, bit 1 unmasked interrupt), `STS 0x0c` (bits 1-20 count), `BARK 0x10`, `BITE 0x14`. 32765 Hz. 20 bits: at most 32 s | [V watchdog_v2.c] |
| Stock | Bark 11 s, bite bark + 3 s, pet 9.36 s. A thread calls each online CPU with a wait, then pets. A stuck CPU stops the thread | [V watchdog_v2.c] |
| Owner | Stock Linux writes these registers from EL1 NS on the same TrustZone, so it does not lock them from NS [I]. Self-check at start: our values must read back, the enable must hold, the counter must move. Else `LAUREL WDOG: off` | [V code] |
| The state at boot | The phone runs for hours and a hang does not reset: no one leaves it on under XNU [V 13:46:59]. The on line gives what it found: `found EN .. bark .. bite ..` | [V] |
| FIQ | Group 0 is TrustZone's [V `pe_fiq.c`]. No FIQ path is ours. A bark is an IRQ: it needs one CPU with interrupts on | [V] |
| Bite | A bite interrupt in TrustZone or a direct reset. What follows on this firmware: normal boot expected, as the cookie is clear after a clean reboot [I `msm-poweroff.c`; `xiaomi-trinket.config`: `# CONFIG_QCOM_DLOAD_MODE is not set`]. **[U] not seen on this phone** | see section 7 |

## 3. Feature

One line: `LAUREL WDOG: on: APSS WDT 0xf017000, bark 12 s (any CPU), bite 20 s, pet 1000 ms, a CPU silent 8000 ms stops the pet; found EN 0x0 bark 0x.. bite 0x..; laurelwdog=0`, or `LAUREL WDOG: off: REASON`. Kill switch: `laurelwdog=0`.

| What | How | Mark |
|---|---|---|
| Round | A kernel thread, priority 95, once a second: a `SIGPast` signal to each CPU in use. `SIGPast` has no slot and no spin [V `cpu_signal_internal`], unlike `cpu_xcall`, so a stuck CPU cannot catch the sender. | [V code] |
| Answer | `sleh_irq` stamps each CPU at each interrupt: time, interrupted pc and lr. The first interrupt after a signal closes it and records the answer time | [V code] |
| Pet | Only if no CPU in use has a signal open for 8 s, and no panic. A CPU that never came up (`SIGPdisabled`, the case `CPU 4 not alive`) is not in use | [V code, host test] |
| Bark | IRQ to any CPU (1-of-N; if the GIC refuses, the boot CPU). Two lines per CPU, then `panic("LAUREL WDOG: bark: ...")`. So the panic hold sends the text over USB, and its timed reset follows | [V code] |
| Bite | No pet for 20 s: the hardware resets with no CPU. This is what a hang of all CPUs gets | [V design], [U] on the phone |
| Panic | `kPEPanicBegin`: no pets, bark = bite = 30 s, count from 0. If the panic hangs before its hold: a bite. Panic hold, `laurel_panic_final`: hardware off, so **a hold does not reset**, except after a bark (patch 2987): the count runs on and the bite resets the phone 30 s after the panic [V code], [U] on the phone. Reason: at 17:56:16 a bark on stuck CPU 5 printed `holding`, then the hold gave no pong and took no `ctl bootloader` [V]. `laurel_restart`, `laurel_power_off`: off just before PSCI: ABL and Mu get no running count | [V code] |
| Lines | A CPU silent 2, 5, 10 s: 2 lines with its last interrupt, thread, signals, SGI state. `answers again` when it comes back. Each minute: `longest answer in 60 s, ms per CPU`, with the pc of the worst. The thread itself over 2 s late: one line per new worst. | [V code] |
| Fallback | Self-check failed: no hardware, the same thread and lines. The USB thread (`ud_thread`) also checks: the pet thread 3 s late gives a line, and it does a round | [V code] |

### Times

| Case | First line | Bark | Bite |
|---|---|---|---|
| All CPUs stop, or the thread stops | none if no CPU runs; else 3 s by USB thread | 12 s | **20 s** |
| One CPU stops with interrupts off | 2 s | 20 s | **28 s** |
| A panic in progress | | | 30 s after its start, until its hold |
| Panic hold, panic spin | | off | off |

### Check against the long stalls of this port

Margin: a stall must exceed 8 s on a CPU, or 12 s on the thread, to count.

| Stall | Longest | Interrupts | Source | Against the limit |
|---|---|---|---|---|
| Interrupt-off code of ours | SPMI: 5 ms wait (2973: interrupts on while waiting), about 1 ms per transaction | off | `sweet_spmi.c:104`, the only `ml_set_interrupts_enabled(FALSE)` in `bsd/dev/laurel*`, `sweet*`, `iokit/Kernel/arm` [V grep] | far under |
| Panel `kprintf` | 700 us a line at 300 MHz | off | cpu-parallel.md [I] | far under |
| UFS command | 5 s limit: a thread sleeps; spins only if interrupts are off | thread: on | `CMD_TIMEOUT_NS` [V]. Host test: a CPU off 5 s, no bark | under 8 s |
| Stackshot | 2 x 100 ms if a CPU is late; the walk itself takes a part of a second on one CPU [I]; no line says the time | off, all CPUs | post/9007, 9013 | far under; `this thread ran N ms` measures it |
| SCM | Modem `auth_and_reset`: 45-54 resumes [V log]: each resume returns to NS. Audio PAS 152-162 ms, zap 3-4 ms | NS interrupts between resumes | [V log] | far under |
| GPU zap before 2153 | Over 4 min in the secure world, CPU lost | | notes.md 2026-11-01. Fixed by the lock [V]. If this comes back, the watchdog resets, and that is right | a real hang |
| CPU bring-up | 5 s per dead CPU; it has `SIGPdisabled` | | `SweetCPU::startAll` | not counted |
| Sleeping waits (GPU 900 ms, flip 2 s, IOSleep, boot of 60+ s) | Any | on | The thread preempts them at priority 95 | not counted |
| Realtime threads on all 8 CPUs for 12 s | Not seen; would starve the thread | on | [I] | a true fault if so |
| Sleep (suspend) | None on this port: `SweetCPU::haltCPU` panics [V] | | | no case |

Measure on the first boot: `LAUREL WDOG: on: this thread ran N ms` must stay far under 12000.

## 4. Stuck-CPU report (`LAUREL DEBUG ACK`)

`ml_dbgwrap_*` needs `coresight_base[CORESIGHT_UTT]`: Apple's, 0 here: it answers `DBGWRAP_ERR_UNSUPPORTED` [V `dbgwrap.c`; nothing in the series sets it].
EDPCSR (CoreSight external debug) is the only register that gives the pc of a running CPU. **Not used.** It needs the QDSS clock from the RPM and the debug power domain. An access with these off can stop the bus [I], and a retail phone can read 0xffffffff for lack of authentication [I]. No self-check can test this before the first access, and the first access runs inside a hang report.

What the debugger path gives, read only and in `kprintf`:

```
LAUREL DEBUG ACK: on: stackshot given up: cpu 5 is late by over 1920000 ticks (time 1)
LAUREL DEBUG ACK: on: late cpu 5 mpidr 0x1: last interrupt 42 ms ago, 88123 in all, pc 0x.. lr 0x..; in a handler now: pc 0x0
LAUREL DEBUG ACK: on: late cpu 5 runs dasd/thread name; signals 0x.., SGI pending; longest answer this minute 3 ms at pc 0x..; slide 0x..
LAUREL DEBUG ACK: on: cpu 5 came 80 ms after the stackshot gave it up: pc 0x.. lr 0x.. fp 0x..
```

| Field | Meaning |
|---|---|
| `came ... pc` | The first point where that CPU let interrupts in: the end of the long section [I]. This is the answer we want. No such line: the CPU did not come back |
| `SGI pending` | The signal got there; the CPU has interrupts off, or is in the secure world |
| `SGI not pending` with `signals` that hold the debug bit | The signal is lost, or it is taken and in the handler now |
| `in a handler now` | Non-zero: inside an interrupt handler; the pc it interrupted |
| `runs` | Task and thread name, by copies that cannot fault. An idle thread with a pending SGI: stuck on the way in or out of idle |

Symbols: subtract `slide`, then `scripts/laurel/crash-bt-symbolize.py`.

## 5. Causes, ranked

| # | Candidate | Evidence | Mark | Next check |
|---|---|---|---|---|
| 1 | First live bus and DDR scaling under load (2985): an RPM or NoC switch stalls all DRAM masters: all CPUs and USB stop together, no code runs | Hang 67 s after `LAUREL RPM SCALE: on`, past the 30 s mark of the guard. It is the only one found that stops all CPUs at once. Against: many boots since 08:18 ran with it, one hang in the log [V] | [V] timing, [I] mechanism, [U] why | `rpmscale=0`, same storm. With the watchdog a bite shows it: no `silent` line first |
| 2 | One CPU stuck in a register read (MCCC `0x220` in `ddr_mhz`, GPU register with its clock off), or in TrustZone: then a lock it holds spreads the hang | Reads have no bound in hardware. `kern.laurel_stats` reads MCCC. [V] audit | [I], [U] if it stalls | `silent` lines name the first CPU, and its last pc |
| 3 | CPU 5 itself | **12 of 12 stackshots given up, in 4 boots, name CPU 5 first; only the one at 07:25:51 also lists others** [V log]. An agent saw it at 0 % busy. No thread is bound to it [V grep]. A CPU in the secure world has no ticks, so 0 % [I, notes 2026-11-01]. `CPU 4 not alive` in boot 6 is the next core: same cluster [V]; link [U] | [V] counts, [U] cause | The new `LAUREL DEBUG ACK` lines and the minute line |
| 4 | RCG on a stopped PLL (2961) after a failed switch, then a GPU read | Only after a `rcg_set` that fails; it should log `MHz out` first | [I], unlikely | Log line |
| 5 | Peak current or heat: both clusters at the cap with 2972 | 76 C, caps at 95 C: not thermal. Power: nothing measured | [U] | |

Not the cause, on this evidence: 1 lost CPU over the whole boot (the 376 s of 480 is 8 x 47 s).

## 6. Audit of today's patches

Spin or wait with interrupts off and no timeout. Details [V tree of this branch]. GPU patches: read by a second agent, in code only.

| Patch | Result | Bounds |
|---|---|---|
| 2970 UFS sleep | No hang path. The mutex stays held over the sleep, as it was over the spin | 5 s deadline, sleep only with interrupts on, preemption on, outside an interrupt; else `delay(1)` |
| 2972 governor | No hang path | No loop; `wr_row` is one write, with no poll. Cost: more peak power [U] |
| 2973 SPMI waiter | No hang path. Better than before | 5 ms deadline; interrupts on while it waits; `emergency` goes on with no lock. Holder 1 ms |
| 2975 GPU time | No hang path | Fixed table |
| 2976 kept buffers | No hang path | Loops end by size; each lock has one unlock per path |
| 2977 push outside the lock | No hang path. Order `fSubmitLock > gGPULock > hw_lock`, no reverse found. All are sleeping locks: a deadlock there would sleep, not stop USB | Each exit of `submit` unlocks. New: up to 8 CPUs flush caches at once: load, bounded |
| 2978 table runs | No hang path | No waits; `tlb_flush` 1000 reads, older |
| 2981 flip | No hang path | `gpuWait` 900 ms, drops its lock; SwapEnd 2 s |
| 2982 fence at swap | No hang path | No loop |
| 2985 RPM | No loop hangs: `wait_for` 1 s, `rs_read_rise` 205 ms. **The hardware may: candidate 1.** A guard exists but clears after 30 s | |
| 9013 single thread | No unbounded spin: with `stackshot_single_thread=1`, `scc_can_work` is false for all but the caller, so no CPU enters the `SS_SETUP` loop [V `kern_stackshot.c:6155, 6266`]. `debugger_sync` can go off by one if a late CPU lands in the next stackshot: that stackshot then runs with one CPU not stopped: no hang [I]. 200 ms interrupts off on the caller for each give-up. Kill switch `=0` brings back the spin risk: do not use | 100 ms + 100 ms |
| 2961 GPU OPP | Polls bounded (PLL 200 reads, RCG 500 reads, 10 ms, 50 ms). Candidate 4 only | |
| `cpu_xcall` (XNU, not a patch) | Slot wait has `xcall_ack_timeout` and a panic: no hang [V `cpu_common.c`] | |
| `delay()` with interrupts off | `machine_delay_until` is WFE: it needs the event stream; `wfe_timeout_init` runs on each CPU [V `arm_init.c:391, 776, 879`]: no hang | |

## 7. First boot: the risk, and the way back

| Risk | Result | Way back |
|---|---|---|
| A wrong bite, each boot | Boot loop | **The boot menu shows; with no key, ABL's retries of slot b end after at most 7 boots and the phone is on Android, with no computer** (`boot-menu.md` section 4). A key press in the menu refills them, so do not press one if you want Android; or pick "Android" |
| Turn it off | `EXTRA_ARGS=laurelwdog=0 scripts/laurel/uefi-image.sh`, then the owner flashes `boot_b` (or uses `fastboot boot`) | A kernel with the same args: no hardware write, no thread |
| The access itself | [I] none: stock writes the same registers. If an XPU refuses: a bus fault at `LAUREL WDOG` in boot: a panic, the hold, then the same way back | The same |
| A bite ends in a dump mode | [U]. `xiaomi-trinket.config` has no DLOAD, so Android does not set the cookie [V]. The debug image (SDI) is bypassed by stock only before a clean reset (`scm_disable_sdi`); it can run at a bite [V code], and on a retail phone [U]. If the phone stays dark or shows USB 9008 or 900E: hold Power | Hold Power until it resets |
| Lost cause text | A hang of all CPUs gives no line: the log just stops, then a new boot [V design] | Compare the time stamps: a stop, then a boot 20 s later = a bite |

No IMEM guard against a boot loop: `LAUREL REBOOT: on: ... (was 0x00000000)`, 3 of 3 boots in the log [V], so the word may not survive a hard reset, and 2985 uses the same word. ABL's count does this job already.

## 8. Lines to read on the first boot

```
LAUREL WDOG: on: APSS WDT ...                                  or off: REASON
LAUREL WDOG: on: this thread ran N ms after its last run ...   N far under 12000
LAUREL WDOG: on: longest answer in 60 s, ms per CPU: 0 1 0 ...; cpu 5 at pc 0x..   once a minute: the masked sections of each CPU, with no stackshot
LAUREL WDOG: on: silent 2000 ms: cpu N ...                     a stuck CPU before a bite
LAUREL WDOG: bark: cpu N ...  then panic(...LAUREL WDOG: bark...)
```

Host test [V]: `scripts/laurel/wdog-test.sh`: PASS: healthy 1 h no bark; a CPU off 5 s, a slow stackshot, the thread 10 s late, a CPU not in use: no bark. One stuck CPU at 60 s: bark 79.1 s, bite 87.1 s. All stop at 60 s: bite 79.1 s.

## First catch, 2026-11-03 17:56:16, kernel 833d75cdc9 [V]

CPU 5 (mpidr 0x1, silver) took its last interrupt in EL0 of `iconservicesagent`, pc 0x19dc52724 lr 0x19dbee774 (the pc of that interrupt, so it can be stale), then stayed silent 19562 ms with an SGI pending. The other 7 CPUs ran. `iconservicesagent` had started 6 s earlier and opened Metal. The hang of 13:46:59 also has `iconservicesagent` in its last lines (a link [I], two events). Cause [U].

## 9. The first catch, read against the code (branch `t3/ios26-frame-gap-root-cause`; patch 2988 + post/9017, built, NOT BOOTED)

What the two lines rule out and what they leave. `logs/hang-175616.txt`, extract of the usblog.

| Candidate | Result | Mark |
|---|---|---|
| The EL0 emulator (`LAUREL EMU`) holds interrupts off | No. `sleh_synchronous` re-enables interrupts from the EL0 SPSR before `handle_uncategorized`; the exclusive loops of `laurel_a64emu_asm.h` stop after `A64EMU_SPINS` failed stores and return to EL0; `lse2_run` stops at 4096 tries. `retry=0` in the counts of that boot | [V code, V log] |
| An interrupt taken and never ended (the CPU interface then delivers nothing of equal or lower priority) | No path found: every branch of `sleh_irq` writes `ICC_EOIR1_EL1`; the spurious 1020-1023 return needs none. The stamp says `in a handler now: pc 0x0` | [V code] |
| Wrong MAIR encodings (xnu-12377 uses the FEAT_XS values 0x40, 0xA0, 0x0D, 0x01, reserved on a Cortex-A53/A73) | No. `HAS_FEAT_XS` is off for SWEET; the built kernel writes 0x44 (WC), 0xBB (WT), 0xFF (WB), 0x04, 0x08, 0x0C (`msr MAIR_EL1` at 0xfffffff007590540) | [V binary] |
| A Secure (Group 0) interrupt looping as FIQ | FIQs are routed to EL3 on this firmware; `sleh_fiq` is not entered for them | [V code], [I] routing |
| A fixed time after boot (both hangs at 67-68 s) | Common lines in the 7 s before both: `iconservicesagent` renders its first icons on Metal; `negronigl: IOSurface: no import by ID, its pages go through USERPTR`; `LAUREL BT: ios: client gone`; `LAUREL CELL: modem shutting down` (13:46:53, and 17:56:09 after the stall). The stuck CPU runs `iconservicesagent` in the 17:56 case, so an SCM call of a kernel thread (modem, audio, zap) is not it: it would show `kernel_task` | [V log] |
| One instruction that never completes in EL0: an exclusive (LDXR/STXR, every atomic of ARMv8.0 code) to Normal Non-cacheable memory, which the memory system of a Snapdragon does not serve, or a load from an address that gives no answer | Fits every number: a user pc, no handler, no timer interrupt either (a running user thread gets one each 10 ms), the SGI pending at the redistributor. What this port maps Non-cacheable into a task: the GPU pool and the scattered write-combined pages (every BO map of Turnip, every pixel map of an IOSurface, 2977), nothing else: the IOSurface state page is cached and read-only in the task (`SweetSurface.cpp`), USERPTR and host imports wire the task's pages and change no attribute (`hostPages`). Which user code would do an atomic on BO or pixel memory: not found in Turnip's `p_atomic` uses (all on heap structs); metal2vulkan's Rust runtime: not read (its source is not in the tree) | [I], the strongest left |
| A kernel path entered from EL0 that holds interrupts off (a spin lock under `splsched`, pmap, a `copyin` of Non-cacheable memory) | Nothing found in the code; a spin lock timeout would panic, not stay silent | [I] |

**Why the user pc has no symbol.** The dyld shared cache slide is random per boot (`read_random` in `vm_shared_region.c`), and `slide 0x0` in the line is the kernel's slide. The `I` lines of a `laurel-autotest sample` of the same boot give it, and none exists for the 17:55 boot. Under the slide of the 17:25 boot (0x19448000) the pc would be CoreGraphics data, so that slide is not the one.

**2988 (both kernels), post/9017 (iOS 26 sleh.c).** Each exception from EL0 stamps its CPU in `sleh_synchronous` (time, ESR, FAR, user pc, thread); `thread_exception_return` and the end of `sleh_synchronous` close the stamp. The report gets a third line:

```
LAUREL WDOG: on: silent 2000 ms: cpu 5 is in the kernel since an EL0 trap 2559 ms ago: class 0x15 (SVC: a system call) esr 0x.. far 0x.. user pc 0x.., 20482 traps in all; GICR pending 0x00000008 active 0x00000000; dyld slide 0x..
LAUREL WDOG: on: silent 2000 ms: cpu 5 has no EL0 trap open (in EL0, or the trap ended): 20482 traps in all, the last 2600 ms ago at user pc 0x.. class 0x24; GICR pending 0x00000008 active 0x00000000; dyld slide 0x..
```

Reading: `in the kernel since an EL0 trap` with a time near the silence = the kernel path of that class holds the CPU (a data abort: `far` is the address; a system call: the user pc names the call). `no EL0 trap open` with the last trap long before the silence = the CPU is in EL0 on an instruction that does not complete: then the user pc of the last interrupt, with the dyld slide, names the code, and the memory it touches is the next question (an exclusive on a GPU buffer or a pixel map). `GICR active` with a bit set = an interrupt taken and never ended. The stamp is stale after the thread moved to another CPU; the report compares the thread with the CPU's current one and says `no EL0 trap open` then. Cost: five stores per EL0 exception. iOS 16: the functions exist, nothing calls them (its `sleh.c` hunk lives in 2986).

**Not done, and why.** EDPCSR stays out (section 4). A reset at the bark (2987) gives the phone back without the owner; the report above is what a stalled core can still give.

## 10. Fourth catch (18:47:43, kernel c68eeb19c9, 2988 on): a system call, and patch 2989

[V] CPU 5 is in the kernel on an EL0 trap of class 0x15 (SVC #0x80: a Unix system call) for 19 s; thread managedappdistributiond; user pc 0x2442b703c, dyld slide 0x11ff4000, so unslid 0x2322c303c = `_madvise+0x8` in libsystem_kernel. GICR pending 0x08280002: our SGI (1), PPI 19, 21 and the virtual timer (27) all wait. Its last interrupt came in at `ml_set_interrupts_enabled_with_debug+0x144`, the unmask: the thread had held interrupts off before that too. Fourth time CPU 5 (mpidr 0x1), third process, third user pc: the process is not the constant.

**What a madvise reaches [V code].** `vm_map_behavior_set` -> `vm_map_reusable_pages` / `vm_map_reuse_pages` / `vm_map_zero` -> `vm_object_deactivate_pages` -> per page `pmap_clear_refmod_options`, `pmap_disconnect`, `pmap_remove_options` -> pv-head bit lock (`pmap_lock_bit`: preemption off, a timeout panic), PTE update by `os_atomic_cmpxchgv` (an exclusive pair on the page table page), `tlbi ...is` + `dsb ish` (`sync_tlb_flush`). Nothing in `vm_object.c`, `vm_map.c`, `vm_resident.c`, `vm_fault.c` or `pmap.c` masks interrupts by hand, and the port's base patches (0001, 0003, 0005) add no `ml_set_interrupts_enabled(FALSE)`. Every XNU spin lock on this path has a timeout that panics (`LockTimeOut`, `lock-panic`): a 19 s spin on one of them would have panicked. So the CPU does not spin on a lock: it is **stalled on one instruction inside this path** [I], and the candidates are:

| Candidate | Why it fits | Why only a silver core | Check |
|---|---|---|---|
| `dsb ish` after a broadcast `tlbi`: a DVM slave never answers | The GPU SMMU is on the DVM path (`gcc_gpu_snoc_dvm_gfx`, on at boot, never off; the stage-1 tables of 2154). An SMMU that is clocked but whose TLB-sync path hangs holds every core's `dsb` | [U]: the two clusters reach the SMMU over the same interconnect | the frames of 2989: `sync_tlb_flush` or a `flush_mmu_tlb_*` caller at the top |
| the exclusive pair on a PTE whose page table page is Non-cacheable | `set_cache_attr` resets a page's attribute at free, so a recycled write-combined page should be cached again [V `vm_page_free_prepare_object`]; not proved for every path | Cortex-A53 has no monitor for Non-cacheable memory; an A73 may serve it | the frames: `pmap_update_pte` or `pmap_clear_refmod_internal` at the top |
| a plain load that gets no answer | a page table walk or a pv entry at a bad physical address | none | the frames and FAR say nothing for a stall; the panic hold after the bite would |

Why CPU 5 and not 4, 6, 7 [I]: the Edge scheduler spills to the silver pset and picks its first idle non-boot core; CPU 4 (mpidr 0x0) was once `not alive` and reads 0 % in one run, so CPU 5 is where a spilled daemon thread lands. The constant is "a silver core", not the fifth one.

**2989 (both kernels) + post/9018 (iOS 26 sleh.c).** Three more lines for an open trap, all read by copies that cannot fault: the frame chain from the fp the CPU's last interrupt found (`sleh_irq` passes it; a stall in a leaf keeps its callers), every pointer into kernel text on the thread's kernel stack (deepest first, up to 4 lines), and its saved user registers (x16 = the system call number, x0-x3, sp, lr, pc). Symbols: subtract the kernel slide, then `scripts/laurel/crash-bt-symbolize.py` or `llvm-nm` on the unstripped kernel of the same build. Built: 361 patches, 0 errors.

The panic hold and `ctl bootloader`: the hold loop (`laurel_usb_panic_hold`) only runs when `ud_panic_begin` returns true; it returns false with `ud_running` off, no DWC3 or no DMA. A bark panics from `sleh_irq` on another CPU; after 2987 the bite resets the phone in 30 s even if the hold never answers.
## Bite and hold, 2026-11-03 18:48 [V]

Patch 2987 kept the bite armed after a bark. At 90 s the phone was still in the hold and answered `pong (panic)`, so the bite gives no reset on this firmware (cause [U]). Patch 2990: after a bark the hold's own timed reset acts in 20 s. Report of the same catch (2988): CPU 5 in the kernel since an SVC 0x80 19258 ms ago, thread `managedappdistributiond`; last interrupt at `ml_set_interrupts_enabled_with_debug`+0x144. So the stuck path is a system call with interrupts off, not EL0.

## 11. Fifth catch (18:51:35) and the cause found in the GPU SMMU: patches 2991, 2992

**Why 2988 said "no EL0 trap open" with the pc in `vm_map_enter` [V code].** The 2988 stamp is per CPU, written on the CPU where the trap entered. A thread preempted inside a system call that goes on running on CPU 5 brought no stamp, and CPU 5's own stamp belonged to another thread that had left. The pc of the last interrupt (`vm_map_zap_dispose`, from `vm_map_enter+0x1184`) is real for that instant, 19.5 s before the report; the stall came after it, in that system call (mmap: `vm_map_enter` zaps the old mapping, `pmap_remove`, TLB invalidate). **2991**: the report takes "inside a system call" from XNU's own per-thread flag `machine.el0_synchronous_trap` (set in `sleh_synchronous`, cleared in `thread_exception_return`); the CPU's stamp adds class, ESR, FAR and user pc only when the trap entered on that CPU, else the line says "entered on another CPU". The path lines of 2989 follow the flag.

**What both caught system calls do on the CPU [V code].** madvise (`vm_object_deactivate_pages` -> `pmap_clear_refmod_options`, `pmap_disconnect`) and mmap (`vm_map_enter` -> `vm_map_zap_dispose` -> `pmap_remove_options`) end in `flush_mmu_tlb_region_asid_async` (`tlbi vaae1is` per page) and `sync_tlb_flush` (`dsb ish`). Nothing on these paths masks interrupts by hand (`vm_object.c`, `vm_map.c`, `vm_resident.c`, `vm_fault.c`, `pmap.c`, the base patches 0001, 0003, 0005), and every XNU spin lock there panics on its timeout: a 19 s spin on a lock would have panicked. The 4K page patch 0140 changes page geometry, the commpage leaf and the bootstrap tables, not the flush. So the core sits on one instruction, and `dsb ish` after a broadcast `tlbi` is the one that waits for other agents.

**The agent that does not answer [V log, V stock code].** The GPU's SMMU: boot line `IDR0 4c017e04` has BTM (bit 13): the SMMU is a DVM slave, it receives every `tlbi ...is` and must acknowledge before the CPU's `dsb ish` completes. `sCR0 00240406` has PTM (bit 12) clear: it takes part. LineageOS `arm-smmu.c`, `arm_smmu_device_reset`: "Disable TLB broadcasting": `reg |= sCR0_VMIDPNE | sCR0_PTM`; both SMMU nodes of `msm-arm-smmu-trinket.dtsi` carry `qcom,skip-init`, which skips only the stream-map and context-bank reset; the sCR0 write runs at every probe, so no CPU on Android ever waits for these SMMUs. Our `smmu_setup` never touched sCR0. Why a silver core each time: [U] (the A53's DVM sync against the A73's; the port's spill of daemon threads to the silver pset puts them there).

**2992** (`LAUREL GPU SMMU`): `smmu_setup` sets `sCR0.VMIDPNE | PTM` after the context bank, reads them back (single security state: `IDR0.SES` 0, so offset 0 is the register), else `off` with the reason; kill switch `gpusmmuptm=0`. The driver's own TLB upkeep is `tlb_flush()` (TLBIALL + TLBSYNC) after each table change, so nothing needs the broadcast; the GPU runs in pass-through here anyway (`SCTLR 0xe0`, identity). Expected: no more silent CPU; the `LAUREL WDOG` minute line stays at 0 ms. If a catch still comes, the 2989/2991 frames name the instruction.

## 12. 2992 on the phone, sixth catch in EL0, and the second SMMU: patch 2993

[V 19:31:11, kernel 48e56e9] `LAUREL GPU SMMU: on: ... sCR0 00240406 -> 00241c06` held, and CPU 5 still went silent 19 s, this time in EL0 of audiomxd with no system call open (2991's per-thread flag). An EL0 `dsb ish` (dyld and libsystem after `ic ivau`, or any `dsb` in user code) waits for the same DVM agents, and EL0 can take no interrupt while an instruction has not completed. [V log] A second SMMU has the same state: `TopazModem: smmu: sCR0 00270406 ID0 4c017e36`: the system's SMMU (apps_smmu, 0x15000000) has BTM and PTM clear. The stock arm-smmu driver sets `sCR0.VMIDPNE | PTM` on every instance it resets. **2993** (`LAUREL APPS SMMU`): the same two bits on that SMMU, set once at the first bank the modem driver makes, read back (the secure world may own the register: then `off` with the reason), kill switch `appssmmuptm=0`. Our banks there are identity with sTLBGSYNC after programming (modem, WLAN, IPA, audio, camera, Bluetooth): nothing relies on the broadcast. Built: 365 patches, 0 errors. NOT BOOTED.

**Other DVM agents [I].** The ARM DVM domain of this SoC: the two CPU clusters (through the CCI) and the SMMUs (the GPU's and the system's TCU; the TBUs behind the TCU sit in the GDSCs of their blocks: camera, display, video, IPA). A TBU whose GDSC is off answers through the TCU's own handling in Linux (`qsmmuv500` halts); here [U]. What changes 2-5 s before the catches [V log]: nothing that turns power off: a Bluetooth bring-up and release (18:47, 18:51, 19:30), iconservicesagent opening Metal (17:55, 19:00), the backlight's first brightness (18:41), a `state` command. The camera driver powers its GDSCs off after use, and the probe at boot ends at about 20 s. The RPM bus scaling (2985) changes NoC votes with the GPU level; its first switch comes with the first GPU load [I]. With PTM on both SMMUs no SMMU is on the broadcast path any more, so a gated TBU cannot matter.

**Why CPU 5 [U].** The silver cluster's second core: the Edge scheduler spills daemon threads to the silver pset and CPU 4 (mpidr 0x0, once `not alive`) takes few of them, so the thread that issues the `dsb` sits on CPU 5. No erratum of the Cortex-A53 r0p4 covers DVM; whether an A53 waits for a DVM sync in a way an A73 does not: [U]. The owner's run of 48e56e9 (2992 only): 5 minutes with 0 catches, "faster"; one boot is not proof.

## 13. 2026-11-06: two cores, SMMUs excluded, and the timeout that wdt=-1 took away: patches 2994, 2995

[V `logs/usblog-20261106-043354.txt`] With `LAUREL GPU SMMU: on` and `LAUREL APPS SMMU: on` (kernel 063c4c8ed8-dirty of another session, series 775c2e2906d185fa and 4b653a573ee3e7c4): 16 barks in 65 minutes, one in every boot, 40 s to 4 min after boot; `silent 2000` lines: 48 on CPU 5 (silver), 24 on CPU 1 (gold, in the boots with 4 CPUs). So neither one core nor the SMMUs. The UFS read queue on or off, 4 or 8 CPUs: a catch each boot. The 04:34 boots of kernel 72a524435c ended in the `pmap_assert_free` panic at the first exec (the other session's 2971 change keeps UPL buffers on the strategy caller; not merged here).

**The 08:09:55 catch, symbolised against that boot's unstripped kernel [V].** CPU 1, runningboardd, `kevent_id` (x16 0x177), in the kernel 19.7 s, the timer PPI and our SGI pending, the CPU's last interrupt in `machine_idle+0xf8`: it woke from idle, switched to this thread, took the system call, and never took an interrupt again. Code pointers on its kernel stack (`__TEXT_EXEC` only; the 2989 range also admitted strings): `thread_invoke+0x330` (after `thread_dispatch`), `thread_dispatch+0x62c` (after `machine_thread_going_on_core`), `thread_setrun+0x824` (after a ticket unlock), `sched_edge_update_pset_load_average+0x4c`, `hw_lock_lock+0x34` (inside the lock, after `_prepare_preemption_disable_measurement`), `hw_lock_bit+0x20` (inside the bit lock), `thread_block_reason+0x118`, `pmap_remove_range_options+0x5c4`, `lck_rw_done`, routing and NECP frames of an older call. The fp chain of 2989 gave nothing: the last interrupt's fp was the idle thread's. The stir-the-pot loops of the Edge scheduler (base 0005 made them 64-bit LL/SC) are clean in the machine code: 4 to 9 instructions between `ldxr` and `stxr`, branches only. Not the cause.

**Why no panic names the lock [V code].** `machine_timeout_init_with_suffix()`: `if (!always_enabled && (wdt == -1 || skip_predicate)) return;`. The boot line has `wdt=-1` (`uefi-image.sh`), so every machine timeout is 0: `lock` (LockTimeOut), `ticket-lock`, `lock-panic`, `interrupt-masked`, `sched-preemption`, the phy read and write delays. `hw_spin_should_keep_spinning()` returns true for a timeout of 0. A spin lock whose holder never lets go, taken with interrupts off (every scheduler lock), is then a silent CPU for ever; upstream panics after 0.25 s with `Spinlock[%p] timeout after N ticks; current owner: %p` and the holder's thread. `ml_init_lock_timeout()` runs after the timeouts and takes `slto_us` and `tlto_us`; **2994** restores the two defaults there when they read 0 (spin 250 ms, ticket 125 ms), one line `LAUREL LOCK TIMEOUT: on`, kill switch `laurellockto=0`. The other timeouts stay off on purpose: the console at 300 MHz and the SPMI waits hold interrupts longer than `interrupt-masked` allows. `wdt=-1` stays: it also keeps XNU's watchdog, the zone-exhaustion panic and the root-mount wait quiet. [I] The holder: a thread that took a scheduler spin lock and then stalled or spun itself; the panic will name it. **2995** keeps `__TEXT_EXEC` pointers only and adds a frame chain found by scanning the stack.

Expected at the next catch: `panic(... Spinlock[0x...] timeout ... current owner: 0x...)` with a backtrace over USB, within 0.25 s of the stall, in place of a silent CPU and a bite. The owner is the next question.

**3041 (2026-11-07) [V phone]:** 2994's line printed from `ml_init_lock_timeout()`, a `STARTUP(TIMEOUTS)` function inside `kernel_startup_bootstrap()`, before `STARTUP(LOCKS)` gave the msgbuf ticket lock its type word: the DEVELOPMENT kernel's `LCK_TICKET_VERIFY` panicked (`Invalid ticket lock`) after `SWEET EARLY 4`, before mark 5; the kill switch printed from the same place. 3041 keeps the timeouts at TIMEOUTS and prints the line from `STARTUP(EARLY_BOOT, STARTUP_RANK_LAST, laurel_lock_timeout_line)`. Host test `scripts/laurel/test-early-lines.sh`. Details: `docs/notes.md` 2026-11-07.

## 14. GIC review against HakiOS f7f7fab (GIC_IAR_TAKEN): the IPI's end-of-interrupt on this port [V code]

HakiOS's fault: its IPI is SGI 0, `ICC_IAR1_EL1` reads 0 for it, and a "0 = none" mark lost the EOI when a core was switched off inside that interrupt (every core but one, in a panic); the next kernel on that core then took no interrupt (an active priority left in the CPU interface). This port: the IPI is SGI 1 (`SWEET_IPI_SGI`), `sleh_irq` keeps the raw `iar` in a local and writes `ICC_EOIR1_EL1` on every path: the timer (after `rtclock_intr`), SGIs (before `cpu_signal_handler`, so a signal raised meanwhile is not lost), the bark (SPI 3) and every other interrupt (after the IOKit handler). Only 1020-1023 return with no EOI, which is right for a spurious read. No `gic_active_iar` state exists, so no mark can be lost. A core never goes off while in an interrupt here (no CPU_OFF: `haltCPU` panics), and `laurel_gicr_setup` of each core at boot deactivates and clears its SGIs and PPIs and writes `ICC_AP1R0_EL1 = 0` (laurel 2013), so a core left in an interrupt by a panic hold and a reset starts the next kernel clean. No change made.

## 15. 2026-11-07: USB control through every panic and hang: patches 3030, 3031, mu 0202 (branch t3/usb-hold-pmic-wdog; built, NOT BOOTED)

Owner's order: "make it so that kernel panic don't stop usb control". Three cases, one cause each, and one backstop that needs no CPU.

### Case 1: the hold of 17:56:16 sent "holding" and then took nothing for 44 minutes

[V `logs/usblog-20261103-071332.txt` 222993-222994] The bark report went out, `LAUREL PANIC: holding; reset with: op10tool ctl bootloader` went out, and the next line in the log is the owner's reset at 18:40:17. The two other bark holds of that day (18:41:57, 18:48:00) and the stackshot panic of 07:25:51 answered `ping` and `bootloader`. So the hold loop ran at least long enough to send; what died was the way in.

[V code] The hold receives through one TRB (`UD_TRB_RX`): `ud_rx_done` reads the frame, hands it to `ud_panic_rx`, then `ud_rx_arm` queues the TRB again. In normal running the same code runs in `ud_thread` (or the timer call of 2013) from `ud_service_events`, which reads an event, advances `evt_pos`, acks it in `GEVNTCOUNT`, then handles it. A panic on another CPU stops `ud_thread` with the debugger IPI wherever it is. The hold then inherits that state: a frame read but the TRB not queued again (no receive, ever), an event acked but not handled (the RX completion is lost: no receive, ever), `evt_pos` advanced but the ack not written (the hold reads one stale slot: a stale "bus reset" turns the data endpoints off), or an endpoint command half done. The TX side does not care: the hold starts its own transfers and ends a stuck one after 2 s. That is the asymmetry of 17:56: sending worked, receiving did not. At 17:56 CPU 0 ran `dropbearmulti` (an SSH session) with 94 frames queued: the USB thread was busy when the IPI came. Mark [I]: the log cannot show where the thread stood; this is the only path found in the code that gives exactly "sends, never receives", and the fix removes every such path.

Also found [V code]: `laurel_wdog_hold` (2987) printed with `kprintf`, which spins on `kprintf_lock` with no way out; a CPU the panic stopped inside a `kprintf` (the panel console at 300 MHz takes 700 us a line) holds that lock for ever, and the hold would never start. And a nested panic inside the hold (a fault in the loop) went to `panic_spin_forever` with the text on the panel only: silence on USB, only the Power key.

**3031** (both kernels, `sweet_usb.c`, `laurel_wdog.c`, `laurel_reboot.c`):

| Change | What |
|---|---|
| `ud.evt_stage`, `ud.evt_cur` | `ud_service_events` leaves a mark at each step (1 read, 2 position advanced, 3 acked, 4 inside `ud_event`). `ud_panic_resync` at the hold start reads it: stage 2 steps the position back one slot (the count still holds the event), stage 3 handles the event now, stage 4 says so and re-arms. A hold then never reads a stale slot and never loses the acked event |
| `ud_panic_rearm` | At the hold start, always: ENDTRANSFER + FORCERM on the RX endpoint when it has a transfer, then a fresh RX TRB; a consumed SETUP with no TRB behind it gets one. And again after 15 s with no frame from the host (a silent host costs one command, a lost TRB comes back). Line `LAUREL PANIC: USB hold: RX re-armed (why), N in all` |
| `ud_rx_done` | a completion for a TRB the controller still owns (`HWO` set) is not a frame: counted, not re-armed twice |
| nested panic in the hold | `LAUREL PANIC: nested panic in the USB hold: reset in 5 s`, then `laurel_restart` (mode normal: the boot menu); a third entry resets by PSCI alone (`laurel_reset_raw`) |
| `laurel_wdog_hold` | `kdb_printf`, no lock |

What the hold cannot fix: a hold CPU that dies (a fault, a stuck register read): that is case 2's backstop.

### Case 2: a hang with no bark, and the bite that does not reset

[V 2026-11-03 18:48] The APSS bite gave no reset in 90 s. [V downstream `msm-poweroff.c`] Android calls `SCM_SVC_BOOT 0x9` ("WDOG_DEBUG_BOOT_PART", "Needed to bypass debug image on some chips") before its own resets: a bite on this firmware goes to TrustZone's debug image path, and whether that path resets a retail phone with no dload cookie is [U]; the phone stayed in the hold, so the APSS was not reset at all. Not resolved here; not needed any more.

[V downstream `qpnp-power-on.c`, mainline `drivers/watchdog/pm8916_wdt.c`] The PM6125 PON has its own watchdog: S1 timer 0x854 and S2 timer 0x855 in seconds (7 bits), S2 control 0x856 (reset type: 1 warm, 4 shutdown, 7 hard), S2 control 2 0x857 bit 7 enable, pet 0x858 bit 0. No pet for S1 s: a bark (an SPMI interrupt, unused here); S2 s more: the PMIC resets the SoC through the PON, the same path as a long press of the Power key (2955), with no CPU and no TrustZone. Android never pets it [V: the only user is `qpnp_pon_wd_config(0)` before download mode]; the PON lane of our SPMI core reaches these registers (2018/2710, the lane every `ctl bootloader` uses [V]).

**3030** (both kernels, new `bsd/dev/laurel_pmic_wdog.c` + `laurel_pmic_wdog_core.h`): `LAUREL PMIC WDOG: on: PM6125 PON watchdog, no pet for 60 s + 2 s: hard reset by the PMIC ...; found off|armed ...; laurelpmicwdog=0`, or `off: REASON` (no PON lane; the PMIC does not hold the setting; `laurelwdog=0`: no pet thread, so nothing may stay armed). Pets, each at most once a second: the APSS watchdog thread (2986) when every CPU in use answered its signal in the last 8 s (the same rule as the hardware pet, also when the APSS hardware is off), the USB panic hold loop at each turn, the timed reset of `laurel_panic_final` while it waits. Disarmed before every reset and power off of ours (`laurel_restart`, `laurel_power_off`: ABL's fastboot and the menu wait for the owner; a power-off with an armed count would turn the phone on again). Reset type hard: the PMIC power-cycles the SoC and its configuration starts clean [I], so a phone that ABL's retries send to Android does not carry an armed count into Android.

| Case | Before | Now |
|---|---|---|
| One CPU stuck, interrupts off | bark 20 s, hold, reset 20 s later (2990) [V 11-06: 16 of 16 came back] | the same; the PMIC count stays petted by the hold |
| All CPUs stop, or interrupts off everywhere | nothing: Power key | the PMIC resets 62 s after the last pet |
| A panic that stops before its hold (a fault in the panic path, the console) | nothing | the same 62 s |
| The hold loop dies | nothing (17:56) | 62 s |
| A pet thread that cannot run for 60 s (every CPU busy with interrupts on) | a bark at 12 s (2986) | the same bark first |

Host test [V]: `scripts/laurel/pmic-wdog-test.sh`: 18 checks of the rules header, and every `LPW_` number of the UEFI side equals the kernel's.

### Case 3: a hang before the gadget starts, and the boot menu's own count

[V 2026-11-07 03:45] Two boots stopped at `SWEET EARLY ... PE_init` with no USB device. Nothing of the kernel runs yet: no thread, no gadget, no pet. The way back must be armed before the kernel.

**mu 0202** (`tools/laurel-slot/uefi/LaurelPmicWdog.c`, copied into UniXNULib by `mu-build.sh`; patch `0202-unixnu-laurel-pmic-wdog`): the menu reaches the PON through the SPMI arbiter's own registers (core 0x1C40000: version, APID count, the PPID map; config 0x1C0A000: the owner EE of each APID; observer channel for reads, rw channel for writes), the same recipe as `sweet_spmi.c` [V on this phone: `PON APID 112 rw lane mapped`], at `TPL_HIGH_LEVEL` so no firmware callback interleaves. At the menu start: `LAUREL PMIC WDOG: on: arbiter .., PON APID ..; found off|armed ..` and a count found armed goes off (the menu may wait for minutes; a warm reset keeps the PMIC's registers). Right before `Loader->Boot` in `RunXnu`: armed with S1 100 s, S2 2 s, hard reset, one pet: `LAUREL PMIC WDOG: on: armed: no pet for 100 s + 2 s from here`. The kernel's 3030 finds it (`found armed, hard reset (the boot loader)`), writes its own 60 s and pets. `laurelpmicwdog=0` in the entry's command line: the menu arms nothing and the kernel disarms what it finds. The Android entry disarms before its reset. A loader that returns: disarmed.

So a kernel that hangs at `PE_init` now ends in a hard reset 102 s after the jump, ABL takes one more retry of slot b, the menu shows again, and after at most 7 such boots ABL boots Android (boot-menu.md section 4), with no key and no computer.

**The menu's count of failed starts** (boot-menu.md section 10): ABL takes one retry before it loads boot_b, so a menu on a slot b that is not successful sees 6 - N where N boots in a row did not reach a refill. The menu now says `iOS failed N boot(s) in a row. Android after R more boots: press a key to stay` from the first one. With a kernel marked good (`scripts/laurel/mark-kernel-good.sh`, entry `ios-lastgood` in the payload) and N >= 2, that entry is the default: `iOS failed N boots in a row: the last good kernel boots. Android after R more`. No write by Mu: the count is ABL's. Rule in `ls_fallback_plan` (`tools/laurel-slot/laurel_slot.c`), host test in `test_slot.c` [V 688 checks].

### What needs the phone

1. The kernel line `LAUREL PMIC WDOG: on: ... found armed, hard reset (the boot loader)` after the menu's `LAUREL PMIC WDOG: on: armed`: both lanes reach the PMIC.
2. `op10tool ctl panic`, then `ctl ping` in the hold: `LAUREL PANIC: USB hold: RX re-armed (hold start), 1 in all` in the log, `pong (panic)`; after 15 s of silence one more `RX re-armed (no frame for 15 s)`; `ctl bootloader` still lands in fastboot (so the disarm before the reset works: `LAUREL PMIC WDOG: off: reset: disarmed`).
3. The reset itself, once, on purpose: `EXTRA_ARGS=laurelwdog=0` makes 3030 disarm (no pet thread)... so instead: a boot with `laurelpmicwdog=1` and a hang. The first real hang of the phone shows it: the log stops, the phone is in the menu about 62 s later (kernel count) or 102 s after the jump (menu count). **Then, before anything else, read the PMIC WD state in Android after a WD reset**: `adb shell su -c 'cat /sys/kernel/debug/regmap/spmi0-00/registers | grep ^857'` must say `857: 00` (the hard reset cleared the enable). If it says `80`, the count survives a hard reset: then Android would reset 102 s into every boot that follows a WD reset, and the menu's arming must go (`laurelpmicwdog=0` in `uefi-image.sh` until a disarm path for ABL's fallback exists). [I] it clears; [U] on this PMIC.
4. ABL after a PMIC hard reset: the menu again, retries one less (the notice line counts), no fastboot, no EDL.
5. iOS 16: the same patches apply (both kernels build); not booted.
