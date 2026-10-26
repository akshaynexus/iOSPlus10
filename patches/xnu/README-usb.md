# USB Ethernet gadget (bsd/dev/negroni_usb.c)

The base driver comes from slop (patches 0072-0077, 0081, 0119: DWC3 at 0x0a600000, ep0, VBUS override, CDC-ECM,
live log). Our patches: 0210 (UDP command server), 0212 (settime), 0282 (bus reset drops the data endpoints),
0360 (panic mode, README-panic.md), 0361 (throughput, this file), 0366 (reconnect after unplug or a Type-C
re-attach, this file), 0368 (the HS PHY after the ADSP start, this file), 0371 (reboot when the host stays lost, this file), 0372 (the PHY supply rails and the ADSP, this file), 0373 (the
charger PD log over GLINK, this file). Host side: docs/usb-network.md.

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

## 0372: the USB PHY supply rails and the ADSP (`negroniusb_rails`)

### Observations [V]

- t11 (03:51, charger GLINK client on), t12 (03:53, `negronichg_wr=0`: no charger writes), t13 (03:58,
  `negronichg_glink=0`: no charger client at all): the Mac loses the device 2-3 s after `THE ADSP IS UP`
  (t13: up 03:58:26, gone 03:58:29). So our GLINK traffic is not the cause. The ADSP starts the drop alone.
- The 0368 PHY watch: the PHY registers, GCC BCR, ref clock and EUD read the same at the ADSP start and at ADSP up.
- t13: the soft reconnects (0366) and PHY re-inits (0368) brought nothing back. The phone kept running: the 0371
  reboot (60 s) put it into boot_a, and the Mac saw it again at 04:00:21 (a new boot, `load_init_program`).
- In t11 the ADSP acked our open of PMIC_RTR_ADSP_APPS at 03:51:00, but its own OPEN (the charger PD start) did not
  arrive before the drop at 03:51:02. So the drop comes at about the time the charger PD starts.
- The ADSP image (`out/firmware/adsp/adsp.b14` strings) holds PMIC rail resources `/pm/ldob2`, `/pm/ldob5`,
  `/pm/ldob6`, `/pm/ldoc1` (each with `/en`, `/mode`, `/mV`), next to `/pm/ldoc10`, `/pm/ldoh2`.
- live.dts `hsphy@88e3000`: `vdd-supply` = pm8350_l5 (ldob5, 0.88 V), `vdda18-supply` = pm8350c_l1 (ldoc1, 1.8 V),
  `vdda33-supply` = pm8350_l2 (ldob2, 3.072 V). `ssphy@88e8000` `core-supply` = pm8350_l6 (ldob6, 1.2 V). So the
  ADSP votes exactly the four USB PHY rails.
- live.dts rpmh-regulator nodes for these rails: `qcom,set = 3`, `qcom,init-voltage` and `qcom,init-mode = 4` (HPM).
  The Linux rpmh-regulator driver sends these votes from APPS at probe, and the PHY driver enables the rails.
  Our XNU kernel sends no RPMh vote for them (negroni_rpmh.c votes only ldoc11, camera and Wi-Fi/BT rails).
- Other ADSP strings: `charger_detection_inital_detection: adsp rerun status`, `battmngr_tech_schgp_chg_rerun_apsd`,
  `PmicTccPlatform_..._TypecModeAsSink`, `oplus_set_otg_switch_status::set typec_mode = drp|sink_only`,
  `Sent Hard Reset Signal Successful`, `Data Role Changed`. The charger PD reruns APSD at its start and runs a USB PD
  stack.

### Cause [I, not proven]

When the charger PD starts, it votes the PHY rails on for its BC1.2/APSD detection, then lowers or drops its votes.
RPMh sets each rail to the highest vote of all masters. APPS has no vote, so the rail follows the ADSP alone and
goes off (or to LPM). The analog side of the HS PHY (vdda33: pull-up and HS transceiver) loses power. The digital
registers still read (that is why 0368 saw no change), and a soft reconnect or PHY init cannot help. This explains
all three tests and why only a reboot (XBL powers the rails again) brings the link back.
Other candidates are not excluded: a PD Hard Reset or Type-C role change from the charger PD, or the APSD rerun
with our pull-up on. 0373 (the charger PD log) and the 0372 rail log tell which one is true.

### Change

- `negroni_usb.c` (`ur_event`, called from `negroni_usb_adsp_event`, the ADSP thread): boot-arg `negroniusb_rails`:
  - `0`: off.
  - `1` (default): log only. SPMI observer reads of the four LDOs (STATUS1 0x08, VSET 0x40/0x41 in mV, MODE 0x45,
    EN_CTL 0x46): at the ADSP start, at ADSP up, at a stop, and every 50 ms on a separate thread from the ADSP start
    until ADSP up + 30 s (60 s at most). One line per change (at most 100), one end line.
  - `2`: as 1, plus APPS RPMh ACTIVE votes before PAS auth-and-reset: ldob5 880 mV, ldoc1 1800 mV, ldob2 3072 mV,
    ldob6 1200 mV, all HPM (mode 7) and enabled (`negroni_rpmh_usb_rails`, negroni_rpmh.c). The vote is sent once per
    boot (again only if it failed). RPMh takes the highest vote, so a lower ADSP vote can no longer turn them off.
- `negroni_spmi.c`: read allowlist + SID 1 peripherals 0x41/0x44/0x45 (PM8350 L2/L5/L6) and SID 2 peripheral 0x40
  (PM8350C L1), offsets 0x08/0x40/0x41/0x45/0x46 only. No write.
- The PMIC5 LDO register meaning (VREG_READY = STATUS1 bit 7, VSET mV, MODE 7 HPM / 5 LPM / 3 RET, EN_CTL bit 7) is
  [I] from Linux qcom_spmi-regulator.c; the log shows raw values. If the LDO peripherals have no APID for EE 0, the
  line shows `read 0x<addr> rc 4` (any failed register read prints the rail as an error, never a half-valid line;
  then only the vote test can answer).
- Safety: the votes use the DT voltages (min = max for ldoc1/ldob2/ldob6; ldob5 880 mV is the DT minimum, RPMh keeps a
  higher vote of another master). HPM only raises the current limit. These are the votes Android holds all the time.

### Boot lines

```
NEGRONI USB: PHY rails (negroniusb_rails=2): log + APPS RPMh votes before the ADSP start
NEGRONI USB: PHY rails at the ADSP start: L5B vdd: st .. 880 mV mode .. en .. | L1C vdda18: ... | L2B vdda33: ... | L6B ss: ...
NEGRONI RPMH: 0372 USB PHY rail ldob5 880 mV HPM on: voted (errno 0)     (x4: ldob5, ldoc1, ldob2, ldob6)
NEGRONI USB: PHY rails: APPS votes ldob5 880, ldoc1 1800, ldob2 3072, ldob6 1200 mV HPM: all voted (fail mask 0)
NEGRONI USB: PHY rails after our votes: ...
NEGRONI USB: PHY rails at ADSP up: ...
NEGRONI USB: PHY rails change #n (ADSP start +N ms, up +M ms): ...          (only when a register moves)
NEGRONI USB: PHY rails watch end: N changes (APPS votes held); now ...
```

### Test

1. Evidence boot (no behaviour change): t13 boot-args + `negroniusb_rails=1 negronichg_ulog=1 negroniusb_lost_reboot=60`.
   Read the boot log of that boot after the 0371 reboot (`make bootlog` with an image that has the 0367 command).
   A `PHY rails change` line 2-3 s after ADSP up with L2B `en 00` (or mode 05/03) proves the cause.
2. Fix boot: the same with `negroniusb_rails=2`. Expected: the four `voted` lines before `PAS auth and reset`,
   no `PHY rails change` with `en 00`, and the Mac keeps en10 after `THE ADSP IS UP` (no `usblog: phone interface gone`).
3. If 2 still drops: the rails are not the cause. The `NEGRONI ULOG:` lines (0373) of the same boot say what the
   charger PD did (APSD rerun, Type-C mode, Hard Reset, data role).

### Verification

- [V] compile-one OK for negroni_usb.c, negroni_rpmh.c, negroni_spmi.c, negroni_chg_glink.c, negroni_adsp.c (only old
  warning kinds). Full build: out/kernel/local-20261026-225104/kernel.development.negroni sha256
  201a9ae54fc9ce02c9062e8e16de90adacffbd23272a12f6eee7f5c3621eaf07 (271 applied incl. 0372 + 0373, 4 dxb skips).
- [ ] Phone: not booted.

## 0373: the charger PD log over GLINK (`negronichg_ulog=1`)

- The live DT has a second pmic_glink device: `qcom,pmic_glink_log` on channel `PMIC_LOGS_ADSP_APPS` with
  `qcom,charger_ulog_glink`. Protocol [V: Linux v6.12 drivers/soc/qcom/pmic_pdcharger_ulog.c]: request
  {owner 32778, type 1, opcode 0x18 GET_CHG_ULOG_REQ, u32 log_size 8192}; answer {header, 8192 bytes of text}. Linux
  asks again 1 s after each answer and prints each non-empty line.
- 0373: a 4th GLINK channel in negroni_adsp.c (`NEGRONI_GLINK_ULOG`, lcid 4); the ADSP's OPEN of
  `PMIC_LOGS_ADSP_APPS` is answered only with `negronichg_ulog=1` (else "not ours, left unanswered" as before).
  A thread in negroni_chg_glink.c (started from `negroni_chg_glink_start`, independent of `negronichg_glink`)
  opens the channel (first wait 30 s, then 5 s per try with a 25 s rest between tries, at most 40 tries, then the
  thread ends: no 1 kHz GLINK poll for the whole boot when the charger PD never opens it), sends the request every `negronichg_ulog_ms` (default 1000,
  200-60000) for 120 s after the open, then every 5 s, and prints every line as `NEGRONI ULOG: <text>` until
  `negronichg_ulog_lines` (default 3000) lines. The RX callback only copies (it runs under the GLINK lock).
  The 8204-byte answer needs an RX intent of that size: the ADSP asks with RX_INTENT_REQ, 0274 grants up to 0x4400.
- Read only: the request asks for log text. Default off (`negronichg_ulog=0`): no change.
- The lines go to the kernel log, so the 0367 boot log keeps them when the USB link is gone.
- Boot lines: `NEGRONI ULOG: start: channel PMIC_LOGS_ADSP_APPS, ...`, `NEGRONI ULOG: PMIC_LOGS_ADSP_APPS is open (try 1)`,
  then the ADSP's own lines, for example `NEGRONI ULOG: ... charger_detection_inital_detection: adsp rerun status=0x..`,
  `... TypeC StateMachine = .., CCStatus= ..`, `... PE: PDContractState=.., DataRole=.., PowerRole=..`. End line:
  `NEGRONI ULOG: end: N lines, N requests, N answers, ...`.
- Failure lines: `PMIC_LOGS_ADSP_APPS not open (try n, rc 60)` (the charger PD never opens it), `no answer to request #n
  in 1.5 s`, `GLINK: PMIC_LOGS_ADSP_APPS: the ADSP asks for an intent of N bytes: refused` (answer too big).
