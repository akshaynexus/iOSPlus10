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
| Panic | `kPEPanicBegin`: no pets, bark = bite = 30 s, count from 0. If the panic hangs before its hold: a bite. Panic hold, `laurel_panic_final`: hardware off, so **a hold does not reset**. `laurel_restart`, `laurel_power_off`: off just before PSCI: ABL and Mu get no running count | [V code] |
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
