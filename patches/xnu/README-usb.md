# USB Ethernet gadget (bsd/dev/negroni_usb.c)

The base driver comes from slop (patches 0072-0077, 0081, 0119: DWC3 at 0x0a600000, ep0, VBUS override, CDC-ECM,
live log). Our patches: 0210 (UDP command server), 0212 (settime), 0282 (bus reset drops the data endpoints),
0360 (panic mode, README-panic.md), 0361 (throughput, this file), 0366 (reconnect after unplug or a Type-C
re-attach, this file), 0368 (the HS PHY after the ADSP start, this file), 0371 (reboot when the host stays lost, this file). Host side: docs/usb-network.md.

## 0361: throughput (RX ring, TX batches, short polls)

### Problem

- [V] 2026-10-27: 1.0-1.2 MB/s in both directions, with SSH and with raw netcat (16 MiB in 13.6-15 s). Ping 1.4 ms.
- [V] The link is high speed: kernel log `NEGRONI USB: connected, speed 0` (DSTS CONNECTSPD 0 = high speed in Linux
  dwc3 core.h); macOS ioreg `USBSpeed` = 3 (high). The `DSTS 0x00820001` in the "running" line is read before the
  host connects, so its speed field means nothing. The HS PHY is not the limit.
- [I] The limit was the driver: one TRB per direction, and the next TRB was started only when `ud_thread` saw the
  completion event on its next poll (`ud_sleep_ms(1)`). That is at most one frame per poll and direction:
  1514 bytes per ~1.2 ms = ~1.2 MB/s, the measured value.
- [I] TX queue of 32 mbufs: a full queue dropped frames (TCP then backs off).

### Change

- RX: a ring of 32 TRBs (2 KiB buffer each) plus a link TRB, started once. Each TRB has CSP: a short packet (the end
  of a frame) completes the TRB and the controller continues with the next one. No IOC: `ud_thread` (and the panic
  loop) look at the ring on every poll (`ud_rx_ring_poll`), deliver every done frame and give the stack one mbuf
  chain (`ifnet_input` once per poll).
- Non-coherent DMA: a TRB is armed again only when all 4 TRBs of its 64-byte cache line are done, then the line is
  cleaned and one UPDATETRANSFER is sent. So a cache clean never writes over a TRB that the controller is writing.
- TX: up to 32 queued frames go into one transfer, one TRB per frame (not chained, so each frame ends with its own
  short packet; the pad byte for 512-multiples stays), LST + IOC on the last TRB. The next batch starts on
  XferComplete.
- TX queue 128 mbufs (was 32). Drops are counted.
- Poll period: `negroniusb_pollus` (default 200 us, no timer leeway) while frames move or a TX batch is open, and for
  20 ms after the last activity; 1 ms when idle (as before).
- DMA area 160 KiB (was 16 KiB). The old offsets (event buffer, ep0, UD_RX/UD_TX, UD_TRB_TX) are unchanged; the panic
  mode still sends single frames from UD_TRB_TX/UD_TX. If a batch is on the IN endpoint when a panic starts, it is
  not sent again after the 2 s timeout (only a single frame is).
- Unchanged: descriptors (bulk 512, USB 2.0), MAC addresses, 192.168.7.2, UDP 5140 log and 5141 commands, ARP and
  command handling in panic mode.

### Measure

- Kernel log, every 10 s with traffic: `NEGRONI USB: ue0 rx N tx N frames; last 10 s: rx X KiB/s Y frames/s, tx ...,
  tx drops D, rx max R/poll, tx max B/batch`. This is the gadget's own rate (no SSH crypto).
- `op10tool ctl usbstats`: the totals now (reply `usb rx ... frames ... bytes, tx ..., tx drops ..., rx max .../poll,
  tx max .../batch, ring 1, poll 200 us`).
- Host: `head -c 16777216 /dev/zero | nc -w 3 192.168.7.2 9000` against `nc -l -p 9000 > /dev/null` on the phone,
  and the other way.
- Boot log line: `NEGRONI USB: RX ring 32 TRBs, TX batch 32, queue 128 (negroniusb_ring=1)`.

### Fallback boot-args

- `negroniusb_ring=0`: the old one-TRB RX path (`ud_rx_done`) and one frame per TX transfer (queue stays 128).
- `negroniusb_pollus=N`: poll period in us while busy (1-999); `0` or >= 1000 = always 1 ms (old timing).

## 0366: reconnect after unplug / Type-C re-attach

### Problem

- [V] 2026-10-27 ~02:30: after the cable was unplugged and plugged in again, the phone kept running, but the Mac saw
  no USB device from it (`ioreg -p IOUSB` empty for the phone, no en interface). Before the unplug the link worked
  (36 MB/s with 0361).
- [V] 2026-10-27 02:42:23: the same with the cable in. The first boot with a running ADSP (0240 SCM resume fix,
  `NEGRONI ADSP: 8 THE ADSP IS UP` at 02:42:20) lost the interface 3 s later. Last gadget line `event 0x0000c046`
  (EP_TX XferComplete, normal). [I] The ADSP firmware owns the Type-C port and the charger; when it starts, it
  negotiates CC/VBUS again, and the host sees a detach + attach. The gadget did not come back either.
- [V] The driver forces VBUS valid in QSCRATCH (`VBUS override on: HS_PHY_CTRL 0x10100000 SS_PHY_CTRL 0x01000000`),
  so the controller never gets a disconnect event. With DEVTEN 0x7 it did not report the bus suspend (L2) either:
  the log shows nothing between the unplug and the replug.
- [V] Code: a bus reset only cleared DALEPENA and the driver flags. The RX ring (0361) is always an active transfer,
  a TX batch whose host went away never completes, and a CDC notification can stay active: no ENDTRANSFER was sent
  (the databook and Linux `dwc3_gadget_reset_interrupt` -> `dwc3_stop_active_transfers` ask for one). ep0 was not set
  back to the setup phase on a reset in the middle of a control transfer. Nothing retried when the host did not
  enumerate the device again.
- [V] `GUSB2PHYCFG 0x00102500` at boot: SUSPHY (bit 6) is already 0, ENBLSLPM (bit 8) is 1. So the HS PHY is not put
  into suspend by the core. Linux sm8450.dtsi sets `snps,dis_u2_susphy_quirk` and `snps,dis_enblslpm_quirk` for this
  controller (both bits cleared).
- [I] Exact failure on the replug: not known. No log exists from that period (the live log needs the link). The
  likely candidates: the controller stays in L2 with the pull-up on and does not answer the host's reset/chirp, or
  the stale transfers break the next configuration. 0366 handles both with the Linux soft disconnect/connect.
- [I] The three interface losses in logs/usblog-20261026-233816.txt at 02:03:33 and 02:05:29 were reboots, not link
  losses: the log stops ~12 s before "gone" and the next boot starts ~64 s later (raw `event` lines again, which
  only the first 200 events of a boot print). The one at 02:06:40 has no silence before it (log until 02:06:39): an
  unplug or a link loss.

### Change (bsd/dev/negroni_usb.c)

- Every STARTTRANSFER records its endpoint and transfer resource index (`ud.ep_busy`, `ud.ep_rsc`). XferComplete
  clears it.
- Bus reset, disconnect event and SET_CONFIGURATION(0): `ud_drop_data()` sends ENDTRANSFER (FORCERM) on every
  active data transfer (TX under `ud.lock`, RX ring, notification), then DALEPENA 0x3 and "not configured". ep0 is
  put back to the setup phase (ENDTRANSFER with CMDIOC and no FORCERM as Linux `dwc3_ep0_end_control_data`,
  SETSTALL, setup TRB) when the reset came in the middle of a control transfer (Linux `dwc3_ep0_reset_state`).
  SET_CONFIGURATION(1) starts everything again (0282 path).
- After each ENDTRANSFER: 1 ms before the next command on that endpoint (Linux `mdelay(1)` for a DWC_usb31
  without GUCTL2[14]). The same 1 ms in the 0360 panic TX timeout path (was 100 us).
- After the core soft reset: 50 ms before the PHY-domain writes (Linux `dwc3_core_soft_reset`, DWC_usb31 <= 1.80a;
  ours is 1.10a, GSNPSID 0x33313130).
- A stale CDC notification is ended before a new one starts.
- DEVTEN: + wakeup (4), U3/L2 suspend (6), erratic error (9) (the Linux set for a DWC_usb31); link state change (3)
  only with `negroniusb_events=2`. Every device event type is
  logged with DSTS and the link state: reset, connect done and disconnect always (with a count); the others the
  first 8 times per type, then every 100th.
- GUSB2PHYCFG: SUSPHY and ENBLSLPM cleared after the core soft reset.
- Watchdog `ud_link_watch()`, every 100 ms in `ud_thread` and in the panic loop (0360): reads DSTS. It logs each link
  state change (rate-limited as above), `no SOF for 3 s` once per episode with DSTS/DCTL/DEVTEN/GUSB2PHYCFG, and
  `SOF again after N ms` when the host is back. A soft reconnect happens when:
  - there was no SOF (DSTS.SOFFN did not change) for `negroniusb_reconnect` s (default 5), or
  - a device event came > 0.5 s after the last SOF (the replug or re-attach) and 1 s later there is still no SOF
    (once per episode; an episode ends at the next SOF).
  After a try the next one comes one period later; after 12 tries in one episode, every 6 periods (30 s). While the
  device is configured and the link is in L2 (link 3: most likely a host that suspended the bus), the 30 s period
  applies at once. The first reconnect drops the configuration, so after it the 5 s period applies.
- Soft reconnect (`ud_soft_reconnect`, Linux `dwc3_gadget_soft_disconnect` + `dwc3_gadget_soft_connect`): drop the
  data state (ENDTRANSFER), end ep0, RUN_STOP 0, wait for DEVCTRLHLT (events acked and dropped meanwhile, up to
  500 ms), pull-up off 100 ms, then `ud_hw_start()`: core soft reset, GUSB2PHYCFG, event buffer, DCFG, DEVTEN,
  ep0, VBUS override, RUN_STOP 1. This is the same start code as at boot (moved out of
  `negroni_usb_gadget_start`). The host sees a new attach and enumerates again. The next 60 raw `event` lines are
  printed again after each reconnect.
- Panic mode: the watchdog also runs in the panic loop (no locks, busy-wait delays there). A host that comes back
  during a panic hold gets a fresh attach.
- [I] Side effect: a host that suspends the bus (Mac asleep) sees a disconnect/attach after 30 s, then every 5 s
  (the device is no longer configured), then every 30 s after 12 tries. macOS does not suspend the ECM device while the Mac is awake (the live log sends all the time).
  `negroniusb_reconnect=0` turns it off.

### Boot-args (fallbacks)

- `negroniusb_reconnect=N`: seconds without SOF before a soft reconnect (default 5). `0` = no watchdog reconnect
  (the logs stay).
- `negroniusb_resetend=0`: no ENDTRANSFER on reset/disconnect/notification, no ep0 reset, SET_CONFIGURATION(0)
  ignored (the 0282 behaviour). With `negroniusb_resetdrop=0` and a configuration, a bus reset ends nothing either
  (the old path: ud_configure would not start it again).
- `negroniusb_events=0`: DEVTEN 0x7 (the old mask); `1` (default): + wakeup, suspend, erratic error (Linux set for a
  DWC_usb31); `2`: + link state change.
- `negroniusb_phycfg=0`: GUSB2PHYCFG as the firmware left it.
- All four at the old values (`negroniusb_reconnect=0 negroniusb_resetend=0 negroniusb_events=0 negroniusb_phycfg=0`)
  = the driver before 0366 (but the start code is the shared `ud_hw_start`).

### Phone result 2026-10-27 02:55 (first 0366 build, before the review fixes)

- [V] Boot lines OK: `GUSB2PHYCFG 0x00102500 -> 0x00102400`, `reconnect handling ... DEVTEN 0x25f`, bus reset #1,
  en10 up, 36 MB/s class link.
- [V] The ADSP came up at 02:55:44; the Mac lost the device at 02:55:46 and never saw any USB device again. So the
  host saw no device at all, and a soft reconnect on the phone could not help. [I] The ADSP (VOOC / Type-C data-line
  switch) likely takes the D+/D- lines away from the SoC PHY; this is investigated separately.

### Test

1. Boot line: `NEGRONI USB: GUSB2PHYCFG 0x00102500 -> 0x00102400 (SUSPHY, ENBLSLPM off ...)` and
   `NEGRONI USB: reconnect handling: ENDTRANSFER on reset on, soft reconnect after 5 s without SOF, DEVTEN 0x00000257`.
2. Unplug for 10 s, then plug in again. Expected phone log (it reaches the Mac after the replug; the live log
   sends the ring from where it stopped):
   - `NEGRONI USB: device event 6 suspend (U3/L2) ...`, `NEGRONI USB: link 0 (on) -> 3 (suspend L2)` (or 4/5),
   - after 3 s `NEGRONI USB: no SOF for 3 s (configured): DSTS ... link 3 ...`,
   - if the link shows 3 (L2): no periodic reconnect before 30 s; the replug's device event triggers
     `soft reconnect #1 ...: device event without SOF` 1 s after the replug if the host does not enumerate by itself.
     If the link shows 4/5: `soft reconnect #1 (1 in this episode): no SOF` after 5 s, again every 5 s,
   - after the replug: `bus reset ...`, `connected, speed 0 ...`, `setup ...`, `configured (1)`,
     `ECM endpoints configured`, `SOF again after N ms (link 0, ...)`.
   Mac: `ioreg -p IOUSB` shows `Negroni iOS (USB Ethernet)` and en10 is back within 5 s of the replug (a direct
   re-enumeration), worst case ~1.2 s (event rule) + ~2 s enumeration. If the replug makes no device event at all
   and the link was L2, the next try comes only at 30 s.
3. ADSP boot (`negroniadsp=1 ...`): if the host loses the device at `THE ADSP IS UP`, expect the same lines and
   en10 back within ~5-7 s.
4. If it still fails: the log after the replug (it arrives once the link is up again) shows which step stops:
   no event at all after the replug, events but no `connected`, or `connected` but no `configured`.

## 0368: the HS PHY after the ADSP start

### Problem

- [V] logs/usblog-20261026-233816.txt 02:42:20 and 02:55:44: `NEGRONI ADSP: 8 THE ADSP IS UP`, GLINK up, our open of
  PMIC_RTR_ADSP_APPS acked; 2-3 s later the Mac has no USB device from the phone at all (no failed enumeration either),
  also with 0366 (02:55). The last gadget lines are normal (`event 0x0000c046`). Without the ADSP the link holds for hours.
- [V] The ADSP image has its own USB PHY utility (`out/firmware/adsp/adsp.b14`, strings next to `usb_pmic_util_log.c`):
  `usb_hs_phy_reset` ("%s, 0x%08X, 0x%08X"), `usb_hs_phy_set_nondrive_mode`, `usb_hs_phy_toggle_dp`,
  `usb_hs_phy_dp_high`, `usb_hs_phy_dp_default_state`, `usb_is_eud_active`, `usb_hs_phy_enable_clkref`
  ("clk_cnt %d, enable %d, failed %d"), `usb_hs_attach_usb_clock` with the clock `gcc_eusb3_0_clkref_en`.
  Next to them: the charger code `battmngr_plat_irq_scpqchg2s_extfg_r1_apsd_done`, "port_type[%d]:Enable BC1.2 Retry",
  `PmSchgUsb_GetQcApsdResult`, the OPLUS VOOC PHY code (`oplus_voocphy_reset_again`).
- [V] `gcc_eusb3_0_clkref_en` is the reference clock of our HS PHY: live.dts `hsphy@88e3000` clocks
  `<0x23 0x1f>` = GCC id 31 = `GCC_EUSB3_0_CLKREF_EN` (op-kernel `qcom,gcc-waipio.h`), register GCC + 0x9c00c bit 0
  (gcc-waipio.c, gcc-sm8450.c). The PHY block reset is `GCC_QUSB2PHY_PRIM_BCR` (DT resets `<0x23 0x15>`, GCC + 0x22000).
- [V] negroni_usb.c never sets the PHY up ("left as the firmware set it up"); 0366's soft reconnect resets only the
  controller. [V] Android (dwc3-msm-core.c, oplus_battery_sm8450.c) starts the gadget after the ADSP, and the
  PHY init (`usb_phy_init`) runs on each role change; OPLUS even keeps the PHY away from D+/D- during PD SVOOC
  (`oplus_dwc3_need_set_usbphy_hz`, dwc3-msm-core.c:616, 4555).
- [I] So: when the charger PD starts with the cable in, it runs its BC1.2/APSD (and HVDCP/VOOC) detection on D+/D-,
  which uses the PHY functions above (reset, non-driving mode, ref clock vote). After that the PHY is reset, non-driving
  or without its ref clock, and nothing sets it up again; the host sees no pull-up, so no device at all. No GLINK
  message from HLOS is known that stops this (the detection is local to the ADSP; HLOS only gets BC_APSD_DONE /
  BC_USB_STATUS_GET notifications afterwards, oplus_battery_sm8450.c:2135, 2212). Not proven: the next boot's log shows it.
- [V] NOT CONFIRMED on the phone (t8, 2026-10-27 03:19-03:20, kernel local-20261026-214742, `negroniadsp=1
  negronichg_glink=1`): the snapshots at the ADSP start and at ADSP up equal the baseline, no `PHY change` line, no repair;
  the Mac lost the device at 03:20:28, 2 s after the charger client's `glink: start` (03:20:26). So the PHY registers
  did not change; the drop follows our charger GLINK traffic. Next steps: README-battery.md section 16 (0370 bisect).

### Change (bsd/dev/negroni_usb.c, hooks in negroni_adsp.c; logging in negroni_chg_glink.c)

- At the gadget start (before our controller start): map the PHY (0x088e3000), the EUD enable register (0x088e2000),
  GCC_QUSB2PHY_PRIM_BCR and GCC_EUSB3_0_CLKREF_EN; snapshot = baseline (a working link):
  `NEGRONI USB: PHY baseline at the gadget start: utmi0 .. utmi1 .. utmi5 .. common0 .. common1 .. common2 .. ctrl1 ..
  ctrl2 .. x0-3 .. cfg0 .. refclk .. | clkref_en 0x.. bcr 0x.. eud_en 0x..`.
- negroni_adsp.c calls `negroni_usb_adsp_event()`: 0 before PAS auth-and-reset, 1 at `THE ADSP IS UP`, 2 on a fatal
  stop. Each prints a snapshot (`PHY at the ADSP start`, `PHY at ADSP up`).
- PHY watch in ud_thread: a sample every 10 ms from the ADSP start until 10 s after ADSP up (30 s at most), else every
  100 ms. Every change: `NEGRONI USB: PHY change (ADSP start +N ms, up +M ms): cfg0 0->1 utmi0 ..->..` (all changes in
  the window, else 64 lines then every 100th). State lines: `PHY differs from the reference` / `back at the reference`.
- Repair (only after an ADSP start): when the sample differs from the reference (baseline, then the state after the
  last repair) and has not changed for `negroniusb_phyfix_ms` (1500), at most every 3 s: soft reconnect (0366 path)
  with a PHY init between the halt and the controller start: ref clock on (GCC 0x9c00c bit 0, wait for CLK_OFF to
  clear), block reset (BCR bit 0, 150 us), then the Linux `qcom_snps_hsphy_init` sequence (phy-qcom-snps-femto-v2.c;
  the same in ios-flame 0089): CMN override on, POR, FSEL (baseline), PLLBTUNE, REFCLK_SEL (baseline), VBUSVLDEXTSEL0,
  VBUSVLDEXT0, overrides X0..X3 (baseline; DT `qcom,param-override-seq` has e7 0f 17 03, logged for comparison),
  VREGBYPASS, SUSPEND_N(_SEL), SLEEPM, SIDDQ off, POR release, SUSPEND_N_SEL off, override enables as at the baseline.
  Log: `PHY before the re-init`, `PHY after the re-init`, `PHY re-init #n: ref clock was OFF, now on|on, ...`.
- Every 0366 soft reconnect after an ADSP start also runs this PHY init (a change that the watch cannot see, e.g. a
  ref clock that is on again but the PHY PLL lost, is then fixed by the no-SOF rule after 5 s).
- negroni_chg_glink.c: every message on PMIC_RTR_ADSP_APPS for 10 s after the first one, then notifications and other
  owners (UCSI 32779, USBC_PAN 32780) up to 200 lines: `NEGRONI BATTERY: glink: rx #n +T ms: owner .. type .. opcode
  0x.. len ..: <5 words> (BC_NOTIFY_IND | not battery_charger)`. Needs `negronichg_glink=1` (the channel is opened only then).

### Review fixes (Opus, 0368 ACCEPT after these)

- F1: no PHY init in a soft reconnect when the controller did not halt (a PHY block reset under a running DWC3 can leave
  CSFTRST stuck and kill the only link): `PHY init skipped in this reconnect: the controller did not halt`.
- F2: a PHY init (watch repair or reconnect) only when: the EUD does not own the PHY (`eud_en` bit 0 clear), ADSP up +
  `negroniusb_phyfix_holdoff_s` (default 5 s; HVDCP holds D+ ~1.25 s without register changes) has passed, the port is
  a host (the charger client's adapter type SDP 1 / CDP 3; without the client: a host seen = DSTS.SOFFN moved between
  two watch samples, `PHY watch: a host is there (SOF number moves)`; re-review fix), and (0369) VOOC is
  not active. Else `PHY repair waits: <reason>` (rate-limited).
- F3: at most 5 PHY inits per ADSP start, then log only. F4: at most 200 change lines in the 10 ms window.
- The re-init line also shows CFG0 bit 0 (UTMI datapath override) before -> after.

### Boot-args

- `negroniusb_phyfix_holdoff_s=N` (0-120, default 5): no PHY init before ADSP up + N s.
- `negroniusb_phyfix=0`: log only (no repair, no PHY init in reconnects). `1` (default): repair. `2`: also a PHY init +
  soft reconnect after each ADSP up (after the hold-off), even when no register changed.
- `negroniusb_phyfix_ms=N` (100-60000, default 1500): how long the PHY must stay unchanged before a repair.

### Test (RAM boot, `scripts/flash/test-boot.sh`)

1. Boot-args as the 02:55 boot (`negroniadsp=1 negroniadsp_step=15 negroniaudio_amp=1 negroniaudio_tone=1
   negronichg_glink=1 ...`), cable in a Mac port, `make usblog` running.
2. Expect before the ADSP: `PHY baseline at the gadget start: ...`, `PHY watch on: repair on (negroniusb_phyfix=1) ...`;
   then `PHY at the ADSP start`, `PHY at ADSP up`, the `PHY change (...)` lines (which registers the ADSP writes:
   the evidence), `glink: rx #1 +0 ms ...` lines.
3. If the link drops: within ~2 s after the last PHY change `soft reconnect #1 ...: the PHY differs from the reference`,
   `PHY re-init #1: ...`, then `bus reset`, `connected, speed 0`, `configured (1)`, en10 back on the Mac (`ioreg -p IOUSB`
   shows `Negroni iOS (USB Ethernet)`). The lines from the gap reach the Mac after the reconnect (ring), and the 0367
   boot log keeps them in any case (`make bootlog` after the next boot).
4. If the link drops but no PHY register changed: the 0366 rule (`no SOF for 3 s`, `soft reconnect ... no SOF`) now
   also runs the PHY init (`PHY re-init #1`). If it still does not come back, try `negroniusb_phyfix=2`, and send the
   boot log: the `PHY change` and `glink: rx` lines say what the ADSP did.

## 0371: reboot when the host stays lost (`negroniusb_lost_reboot=S`)

- Why [V]: with the ADSP on, the Mac lost the device for good ~2 s after our charger GLINK channel started (boots
  03:20:28 and 03:51:02). The phone kept running and could not be reached. Tests are RAM boots (`fastboot boot`) and
  boot_a holds a known-good image, so a normal reboot always brings USB back.
- Boot-arg `negroniusb_lost_reboot=S` (default 0 = off). In `ud_link_watch` (ud_thread only, never in panic mode: the
  panic hold loop has its own timed reset): when the device was configured at least once in this boot
  (SET_CONFIGURATION(1)) and then had no SOF for S s in one stretch (DSTS.SOFFN does not move; the 0366 soft
  reconnects do not end the stretch, only a SOF does), it:
  1. logs `NEGRONI USB: host lost for S s: rebooting (negroniusb_lost_reboot); DSTS ... link N (...), K soft
     reconnects, reason 0 set`,
  2. sets reboot reason 0 (normal boot, not fastboot) and schedules the USB "reboot" command path: 500 ms later
     `ud_ctl_poll` writes the boot log end mark `negroni_bootlog_end(4, "reset (USB host lost S s)")` (0367) and
     calls `negroni_reboot_reset()` (PSCI SYSTEM_RESET).
- Once per boot. Not before the first configuration (a boot with no cable never reboots by itself). A pending USB
- The driver forces VBUS valid, so a Mac system sleep longer than S s or a deliberate unplug also reboots the phone into
  boot_a (and ends a RAM-boot test). Use the arg on test images only (scripts/ios16/build.sh skips out/ios16-safe).
- The reset is PSCI SYSTEM_RESET with no VFS sync (same as the `reboot` command): a userland write at that moment can
  be lost, the same risk as a hard reset. Opus review 2026-10-27: ACCEPT.
  command (reset, power off, panic) wins.
- Boot line when on: `NEGRONI USB: reboot after S s without host once configured (negroniusb_lost_reboot)`.
- Pick S above the 0366 periods: e.g. `negroniusb_lost_reboot=60` (the L2 case waits 30 s before its first soft
  reconnect).
- Test: boot with `negroniusb_lost_reboot=20`, wait for en10, unplug. ~20 s later the phone reboots into boot_a.
  The 0367 boot log of that boot ends with "reset (USB host lost 20 s)" and has the "host lost" line.
