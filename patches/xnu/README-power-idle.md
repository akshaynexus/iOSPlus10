# Idle power with the screen off (patch 0382)

Status 2026-10-27: written, compile-checked, and built in the full set (`out/kernel/local-20261027-111424`,
with 0383 and 0384). It has not run on the phone yet.

Owner report: "on sleep it still runs the phone hot and drains battery".

Marks: **[V]** seen in a log, in source or in a build. **[I]** inference.

## 1. What the logs show

Tool: `scripts/power/idle-log.py LOG...`. It splits a log by display state and prints the line rates, the
CPUFREQ busy, the respawns and the crashes.

### 1.1 The busy number in the CPUFREQ lines is biased [V source]

- `negroni_cpufreq.c` prints a CPUFREQ line in two cases. It prints when a row changed (at most 1/s). It
  also prints once a minute (`GOV_LOG_TICKS 600`). A row changes mostly when the busy share passes 70 %.
  So most lines come from busy moments.
- "busy" is the busiest core of the domain over 300 ms. It is not the mean of the domain.
- Example: the `d0 1785 MHz busy 96%` lines at idle are single cores during a burst. They do not show a
  steady load.
- The unbiased lines are the minute lines. One case: `logs/usblog-20261026-131747.txt`, display off
  13:28:02-13:30:53, the minute lines at 13:28:31, 13:29:31 and 13:30:32. They show `d0 busy 34% / 44% /
  56%`, with d1 and d2 at 0-12 % [V]. One A510 core is busy for about half of each 300 ms window with the
  screen off. The logs do not tell which thread it is. The new `NEGRONI TOP` lines (section 3.1) show it.

### 1.2 Wakeups: every poller runs at full rate with the screen off [V source]

Nothing in the drivers read the display state before 0382. With the image boot-args (negroniusb=2,
keys, touch, BT, ADSP, ...), these loops run all the time:

| Loop (file) | Period before 0382 | Screen off before | 0382 |
|---|---|---|---|
| USB `ud_thread` (negroni_usb.c) | **1 ms always**; 200 us for 20 ms after each frame or event, also after our own TX completions | same, also with no cable | 4 ms idle (screen on), 20 ms dark or no host; 1 ms when host data came in the last 2 s, a TX is in flight, an event is recent, a USB command is pending, or the PHY watch window (0368) is open; 200 us only for host traffic; a TX wakes the thread at once |
| USB `ud_log_thread` | 100 ms | 100 ms, also not configured | 250 ms dark, 1 s not configured |
| touch `touch_thread` | 10 ms (ATTN GPIO read) | same | 50 ms dark with no finger down (ATTN is a level: nothing is lost) |
| keys `keys_thread` | 20 ms (SPMI read, spin on STATUS) | same | 40 ms dark with no key down |
| BT `h4_rx_thread` | 1/5/20 ms | 20 ms, also with the chip off | 1 s while the chip is off (power-on kicks it) |
| FB vsync timer (NegroniFramebuffer.cpp) | 120 Hz on; 100 ms off | **10/s, plus a vsync notification to every client per tick** (backboardd/CoreAnimation wake 10/s) | 500 ms after 5 s dark (wake kicks the timer at once); notifications: unchanged by default, `negronifb_offnotify=0` stops them |
| FB/TE/VRR/DBUF/DPU stat lines | 5 lines every 1 s | **same while dark** (example: 297 FB STAT lines in 322 s off) | dark: only when something happened, else one set a minute |
| DPU TE interrupt (negroni_dpu.c, negronifb_teirq=1) | 120/s on | not masked while dark | masked while dark, unmasked at the first tick after the wake |
| Battery plug tick (NegroniBattery.cpp) | 1 s (about 8 IOSleep(1) inside) | same | 5 s dark; the full read stays every 20 s |
| UFS boot-log flush (negroni_ufs.c) | a write every 5 s while there is new text | the stat lines make new text each second, so a UFS write every 5 s | fewer lines dark, so fewer writes (not changed directly) |
| cpufreq governor | 100 ms | same | not changed (10/s) |
| GPU watch (negroni_adreno.c) | 100/250 ms | same | not changed (GPU agent, 0384) |
| thermal | 1 s | same | not changed |
| ADSP/SLPI fatal watch | 200 ms | same | not changed |
| chg GLINK `idle()` | 50 ms | same | not changed |

Sum before 0382 with the screen off [I, from the periods]: about 1000 (USB) + 100 (touch) + 50 (keys) + 50
(BT) + 20 (GLINK) + 10 (FB) + 10 (cpufreq) + 10 (USB log) + 9 (battery) + 5 (ADSP/SLPI) + 4 (USB idle) + 4
(GPU) = **about 1270 timer wakeups/s**. A wakeup every 0.8 ms keeps a core out of every PSCI idle state
(rail-pc needs 4090 us residency, 0288). So 0383 (deep idle) cannot help much while this runs.

### 1.3 `delay()` never spins here [V source]

- `NegroniCPU.cpp` registers the CPUs without `powergate_latency`. So `cpu_idle_latency` is 0.
- `ml_delay_should_spin()` (osfmk/arm64/machine_routines.c:2362) therefore returns FALSE.
- `delay(N)` in thread context blocks on a timer (osfmk/kern/clock.c `_clock_delay_until_deadline_with_leeway`).
  It spins only with preemption or interrupts disabled.
- So each `delay(5)` of the bit-banged touch I2C is a timer wakeup and a context switch. A touch report costs
  many of them. The comment in negroni_wlan.c:285 ("delay() spins in this XNU") is wrong for thread context.

### 1.4 The idle loop does WFI [V source]

- `negronicpuidle=0` (the default) means `negroni_cpuidle_idle()` does WFI only (osfmk/arm64/negroni_cpuidle.c
  header). The core is clock-gated but stays powered, with its L1/L2.
- The PSCI states (1 = core rail-pc, 2 = + cluster) are 0288/0383. Another agent owns them; this patch does
  not touch them.

### 1.5 Userland respawn loops [V logs]

| Process | Rate | Evidence |
|---|---|---|
| bluetoothd | every 10 s (6/min) for hours | `logs/usblog-20261026-233816.txt`: 435 execs; `CRASH bluetoothd ... Bluetooth fatal error - crashing { reason=1201 }` (usblog-20261027-121304, 14:46:33/43/53) |
| | each restart reloads the controller: 500-780 `NEGRONI BT` lines/min (0xfc00 firmware download, 0xfce9 VSCs) | usblog-20261026-233816 02:49-03:20 |
| watchdogd | every 10 s in the long-boot-args boots | notes.md section 51 (fixed by 0378) |
| AegirPoster (lock-screen Astronomy poster) | 60-90 execs per 10 min, `CRASH AegirPoster sig 6` | usblog-20261026-131747: 91 crashes |
| assetsd, FitnessWidget, MusicWidgets | some crashes per boot | same logs |

[I] Each restart costs dyld, launchd, xpcproxy work and, for bluetoothd, a BT firmware reload over the UART.
These are not kernel loops. 0382 does not change them. See section 5.

### 1.6 Boot 12 (7 h at the lock screen): the display was ON [V]

- `logs/bootlog-12.txt` holds the last 4352 s (21208-25560 s). In that window there is no `display off`
  line at all.
- `FB STAT: swaps/s 66 presents/s 66 (gpu 66)` comes every second, with `GPU WATCH ... gxclk 639 MHz | dcvs 9
  busy 0%`. The GPU stays at its top clock while 0 % busy.
- Thermal: cpu 49-53 C. The phone was on USB power (`external=1`, usbin 4.9 V).
- So in boot 12, iOS never turned the display off. The lock screen composited 66 frames/s for hours.
- [I] Auto-lock did not run, or something held the display awake (the "Never" setting, or an assertion).
  Check Settings > Display > Auto-Lock and `pmset -g assertions`-like state on the next boot.
- The GPU clock at 0 % busy belongs to the GPU agent (0384 adds a display-off GPU governor step).

## 2. Patch 0382 files

`patches/xnu/0382-negroni-power-idle.patch` (applies after 0381; 0383 and 0384 apply on top of it [V git apply
--check, full build]).

| File | Change |
|---|---|
| iokit/Kernel/arm/NegroniFramebuffer.cpp | `negroni_display_asleep` (C global): 1 from the first slow tick after the DCS sleep, 0 at RequestPowerChange(1). Long off tick, wake kick, quiet stat lines, optional notification stop |
| bsd/dev/negroni_usb.c | `ud_poll_period()`: the adaptive poll; `ud.last_rx` (host frames and host events only); `ud.poll_chan` wake from `ud_if_output`; `ud_log_thread` back-off |
| bsd/dev/negroni_dpu.c | TE SPI masked while dark; the per-second line quiet while dark |
| bsd/dev/negroni_keys.c | 40 ms dark poll |
| bsd/dev/negroni_touch.c | 50 ms dark poll |
| bsd/dev/negroni_bt_h4.c | 1 s RX poll while the chip is off |
| iokit/Kernel/arm/NegroniBattery.cpp | 5 s plug tick dark; the full-read counter by time (ms), not by ticks |
| osfmk/kern/negroni_top.c (new), osfmk/conf/files.arm64, NegroniCPU.cpp | `NEGRONI TOP` lines |

## 3. Boot-args (all new; defaults on unless noted)

| Boot-arg | Default | Old behaviour | What |
|---|---|---|---|
| `negroniusb_idle_ms` | 4 | 1 | USB poll with nothing moving, screen on (clamped to 100) |
| `negroniusb_idle_off_ms` | 20 | - | USB poll dark or not configured (at least `_idle_ms`, at most 100) |
| `negronitouch_dark_ms` | 50 | 10 | touch ATTN poll dark, no finger (10..200) |
| `negronikeys_dark_ms` | 40 | 20 | key poll dark, no key down (20..60) |
| `negronibatt_dark_ms` | 5000 | 0 | battery plug tick dark (0 = as screen on) |
| `negronifb_offtick_ms` | 500 | 100 | off tick after 5 s dark (100..2000) |
| `negronifb_offnotify` | **1 (as before)** | 1 | 0 = no vsync notifications while dark (gated: userland effect not known) |
| `negronifb_offstat_s` | 60 | - | quiet stat lines dark: one set every N s (0 = only on activity) |
| `negronitop` | 60 | - | NEGRONI TOP window in s (0 = off, min 5) |
| `negronifb_asleep` | 1 | - | 0 = `negroni_display_asleep` stays 0: USB dark poll, USB log 250 ms, touch, keys, battery, DPU TE mask and the quiet stat lines all act as with the display on (review A/B switch) |

### 3.1 NEGRONI TOP (diagnostic, every 60 s)

```
NEGRONI TOP 60 s dark 1: busy% 3 1 0 0 0 0 0 0 | irq/s 60 20 8 5 2 2 1 1 | timer/s ... | ipi/s ...
NEGRONI TOP procs (1830 threads): kernel_task 2.1%, backboardd[58] 0.4%, ...
NEGRONI TOP thr 1.2% kernel_task tid 312 "" st 0x1 lr 0x... 0x... 0x... (unslid return addresses)
```

- busy% per CPU = (user + system) / (user + system + idle) over the window (recount, unbiased).
- irq/s = all IRQ exceptions (`cpu_stat.irq_ex_cnt`: timer, IPI, devices). These are the wakeups.
- Thread % = CPU time in the window as a % of one core.
- Kernel threads: symbolise the addresses with `scripts/debug/panic-symbolize.sh -a ADDR...` (the frames
  after thread_block name the loop).

## 4. Safety watchdogs (unchanged in function)

- 0371 lost reboot (no SOF for S s): it runs in `ud_link_watch`, every 100 ms by time. With a 20 ms poll it
  runs every 100-120 ms. Its seconds-scale limits are unchanged.
- 0375 idle reboot: its own 250 ms thread, untouched. Its "ud_thread has not run for 5 s" check: the longest
  ud_thread sleep is now 100 ms (clamp), far below 5 s.
- 0381 data watch: 100 ms by time inside ud_thread, limits in seconds: unchanged.
- 0368 PHY watch: ud_thread stays at 1 ms during the 10 ms-sample window (ADSP start to up + 10 s).
- USB commands (reboot, poweroff, panic): the pending command keeps the 1 ms poll until it runs.
- Panic mode: ud_thread still sleeps 1 s (unchanged). The panic loop has its own poll.

## 5. Not done here (owners / next steps)

- bluetoothd `reason=1201` crash loop: BT agent. Until fixed, `negronibt=0` saves the 10 s reload loop [I].
- AegirPoster crash loop: choose another lock-screen wallpaper, or the Metal fix (docs/metal-management.md).
- Display not turning off in boot 12: check Auto-Lock on the phone.
- GPU at 639 MHz with 0 % busy, GPU watch period: GPU agent (0384).
- Deep idle (PSCI): 0383. It gains much more after 0382, because the 1 ms USB poll was the main short-sleep
  source.
- The real fix for USB is the DWC3 event interrupt: SPI 133 = INTID 165, level (out/live.dts dwc3@a600000
  `interrupts = <0 0x85 4>`). `negroni_spi_register` (pe_fiq.c) has free slots. RX ring TRBs would need IOC
  (0361 "the ring does not complete"). Not done: USB reachability is critical, and it needs a phone test.
- Touch ATTN (GPIO21) and keys (PMIC PON) have interrupts through TLMM/PDC and the SPMI arbiter. Not wired.

## 6. How to measure on the phone

1. Boot the image with this kernel. Expected start lines:
   - `NEGRONI USB: 0382 idle poll 4 ms, 20 ms dark or no host ...`
   - `NEGRONI FB: 0382 dark: tick 500 ms after 5000 ms, vsync notifications on, idle lines every 60 s ...`
   - `NEGRONI TOP: a line set every 60 s ...`
2. Keep USB and `scripts/debug/usblog.sh` running. Press power (display off). Wait 5 min. Do not touch the phone.
3. Run `scripts/power/idle-log.py logs/usblog-<new>.txt`. Expected with the screen off [I, targets]:
   - `TOP ... dark 1: busy%`: every core below 5 %. Before, the CPUFREQ minute lines showed d0 34-56 %.
   - irq/s per core: below 100. Before: at least 1000 on the core that runs ud_thread, from the 1 ms poll alone.
   - Every 60 s one set of FB STAT/TE/VRR/DPU lines instead of 5 lines/s.
   - `TOP procs`: the top consumers. If bluetoothd or launchd lead, it is the respawn loop (section 1.5).
4. With the cable unplugged, the same lines come later in the boot log (`scripts/debug/bootlog-ssh.sh`).
   With `negroniusb_lost_reboot` set, an unplug reboots after 60 s (0371). For an unplugged test use an image
   with `LOST_REBOOT=0 IDLE_REBOOT=0`.
5. Compare: boot-args `negroniusb_idle_ms=1 negronifb_asleep=0 negronifb_offtick_ms=100` give the old behaviour
   with the TOP lines, for an A/B test. Not restored by any boot-arg: the USB live log at 1 s while no host is
   configured (it sends nothing then), and the BT RX poll at 1 s while the chip is off (nothing to read).
6. Wake test: press power with the screen off. The display must come on as fast as before (the wake kick
   ticks at once). A key press with the screen dark must always wake it (40 ms poll).
7. Optional: `negronifb_offnotify=0`. Check that the screen still comes back and that backboardd does not
   log errors.

## 7. Review 2026-10-27 (Opus)

Four fixes, compile-checked (negroni_usb.c, NegroniFramebuffer.cpp with 0384, negroni_top.c). 0383 and 0384
still apply. The build in the status line is from before these fixes.

1. FB: the dark flag was stored after `fLock` was released. A `RequestPowerChange(1)` in that window left it at 1
   with the display on. Now it is stored under `fLock`, only while `fPowerOff`.
2. TOP: `bzero(tasks)` after the thread walk cleared the sums. The procs line was always empty. It is now before
   the walk.
3. TOP: the kernel-stack read of a blocked thread is now under `thread_lock` at splsched. Without the lock, the
   thread could run, give its stack away, and `stack_collect` could unmap it.
4. USB: a frame queued between `ud_poll_period()` and `assert_wait` got no wakeup. `ud_poll_sleep_ms` checks the
   TX state again after `assert_wait` (long sleeps only, so the 1 ms sleep with a TX in flight does not spin).

Checked, no change needed: the first host event after a long idle is seen within 20 ms, then the poll is 200 us
or 1 ms for 2 s. USB 2.0 allows 50 ms for a request without data and 500 ms per data packet, so enumeration and
SET_ADDRESS have margin. The event buffer (1024 events) cannot overflow in 20 ms: SOF events are off and the
RX ring TRBs post no events. The 0371/0375/0381/0368 checks run by time and use limits in seconds. A pending
USB command keeps the 1 ms poll. The wake kick and `rearm()` race only to an extra tick. The TE SPI is
unmasked in the first tick after the wake, before that tick's frame. Keys: the long-press time in 0377 is in
seconds and the poll is 20 ms while a key is down. Touch: S3908 ATTN is a level.
Open [I]: a TX that stays busy while the host sleeps (suspended, no SOF) keeps the poll at 1 ms. This costs
power, but it is not a reachability risk.

