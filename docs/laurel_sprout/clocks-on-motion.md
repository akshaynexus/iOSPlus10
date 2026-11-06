# Mi A3 iOS 26: full CPU and GPU clock on touch and motion; RAM above the window (laurel 3020-3022, mu 0104)

Date: 2026-11-07. Branch `t3/perf-clocks-ram`, on `origin/laurel-sprout` 063c4c8. Owner's order (2026-11-03 19:37): "Make sure it runs on
full gpu and cpu clock speed and ram properly". Marks: [V] read in a log, in code, or measured on the host. [I] inference. [U] unknown.
**Built and host-tested. NOT BOOTED: the phone was disconnected.** The current kernel series panics at `exec launchd` (`pmap_assert_free`,
notes.md 2026-11-06) before any of this runs; that panic is another agent's work, these patches sit on top of it.

## 1. What the last boot showed (kernel 48e56e9, `logs/usblog-20261103-071332.txt` from 19:31:51) [V]

| Item | Numbers | Reading |
| --- | --- | --- |
| Gold | 2016 MHz 42-60 s of each UI minute; 300:5 in the quietest | the cap is reached; the 40 ms tick (2972) gets it there |
| Silver | `300:20 ... 1804:27` and `300:30 ... 1804:16` in UI minutes | silver sat at 300 MHz for a third of a moving minute: only a touch held it (500 ms), GPU work held gold alone |
| GPU | `320 MHz 17 s, 465 2 s, 600 2 s, 745 11 s, 950 26 s, 30 raises, 0 hot refusals; busy 11 %` | each motion began at 320, went 745 (touch, one tick) then 950 (busy, next tick): 50-100 ms per burst below the top, 30 times a minute |
| DDR | 1805 MHz with the GPU at 950, 1355 at rest | the bus vote follows the level (2961 + 2985) |
| Frames | `motion ended: 151 frames in 2611 ms` (58/s), `178 in 6900` (26/s), `99 in 6127` (16/s), `114 in 9975` (11/s) | long animations are slow with gold at 2016 and the GPU at 950 most of the time: the clocks are not their main limit [I]; see `ios26-default-speed.md` section 7 and `watchdog.md` |
| Idle states | WFI only (`negronicpuidle` not ported, no PSCI CPU_SUSPEND) | no deep-idle exit cost exists: nothing to fix here |
| Cores | `LAUREL CPU TOP: 60 s, busy N s of 480` = 8 x 60 | all 8 CPUs are in the scheduler; `hw.perflevel0/1` 4 + 4, `kern.sched: edge` (`cpu-parallel.md`) |
| RAM | `LAUREL RAM: on: 3904 MiB at 0xc1004000..0x1b5004000 (banks 0x80000000..0x1c0000000)`, `LAUREL GPU POOL: on: 1024 MiB at 0x80000000`, modem pool 16 MiB | 4944 MiB owned of 6144 MiB of addresses |

## 2. CPU: laurel 3020 `LAUREL CPU MOTION`

Policy (laurel_gov_core.h `lgov_hold`, applied in `gov_step`; the governor thread is woken by the event, so the OSM row is written within the
thread's wake-up, not at the next 40 ms tick):

| Event | Gold | Silver | Held |
| --- | --- | --- | --- |
| touch (SweetHID, also the autotest's synthetic touch of 2983) | cap | cap | 500 ms after the last touch event |
| frame on its way: a GPU submission (`redwood_gpu_submit`) or a swap (`AppleCLCD::swap`) | cap | the lowest row >= 1400 MHz: **1420 MHz** on this table [V rows line] | 150 ms after the last frame (9 frames at 60 Hz, 1.5 at 10/s) |
| nothing in the window | by load (2972: a full tick -> cap, under 30 % for 320 ms -> one row down) | same | the floor comes back only when the screen is still |

The thermal cap wins over every hold (`lgov_next` caps at `cap`; gold -1 row per second from 95 C, silver too from 105 C, +1 row per 2 s below
85 C: `laurel_thermal_caps.h`, unchanged). One line at start: `LAUREL CPU MOTION: on: a touch holds silver and gold at their caps for 500 ms; a frame
(GPU submission or swap) holds gold at its cap and silver at 1420 MHz for 150 ms; the event wakes the governor (no ramp); the floor comes back by load
when the screen is still`. `kern.laurel_stats` `cpu.hold=touch|motion|none`. Kill switch `laurelcpumotion=0` (the 2972 rule; the line says so). The
wake-up: the first event after a pause of one tick (40 ms) wakes the governor and the GPU governor; while events flow the stamps alone keep the
hold at each tick, so a 60 Hz stream costs no extra wake-ups [V code].

Why not silver at its cap on motion [I]: backboardd's frames end 96 % on gold (`battery-power.md`); silver carries the helpers. 1420 MHz is 79 % of
its top at the SVS corner, the cap on a touch keeps the first frame's helpers at full speed. A later measure may move it: one constant
(`LGOV_SILVER_MOTION_KHZ`).

## 3. GPU: laurel 3021 `LAUREL GPU MOTION`

The 2961 governor thread now waits on an event with the 50 ms timeout (`assert_wait_timeout` in place of `IOSleep`). `laurel_gpu_dcvs_poke()` (from
the touch and the first frame after a pause, laurel 3020) wakes it. Decision (`opp_decide`, `laurel_gpu_opp.h`): the UI holds a level: `OPP_HOLD_TOP`
with a touch in the last 300 ms or a frame in the last 150 ms: the top usable level under the thermal cap (**950 MHz**, bus vote **1804 MHz** before
the raise by `opp_go`), in one `opp_go` (320 -> 950: PLL0 on, RCG, PLL1 off: one step, no park). After the hold: by load as before (lower only after
500 ms under the aim). Hot (95 C, sensor 15): the raise is refused and counted (`hot refusals` in the minute line); 100 C: the lowest level. These are
Android's stock trips [V trinket-thermal.dtsi]; that is the limit by design: the stock rule keeps 950 MHz until 95 C. Line: `LAUREL GPU MOTION: on: a
touch or a frame (GPU submission or swap) wakes the governor: the top level (950 MHz, DDR 1804 MHz) at once, held 150 ms after the last frame, 300 ms after a
touch; then by load; hot 95 C refuses`. Kill switch `gpumotion=0` (2961: a touch holds 745 MHz, read at the tick). `opp_on_line` ends with `raise 50 % or UI`.

Cost of one raise [V code]: iPeak vote (danger bit, usually at once), one RPM DDR message, one RPM CX message, PLL lock <= 200 us, RCG, the clock read
(two GCC counter runs of 1.7 ms + 2 ms of CP counter): about 6 ms of the governor thread; the GPU runs on meanwhile. 30 raises a minute = 180 ms.

## 4. RAM: mu 0104 + laurel 3022, the 174 MiB above the window

Where the other RAM is [V `uefi-boot.md` "Memory map", Mu `MemoryMapLib.c`]:

| Range | MiB | What | Taken now? |
| --- | ---: | --- | --- |
| 0x1B5004000-0x1C0000000 | 176 | UEFI's own allocations, top-down from the bank end: DXE images, pool, page tables, DarwinBoot's image. Free after ExitBootServices; DarwinEnter turns the MMU off; the display scans out of "Display Reserved" 0x5C000000 in bank A, not here | **yes: mu 0104**, 174 MiB (the 2 MiB multiple of 0xAFFC000) [V host test on the Mi A3 map] |
| 0x65E00000-0x7CC00000 | 366 | free in bank A, nothing uses it | no: not contiguous with the window; XNU arm64 manages one physical range (`pmap_bootstrap`, `vm_pages[]`) |
| 0x5FC00000-0x65D00000 | 97 | UEFI FD, SEC heap, stack, DXE heap (bank A) | no: same reason; the DXE heap is boot-services memory |
| 0x40000000-0x5FC00000 | 508 | hyp, AOP, SMEM, PIL (modem, ADSP...), display, TZ carve-outs | never: firmware |
| 0x80000000-0xC1000000 | 1040 | GPU pool 1024 + modem pool 16 | device pools, by design (2974) |

So after this: 3904 + 174 = **4078 MiB** kernel RAM + 1040 MiB pools = 5118 MiB owned; 463 MiB in bank A stay out, and 508 MiB are firmware. Android's
5.7 GB (5836 MiB) counts bank A's free part too; that is the whole difference, and it is a one-range limit of XNU, not a firmware reservation.

How: DarwinBoot walks the final memory map (the one `ExitBootServices` takes) from the window end over descriptors of type loader code/data,
boot-services code/data and conventional, contiguous with it; a runtime-services, reserved, ACPI, MMIO, persistent descriptor or
`EFI_MEMORY_RUNTIME` ends the run. `boot_args.memSize = memSizeActual = window + top`; the owned range of the cache clean in `DarwinEnter` grows
with it. XNU 2100/2974 then checks the whole size against the ADT banks (`end <= 0x1C0000000`), the pools and the 4608 MiB table budget as before,
and 3022 adds to the line: `; +174 MiB above the 3904 MiB the ADT asks: UEFI's boot memory, given by DarwinBoot`. Bootstrap tables for 4078 MiB at
0xC1004000: 2 L1 + 4 (V=P) + 5 (KVA) + 1 = 12 of 16 pages [V computed as `ram-map-test.py tables()`]. Screen: `WINDOW +ae00000 UEFI TOP` on row 1.
Kill switch: `laurelramtop=0` in the command line (DarwinBoot reads it: no rebuild). Host test: `scripts/laurel/test-darwinboot-top.sh` (the header
of the patch on fake maps: the Mi A3 layout, a runtime page in the middle, every stopping type, the cap, 2 MiB rounding, bad input).

What depends on the size, checked [V code]: `LAUREL WIRED` limit = 55 % of max_mem: 2147 -> 2242 MiB, 2732 -> 2853 MiB for the shown app
(`laurel_wired.c`, no constant changed). memorystatus (jetsam): the kernel's bands are `max_mem <= 3 GiB` and `<= 6 GiB`
(`MEMORYSTATUS_SMALL/MEDIUM_MEMORY_THRESHOLD`, kern_memorystatus.c:280); 3904 and 4078 MiB are both in the middle band: no threshold class changes.
The per-job limits are the root's plist floors (`cpu-parallel.md`): untouched, no job removed or restricted.

Risks [I]: a UEFI driver that keeps a DMA engine on a boot-services buffer after ExitBootServices (the Qualcomm UFS/USB DXEs stop at their
ExitBootServices events; XNU resets both). The top of the window is used first (`vm_himemory_mode = FALSE`), so such a fault would show at once
as corruption early in the boot, not later. Then `laurelramtop=0`.

## 5. What the phone must show (same scenario before and after: `scripts/laurel/ios26-autotest.sh run`, or the owner's swipes)

| Feature | Line | Before (boot 19:31) | After, expected |
| --- | --- | --- | --- |
| CPU MOTION | `LAUREL CPU MOTION: on: ...` at boot | none | the line |
| | `LAUREL CPUFREQ: on: silver MHz:seconds in the last minute` in a UI minute | `300:20 ... 1420:2 1612:4 1804:27` | `300` seconds only from still time; 1420 or 1804 while frames moved |
| | `... gold ...` | `300:5 ... 2016:42` | 2016 for all moving seconds |
| | `sysctl kern.laurel_stats` `cpu.hold=` during a server animation (no finger) | `none` or `gpu` | `motion` |
| GPU MOTION | `LAUREL GPU MOTION: on: ...` at boot | none | the line, 950 MHz, DDR 1804 |
| | `LAUREL GPU CLOCK: on: last minute ...` in a UI minute | `320 MHz 17 s, 465 2 s, 600 2 s, 745 11 s, 950 26 s, 30 raises` | no 465/600/745 seconds; raises = motions; 320 only in still time |
| | `LAUREL FRAME: motion ended: N frames in M ms` for the same swipe | 58/s, 26/s, 16/s, 11/s | not worse; the first frames of a burst faster [I: the gain is in the first 50-100 ms of each burst] |
| | `hot refusals` | 0 | 0; if not 0, the stock trips act: that is the limit |
| RAM | `LAUREL RAM: on:` | `3904 MiB at 0xc1004000..0x1b5004000` | `4078 MiB at 0xc1004000..0x1bfe04000 ...; +174 MiB above the 3904 MiB the ADT asks` |
| | screen at the hand-off | none | `WINDOW +ae00000 UEFI TOP` |
| | `hw.memsize`, `LAUREL WIRED: on: ... 55% of max_mem` | 4093640704, 2147 MiB | 4276092928, 2242 MiB |
| | memory kills (`CRASH`, `ended tasks` in `LAUREL CPU TOP`) | as before | not more |

Not proven until a boot: everything above the "After" column. The autotest's synthetic touch (2983) goes through `laurel_input_touch` [V code], so
`ios26-autotest.sh run` exercises both holds without a finger.

## 6. Patches and tests

| Patch | Files | Host test |
| --- | --- | --- |
| 3020-laurel-cpu-motion | laurel_gov_core.h, laurel_gov_loop.h, laurel_thermal.c, TopazAdreno.cpp (one call), SweetFramebuffer.cpp (one call) | `scripts/laurel/gov-test.sh` PASS |
| 3021-laurel-gpu-motion | laurel_gpu_opp.h (`opp_decide` takes the held level), LaurelGpuDcvs.cpp | `scripts/laurel/test-gpu-opp.sh` PASS (3 controls) |
| 3022-laurel-ram-top-line | laurel_ram.c | by the kernel build |
| mu 0104-darwinboot-window-top | DarwinBoot.c, DarwinBoot.inf, new WindowTop.h | `scripts/laurel/test-darwinboot-top.sh` PASS |

Both kernels take 3020-3022 (the files exist in both). The frame-gap work on CPU 5 (2985-2993) lowers or gates nothing here: these patches only
raise and hold clocks and wake two threads earlier; the shared files are touched in one line each.
