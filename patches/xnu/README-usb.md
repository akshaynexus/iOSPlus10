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

## 0374: keep the phone a Type-C sink (`negronichg_typec`)

### Observations [V: logs/bootlog-9.txt, t19 boot, `negronichg_glink=0 negroniusb_rails=2 negronichg_ulog=1`]

ULOG times are the ADSP's own counter (19.2 MHz, seconds). The USB times are ms after `THE ADSP IS UP`.

- 58.832-58.914: the charger PD starts. `apsd_result: 2` (SDP), `PartnerType=4, Voltage=5000 mV, Current=1500 mA`
  (Rp 1.5 A of the Mac), `USB Plug-In Event signalled`. The phone is a sink. This is correct.
- 58.914: `pmic_glink_open()`, `PmicTccRegister_Init`, `PmicTccPlatform_Init` (the PD starts its own TCPC/TCPM).
- 58.924 (10 ms later): `TypecModeAsSink: PmSchgTypec_GetSnkSrcMode[0x0]`, `TypeCPartnerType=0`, `bPlugIn[0]`.
  58.966: `Vbus Voltage = 5 mV`. The Mac took VBUS away: the attach is lost.
- USB +2110 ms: `PHY change ... utmi0 1010101->21212121 utmi1 0->1010101 ctrl2 6060606->e0e0e0e cfg0 0->3030303`.
  These are the downstream `dpdm` writes (UTMI_CTRL0 TERMSEL bit 5, UTMI_CTRL1 XCVRSEL, HS_PHY_CTRL2
  USB2_SUSPEND_N_SEL, CFG0 both overrides). +2161 ms: the overrides go away, `clkref_en 1->80000000` (the ADSP
  turns the PHY ref clock off: "no cable"), the link goes to suspend L2. The ADSP opens `PMIC_RTR_ADSP_APPS` here.
- 58.970: `tcpm_state_run: curr=0, next=1` (Look4Connection). `PmSchgTypec_GetPortRole[0x0]` = DRP.
- 59.548: the CC interrupt. `cid_status = 1`, `GetSnkSrcMode[0x1]`, `GetSourceStatus[0x5]`, `cc[2], ufp[0], dfp[5]`,
  `CC_STATUS = 28` (Looking4Connection, ConnectResult 0 = the phone shows Rp, CC2 = SRC.Rd).
  `ROLE_CONTROL = 0x07` (CC1 open, CC2 Rp, DRP 0). `ConnectPartnerType=2` (UFP), `PowerDirection=1` (provider).
  `OTG_ENABLE_REQ`, `SetVbus: VbusEn=1`, 59.769 ramp 180 ms, `POWER_STATUS = 1C` (SourcingVbus), PD header
  `DataRole=1, PowerRole=1` (DFP + source). `Source_Capabilities` goes out every 100 ms: `Message Failed` (no GoodCRC).
- So the Mac port (DRP) became the sink/UFP. A UFP Mac is not a USB host: the gadget has no host. Soft reconnects
  and PHY re-inits cannot change the Type-C role. Only a reboot resets it (the 0371 reboot after 60 s).
- `pmic_glink_tx(): glink handle is NULL` (several): the PD sends notifications (for example BC_OTG_ENABLE 0x50) to
  the AP, but nobody listens (`negronichg_glink=0`).

### Cause [I, strong: every step above is in the PD's log; not yet proven by a fix]

The PD's TCPM start puts the port in DRP and drops the attach. In the new DRP toggle the phone wins the source
role against the Mac. The phone then waits for PD from a sink that does not answer; the Mac does not get its host role.

Not the cause [V]: our charger GLINK client (t13 with `negronichg_glink=0` drops too), the charger writes (t12),
the PHY rails (t19 with `negroniusb_rails=2`: `0 changes (APPS votes held)`). The QSCRATCH forced VBUS valid does
not touch the PMIC (the PMIC reads VBUS and CC itself; the 5 mV comes after the Mac removed VBUS).

### Stock (Android) [V: out/src/op-modules/vendor/oplus/kernel/charger/charger_ic/oplus_battery_sm8450.[ch]]

- usb property ids (enum usb_property_id, .h:219-282, counted): 14 USB_OTG_AP_ENABLE, 15 USB_OTG_SWITCH,
  17 USB_TYPEC_CC_ORIENTATION, 18 USB_CID_STATUS, 19 USB_TYPEC_MODE, 21 USB_OTG_VBUS_REGULATOR_ENABLE.
- Write USB_TYPEC_MODE takes PM_TYPEC_PORT_ROLE_TYPE (.h:143-150): DRP 0, SNK 1, SRC 2, DISABLE 3.
  `oplus_ccdetect_disable()` (:1060) writes SNK 1 ("set UFP mode"); `oplus_ccdetect_enable()` writes DRP.
- Read USB_TYPEC_MODE gives the role: 0 = sink, other = source (`oplus_check_cc_mode` :10081-10092; `== 1` =
  OTG online, :8988, :9043).
- `qcom,otg_scheme = <0x00>` (live.dts:6815) = OTG_SCHEME_CID. The OTG switch (user setting) goes to the PD as
  USB_OTG_SWITCH (:8887). The PD has `oplus_set_otg_switch_status::set typec_mode = drp|sink_only` and
  `CidTOEvt_Handler::set typec_mode=snk` (adsp.b14 strings). With HLOS, BC_OTG_ENABLE 0x50 starts the external OTG
  boost (`otg_notification_handler`, GPIO `qcom,otg-booster-en-gpio`); without HLOS, nothing answers.
- Linux ucsi_glink / pmic_glink_altmode: no role write at init [I: they only read connector status]. They are not
  the difference.

### Change (bsd/dev/negroni_chg_glink.c, negroni_adsp.c/.h)

- Boot-arg `negronichg_typec` (default 0 = off, no change). Bits: 1 = sink only, 2 = USB_OTG_SWITCH = 0 (stock OTG
  off), 4 = watch only (reads and log lines, no write; ignores bits 1 and 2). Any non-zero value logs the role.
- With `negronichg_glink=1`: part of the charger client. With `negronichg_glink=0`: a typec-only client (same
  thread, no charger reads or writes, no charge loop). Both need `negroniadsp=1`.
  `negroni_chg_pmic_wanted()` lets negroni_adsp.c answer the ADSP's OPEN of `PMIC_RTR_ADSP_APPS` in both cases.
- At the open: read USB_TYPEC_MODE; at the first answer also read CID / OTG switch / CC orientation (one line), then
  (typec-only) BC_SET_NOTIFY_REQ, then bit 2: USB_OTG_SWITCH = 0, bit 1: USB_TYPEC_MODE = 1 (SNK). This comes before
  the first charger cycle: the PD's role decision came 0.6 s after its OPEN in t19.
- Watch: one read every 500 ms for 60 s after the open, then every 5 s, and at each notification 0x50 / 0x51 /
  0x53 / 0x55 / 0x57. When the read is 1 (source) or a BC_OTG_ENABLE 0x50 came: USB_TYPEC_MODE = SNK again, at most
  6 times per boot, at least 3 s apart. The sink-only port drops Rp; the Mac must then be the source and the host.
- Read semantics check (review): right after the first SNK write, one more read. If the role read was not 1 before
  and is 1 after (a sink-only write cannot make the phone a source), the read is the set role (0 DRP, 1 SNK). Then a
  read of 1 is not "source": the re-assert runs on a read of 0 (DRP again) or BC_OTG_ENABLE. Log line `typec:
  USB_TYPEC_MODE reads N before and 1 after the SNK write: the read is the set role ...`.
- Notification log lines: at most 20 (own budget); the 80 typec lines stay for the reads and writes.
- With bit 4 (watch only) the typec-only client still sends BC_SET_NOTIFY_REQ (a subscription, no property write).
- Safety: the SNK role only stops the phone from sourcing VBUS (no OTG boost); charging stays. The role is PD/PMIC
  state; the stock Android boot runs the PD's TCPM init again (DRP) [I: from t19, the TCPM start sets DRP].
- Not gated by `negronichg_wr` (0370) or `negronichg_wr_delay_s`.
- Cost: no OTG (a USB stick on the phone) while it is on. OTG needs `negronichg_typec=0`.

### Boot-args (test)

`negroniadsp=1 ... negronichg_glink=0 negronichg_typec=3 negronichg_ulog=1` (typec-only, both writes), then the same
with `negronichg_typec=1`. Watch only (role semantics): `negronichg_typec=4`. Keep `negroniusb_lost_reboot=60`.

### Expected lines

- `NEGRONI BATTERY: glink: start (typec only, negronichg_glink=0): channel PMIC_RTR_ADSP_APPS, negronichg_typec 0x3, no charger writes`
- `NEGRONI ADSP: 10 GLINK: the ADSP opens PMIC_RTR_ADSP_APPS (rcid 7)` (not "not ours")
- `NEGRONI BATTERY: glink: PMIC_RTR_ADSP_APPS is open (try 1)`
- `NEGRONI BATTERY: glink: typec: first answer +N ms after the open (open): USB_TYPEC_MODE 0 (...), CID 1, OTG switch ..., CC orientation ...`
- `NEGRONI BATTERY: glink: typec: write USB_OTG_SWITCH (OTG off) = 0 (first answer): ok (ret_code 0) +N ms after the open`
- `NEGRONI BATTERY: glink: typec: write USB_TYPEC_MODE (TYPEC_PORT_ROLE_SNK, sink only) = 1 (first answer): ok ...`
- PD side: `NEGRONI ULOG: ... usb_set_power_supply_properties::set typec_mode[1]`, `... otg switch[0]`, then at the CC
  interrupt NO `OTG_ENABLE_REQ`; instead `typec mode as sink` with GetSnkSrcMode 0, `PartnerType=4 ... 1500 mA`,
  `bPlugIn[1]`, PD header `DataRole=0, PowerRole=0`.
- USB: `soft reconnect #1 ...`, then the Mac sees the device again within a few seconds; no `host lost for 60 s`.
- Fail signs: `typec: ... REFUSED` (the PD does not take the property), `the phone is the Type-C source (role 1):
  sink only again (#n of 6)`, `still the source after 6 sink-only writes`.

### Guesses to check on the phone

- [I] The read semantics (0 sink / 1 source) come from the stock HLOS code only. The read-back after the first write
  (above) finds the "set role" case; before the review fix, that case gave 6 SNK writes in ~18 s (each one may restart
  the PD's Type-C state machine [I]).
- [I] If the write lands after the CC decision (no early answer), the re-assert path must move the role.
- [I] The PD may set DRP again on a CID event (`TypecOrRid_det_Cb::set typec_mode=drp`). Bit 2 (OTG switch off) is
  there for that case.

### Build [V]

out/kernel/local-20261026-232521/kernel.development.negroni sha256
d2d943ae8fa17bfe14ca22af9dc0b1801cd8ab6a4b306ac69eb4b55b37c243f9 (273 applied incl. 0374; only the 4 dxb skips; link
out/kernel/kernel.macho). compile-one of negroni_chg_glink.c and negroni_adsp.c: no diagnostic; the full build shows
only the old warning kind (-Wdeclaration-after-statement). Patch sha256 1bc62225ec4ab341d659bb3052e6fb12a4d9a31bc304173ba1c0943ecb853f3c. Not booted; no image.
Review (Opus): read-back fix + notification budget, patch sha256 dd5cd5734530aa606f72ef631795c72b3184c8fc81eee599f719f264f5862560;
compile-one of negroni_chg_glink.c: no diagnostic. The kernel above does not have the fix: rebuild.

## 0375: data-path watchdog (`negroniusb_idle_reboot=S`) and why 0371 did not fire in t22

### Observations [V: logs/usblog-20261026-233816.txt, logs/usbkick.*, t22 with `negroniadsp=1 negronichg_typec=3`]

- 05:05:19 the phone's log stream stops; `phone interface gone`. 05:05:25 `en10 up` (the Mac enumerated the phone
  again, high speed). `settime: no reply in 30 s`. Ping, ARP and the ctl channel got no answer. The live log did not
  come back.
- 05:10:02 `en10 up` after `usb-host-kick reenum` (IOKit USBDeviceReEnumerate): a new enumeration, still no reply.
- 05:12:41-05:14:01 `usb-host-kick suspend 80` (`suspend: 0x0`, `held 80 s`): no reboot, and the Mac log has NO new
  `en10 up` / `interface gone` line in these 80 s. The phone needed a button reset.
- The enumerations prove that ud_thread handled ep0 at 05:05:25 and 05:10:02 (descriptors and SET_CONFIGURATION need
  it; the host-side MAC comes from our string descriptor).
- Mac side: `scripts/debug/usblog.sh` sends `settime` only when the interface comes up (retried 30 s); it sent
  nothing periodic. macOS's own traffic on en10 (IPv6, mDNS, ARP) has no fixed period.

### Why 0371 did not fire (code reading)

- The `configured once` latch (`ud.ever_configured`) is set in ud_configure and never cleared: a re-enumeration does
  not reset it [V code].
- The 0371 stretch ends only when DSTS.SOFFN changes. In L2 (host suspend) the SOFFN does not move [V:
  bootlog-9/-10, `link 3 (suspend L2)` with a fixed DSTS]. With SOFs stopped and ud_thread running, 0366 makes a
  soft reconnect 30 s into the stretch (configured + L2 = the long period, 6 x 5 s). The pull-up goes off for 100 ms;
  the Mac sees a disconnect and enumerates the device again (a new `en10 up` without our address). The Mac log has
  no such line in the 80 s. So one of these is true [I, the log cannot tell which]:
  1. SOFs kept coming: macOS did not really suspend the port (USBDeviceSuspend returns 0x0 but IOUSBHost keeps the
     port active while the ECM driver has open pipes [I]). Then 0371 cannot fire by design: the host is there.
  2. ud_thread did not run `ud_link_watch` (stuck in some step after the enumeration, for example in a call into
     the network stack: `dlil_post_msg` at SET_INTERFACE, `ifnet_input`, or `ud.lock`). 0371 and 0366 run only in
     ud_thread, so neither can act.
- Also by design: a held host suspend can only reach 0371 when 0366 is off or slower than S. With
  `negroniusb_reconnect=5` (30 s in L2) and S = 60, our own reconnect wakes the host first. So `usb-host-kick
  suspend` is not a way to trigger 0371 while 0366 runs.
- Hardening (small): one SOFFN change alone (for example the frame number of a restarted controller) ended the
  0371 stretch. Now the stretch ends only when SOFFN changed in two 100 ms samples in a row (`ud.sof_moved`). The
  0366 rules are unchanged.

### Change (bsd/dev/negroni_usb.c)

- Boot-arg `negroniusb_idle_reboot=S` (default 0 = off). With S > 0 a separate kernel thread `ud_idle_thread`
  starts (not ud_thread, not the endpoint queues). It samples every 250 ms.
- Arm condition: the device was configured once in this boot (`ud.ever_configured`) AND at least one host frame
  reached the bulk OUT path (`ud.out_at` != 0: any frame of valid length in `ud_rx_frame`, for the command server or
  the stack). A boot with no cable or no host traffic never reboots.
- Fire condition (either):
  - no bulk OUT frame for S s (also the case when ud_thread is stuck: then nobody reads the RX ring), or
  - one IN transfer active for S s without XferComplete (`ud.tx_busy` since `ud.tx_start_at`): the phone's TX path
    is dead (the log stream and the ctl replies stop) while the host may still send.
- Then: one line `NEGRONI USB: no USB data for S s: rebooting (negroniusb_idle_reboot); <why>; last OUT frame ... ms
  ago (N OUT frames), IN transfer active|idle ... ms, last IN done ... ms ago, txq N, tx drops N, rx N tx N frames;
  SOF ... ms ago, DSTS 0x... link N (...), [not ]configured, N soft reconnects; ud_thread ... ms ago in step <step>,
  last event 0x...`, then `idle reboot: reason 0 set`, 500 ms wait, `negroni_bootlog_end(4, "reset (USB data idle S
  s)")` (0367), `idle reboot: PSCI SYSTEM_RESET`, `negroni_reboot_reset()`. The watchdog thread does this itself
  (ud_ctl_poll runs in ud_thread, which may be the stuck part). A thread_call resets 5 s later if the end mark
  blocks (UFS lock).
- Once per boot. Never in panic mode (the panic hold loop has its own timed reset). A pending USB command (reset,
  power off, panic) wins: the line `idle reboot waits: a USB command is pending (N)`. Only when that command is still
  not run 5 s after its time (ud_thread stuck), the watchdog resets; the command's reason stays.
  `ud.ctl_action = UD_CTL_WATCHDOG` (compare-and-swap from NONE) blocks new commands (`error: busy`) and 0371.
- Diagnostics (same thread, also without a reboot): `ud_thread has not run for N ms: in step <step>, last event
  0x..., DSTS ..., SOF N ms ago (0375 watch)` when ud_thread has not started a loop pass for 5 s (at most 8 per
  boot), and `ud_thread runs again (0375 watch)`. Steps: events, rx poll, ctl poll, link watch, PHY watch, sleep,
  `dlil_post_msg (link event)`, `ifnet_input`, `ud.lock (TX complete)`, `ud.lock (drop data)`, `soft reconnect`. The
  watchdog keeps its own DSTS.SOFFN sample, so "SOF N ms ago" answers question 1/2 above next time.
- Boot line: `NEGRONI USB: reboot after S s without USB data once configured and host data came
  (negroniusb_idle_reboot)`.

### Host side

- The host must send a bulk OUT frame at least every S s. `scripts/debug/usblog.sh` now sends a UDP broadcast
  `keepalive` to 192.168.7.255:5142 every 10 s (`USBLOG_KEEPALIVE=N`, 0 = off). A broadcast needs no ARP (in t22
  ARP got no answer, so a unicast would not leave the Mac) and no reply; the phone's stack drops it silently. An
  old usblog.sh (started before this change) does NOT send it: restart the usblog tmux job before a test image
  with this arg.
- `scripts/ios16/build.sh` adds `negroniusb_idle_reboot=90` to every image except out/ios16-safe (`IDLE_REBOOT=S`,
  `IDLE_REBOOT=0` = off), next to `negroniusb_lost_reboot=60`.
- A Mac sleep longer than S s, or a test without usblog.sh, reboots the phone into boot_a (as 0371).
- `scripts/debug/usb-host-kick.sh reenum|suspend [S]|resume` (tools/usb-host-kick, IOKit, sudo): host-side
  re-enumeration / port suspend. In t22 `reenum` re-enumerated the gadget, but the data path stayed dead; `suspend
  80` did not trigger 0371 (see above). With 0375 the way to recover a dead data path is to wait S s (or stop the
  sender), not the suspend.

### Test (RAM boot, `negroniusb_idle_reboot=30` for a short test)

1. Boot, start `scripts/debug/usblog.sh` (new version), wait for `en10 up` and the boot line.
2. Safe trigger: stop only the keepalive and every other sender for S s. Simplest: stop the usblog job and
   `sudo ifconfig en10 down` for S + 10 s (no OUT frames; the phone cannot be reached in this time anyway), then
   `ifconfig en10 up`. Or run usblog with `USBLOG_KEEPALIVE=0` and wait (macOS traffic may still keep it alive).
3. Expect: `no USB data for 30 s: rebooting (negroniusb_idle_reboot); no OUT frame` (or `no OUT frame and IN
   stuck`), `idle reboot: reason 0 set`, `NEGRONI BOOTLOG: boot N ends: restart (reset (USB data idle 30 s))`,
   `idle reboot: PSCI SYSTEM_RESET`, then boot_a boots. `op10tool bootlog` of that boot ends with "reset (USB data
   idle 30 s)".
4. Negative test: with the keepalive on, no reboot for several minutes; `usbstats` works.

### Build [V]

out/kernel/local-20261026-235425/kernel.development.negroni sha256
26d079d28ab223ad7d2444ac9e5ec36b3117d089ed51cc231828be592ab31384 (274 applied incl. 0375; only the 4 dxb skips; link
out/kernel/kernel.macho). compile-one of negroni_usb.c and the full build: only the old warning kinds. Patch sha256
1e39eaeca3a0aa16a0c2615a17e835cd626772cd4b454c627b3b16e7a71f50f0. Not booted; no image. Not reviewed yet.

### Review (Opus, 2026-10-27): ACCEPT after 4 fixes [V: compile-one OK, only the old warning kinds; not built, not booted]

- IN-stuck rule race: the watchdog read `tx_start_at` before `tx_busy`, with no barrier. A new transfer that started
  between the two reads (after 90 s with no TX) paired busy=1 with the old start time: a false reboot. Now
  `ud_tx_kick_locked` stores `tx_start_at` first and `tx_busy` with release; the watchdog loads `tx_busy` (acquire)
  first.
- `ctl_action`: one compare-and-swap for both cases (also the take-over from a pending command; the plain store
  after the CAS is gone). `ud_ctl_poll` takes its action with a CAS (no double reset / double end mark when ud_thread
  wakes during a take-over). `ud_ctl_schedule` (USB commands, 0371) sets the action only from NONE (it no longer
  overwrites UD_CTL_WATCHDOG after the caller's check). The watchdog reads `ctl_action` with acquire before
  `ctl_deadline` (no stale deadline makes an early take-over).
- If PSCI refuses the reset, the watchdog thread sets `ctl_action` back to NONE before it returns (else every USB
  command answers `error: busy` for the rest of the boot).
- usblog.sh: `exec python3` in keepalive (the EXIT trap now stops the sender; before, an orphan python kept sending
  after usblog stopped). Linux: `ip addr replace ... brd +` (without a broadcast address 192.168.7.255 is a unicast
  that needs ARP).
- Checked, no change: idle IN endpoints do not count (only EP_TX `tx_busy`; EP_INT notifications are not in the rule);
  macOS keeps a bulk IN read pending while the ECM interface is up; 64-bit aligned loads/stores are single-copy atomic
  on arm64; the 0371 two-sample rule still fires on an unplug (no SOFFN change -> `sof_moved` false, `lost_since` stays).
- Patch sha256 after the fixes: 831dfaa03a014b1e125e64ec8ed3c163e54b6687175a433a8e63a3bad3ef0aa4. The kernel above is from the old patch: rebuild.

## 0381: the data path after a re-enumeration (`negroniusb_datafix`) and what bootlog-12 shows about t22

### What the logs contain [V]

- `logs/bootlog-12.txt` is boot 12 = t22 (line 6: `negroniadsp=1 ... negronichg_glink=0 ... negroniusb_rails=1
  negronichg_ulog=1 negronichg_typec=3 negroniusb_lost_reboot=60`, no `negroniusb_idle_reboot`). Line 9: `console bytes
  22025771 (the first 17831467 bytes were overwritten in the 4 MiB ring)`. The file starts at uptime 21208 s (line 14,
  GPU WATCH) and ends at 25560 s (line 3). The boot started at 05:04:20 (Mac `interface gone` at
  usblog-20261026-233816.txt:205411), so the ADSP start and the link drop (uptime ~57-59 s) are NOT in it.
- In the 26155 lines: 0 `NEGRONI USB`, 0 `NEGRONI CTL`, 0 `NEGRONI ULOG`, 0 `typec`, 0 `NEGRONI NET` lines.
- 76 `BATTERY: charge:` lines, from line 76 (`external=1 ... adapter 5004mV 896mA`) to line 25641 (`external=1 ... 4951mV
  1615mA`): the Mac gave VBUS for the whole tail; the phone was the sink. One sample (lines 22509-22510, uptime ~24710 s)
  reads `usbin 0mV`, `external=0`, but the same raw line has `iin 1417mA`; the next sample (22521) is 4875 mV
  [I: an ADC read glitch, not an unplug].
- The end (lines 26062-26155): `exec powermenu-helper`, launchd shutdown, `MACH Reboot`, `boot 12 ends: restart (restart
  (reboot))`. The owner restarted iOS from the power menu at 12:10:20; it was not a button hard reset.
- The live log of the drop is in usblog-20261026-233816.txt: 206573 `THE ADSP IS UP` (05:05:17), 206750 `glink: start
  (typec only ... negronichg_typec 0x3)`, 206752 `the ADSP acks our open of PMIC_RTR_ADSP_APPS`, 206976 the last raw
  `event 0x0000c046` (05:05:18), 207096 `phone interface gone` (05:05:19). No `PMIC_RTR_ADSP_APPS is open`, no `typec:`
  line before the drop.
- The usblog file has no line after 05:10:13 (file time 05:10). So nothing shows whether usblog.sh still ran during the
  05:12:41 `usb-host-kick suspend 80` (the 0375 text "no new en10 up in these 80 s" has no proof).

### Findings

1. Order of the typec writes and the drop [V t19 + t22]. The typec client writes only after the ADSP opens its side of
   PMIC_RTR_ADSP_APPS (`negroni_glink_open` waits for the ADSP's OPEN, negroni_chg_glink.c "no OPEN from the ADSP").
   In t19 (bootlog-9) the PD's PHY writes (2953, 2962: `clkref_en 1->80000000`) come BEFORE the ADSP's OPEN (2967), and
   the ULOG shows `pmic_glink_open` (3431), `PmicTccPlatform_Init` (3434) and the lost sink attach 10 ms later (3443-3445).
   In t22 the drop (05:05:19 = ADSP up + 2 s, the same time as the PHY ref clock off in bootlog-3/-9) came before any typec
   line. So the first drop cannot be stopped by a GLINK write: the channel opens with the TCPM start. An earlier write
   "at the first GLINK open" is not possible (our open is acked at once, but the PD answers no request before its own
   OPEN) [I strong]. The SNK write worked afterwards: the Mac was the source for 7 h (battery lines) and the host 6 s
   after the drop.
2. Event 0x0000c046 [V decode, DWC3 databook / Linux core.h]: bit 0 = 0 (endpoint event), bits 5:1 = 3 (physical
   endpoint 3 = ep 0x81, bulk IN, EP_TX), bits 9:6 = 1 (XferComplete), bits 15:12 = 0xc (IOC | LST): a TX batch of the
   live log ended normally. It is not a flood: ud_thread prints only the first 200 events of a boot (60 again after a
   soft reconnect). In the t22 boot: 196 raw event lines, 83 of them c046 (usblog 205411-207096); the last one is ~1 s
   before the drop. So TX worked until the drop.
3. Gadget reconnect handling [V code]: a bus reset runs `ud_drop_data` (ENDTRANSFER on EP_TX/EP_RX/EP_INT, DALEPENA 3,
   not configured, KEV_DL_LINK_OFF); SET_CONFIGURATION(1) sets the endpoints again (DEPSTARTCFG 2, SETEPCONFIG, RX
   ring); SET_INTERFACE alt 1 sends NETWORK_CONNECTION and KEV_DL_LINK_ON. ue0 is never detached or re-plumbed: only the
   link events and SIOCGIFMEDIA change; its address is set once at boot. The TX queue keeps old frames over a reset.
   The live log socket is kept for the whole boot.
4. ud_thread [V]: it ran at 05:05:25 and at 05:10:02 (both enumerations need ep0 answers, and only ud_thread polls the
   events). After 05:10 nothing tells [U].
5. Why 0371 did not fire for 7 h [V code + V empty tail]: with ud_thread running, a SOF-less stretch of 60 s reboots,
   and 0366 prints `soft reconnect #N` (every 10th) and `no SOF for 3 s`. None of these lines is in the 70-min tail. So
   in that time either SOFFN kept moving (the Mac kept the port active: host present) or ud_thread did not run [I: the
   first one is more likely; the stats line `ue0 rx ... tx ...` prints only above 100 rx / 500 tx frames per 10 s, so
   its absence proves nothing].
6. Role vs controller mode [V code, I hardware]: nothing in the ADSP path writes the DWC3 (GCTL PRTCAPDIR) or QSCRATCH;
   the PD writes the HS PHY (UTMI overrides, cfg0, ref clock: 0368) and the PMIC Type-C block. `ud_hw_start` sets
   PRTCAPDIR = device at every soft reconnect. The enumerations prove device mode at 05:05:25 and 05:10:02.
7. Root cause of the dead data path: NOT in the logs [U]. The candidates that match all observations (enumeration works,
   no frame either way, no USB line, no 0371): (a) the link came up at full speed (the PD's PHY override TERMSEL/XCVRSEL =
   full speed, cfg0 = 3, seen in bootlog-3/-9) while the gadget keeps 512-byte bulk packets, a high-speed-only value: ep0 works
   (64), bulk does not; the "high speed" of the 0375 text has no log line behind it; (b) a dead IN path (an IN transfer that
   the host never reads, so tx_busy stays: no log, no ARP answer, no ctl answer); (c) the stack lost 192.168.7.2 or its
   ARP state (no ARP answer; the log socket holds its datagrams for an ARP entry that never resolves). 0381 tells them
   apart on the next test and repairs (a) and (b) without a reboot.

### Change (bsd/dev/negroni_usb.c), boot-arg `negroniusb_datafix` (default 0 = off), `negroniusb_datafix_s` (default 10, 3..120)

- Bit 1 (re-init): ud_thread checks every 100 ms. Dead = configured, data alt 1, SOFFN moved in the last 1 s, and either
  no host frame `negroniusb_datafix_s` s after SET_INTERFACE alt 1, or one IN transfer active that long. Then two state
  lines and a full re-init: soft reconnect with a PHY init (0368 `hp_init`, one init past the 5 per ADSP start; EUD,
  hold-off and VOOC rules stay; no PHY write with `negroniusb_phyfix=0`), TX queue dropped, ue0 IFF_UP|IFF_RUNNING,
  192.168.7.2 added again when it is gone (`ifnet_get_address_list_family`), a new live-log socket. The ue0 part runs in
  a thread call (`ud_df_stack`), never in ud_thread: ud_thread serves ep0 and the command server and must not wait for
  a stack lock (review). ue0 is not re-plumbed (PF_INET stays attached from boot). The host enumerates again. At most 3 re-inits per episode
  (an episode ends with the first host frame after a link up: `data path works`); then the state lines every 300 s
  (at most 24) and 0371/0375 decide.
- Bit 2 (raw link): the live log goes only as raw UDP frames to the host MAC (the old fallback path: no socket, no
  route, no ARP), and ud_thread answers ARP requests for 192.168.7.2 itself (only well-formed Ethernet/IPv4 requests, opcode 1, with a
  unicast sender MAC; one 42-byte reply to the sender's MAC; the frame still goes to the stack). The
  command server already answers raw. So log, ping and settime do not depend on the stack.
- Bit 4 (watch only): the state lines of bit 1, no re-init.
- Bit 8 (full speed): when connect done reports full speed (DSTS.CONNECTSPD 1 or 3), the configuration descriptor gives
  64 for ep 0x81 and ep 0x01, SETEPCONFIG uses 64, and the TX pad rule (no ZLP) uses 64. High speed is unchanged (512).
- Any non-zero value: ARP requests for 192.168.7.2 are counted; `the link is not high speed` line at connect done.
- Not changed: 0366, 0368 (except the one-shot cap bypass), 0371, 0375, the panic mode (only the pad rule reads the
  max packet).
- Cost [I]: bit 1 needs a sender on the Mac (usblog.sh: settime at link up, keepalive every 10 s; macOS's own IPv6/mDNS
  frames at link up). An enumeration with no host frame at all (en10 not up on the Mac) gives 3 re-inits, then only
  the state lines.

### Boot-args (test)

t22 args + `negroniusb_idle_reboot=90 negroniusb_datafix=0xb` (1 + 2 + 8; datafix_s 10). Order of the guards: 3 re-inits
(~45 s) before 0375 (90 s without a host frame). First a normal boot (ADSP off) with `negroniusb_datafix=0xb`: no
`data path dead` line, log and `op10tool ctl ping` work (raw log path, kernel ARP answer).

### Expected lines

- Boot: `NEGRONI USB: data path (negroniusb_datafix=0xb): re-init when dead (3 per episode), raw live log + kernel ARP answer, 64-byte bulk at full speed, check after 10 s (negroniusb_datafix_s)`
- After the ADSP drop and the new enumeration, if the data path is dead:
  `NEGRONI USB: data path dead (re-init 1 of 3): no frame from the host 10 s after its link up (SET_INTERFACE alt 1); speed S (...), configured, data alt 1, ... OUT frames N (... ARP for 192.168.7.2 N), IN active|idle ...`
  `NEGRONI USB: data path dead (re-init 1 of 3) state: DSTS ... DALEPENA ... ep busy rx R tx T int I, TX TRB0 ctl 0x..., RX ring N of 32 armed, PHY as at the gadget start|DIFFERS ..., ue0 flags 0x..., N soft reconnects`
  (+ `PHY now (0381): ...` when the PHY differs), `soft reconnect #N ...: data path dead (negroniusb_datafix)`, `PHY re-init #N`,
  `data path re-init done: PHY init done, N queued frames dropped, ue0 + 192.168.7.2 in a thread call, new log socket`,
  `data path re-init, stack part: ue0 flags 0x..., 192.168.7.2 on ue0|was GONE, added again` (watch only / used up:
  `data path state, stack part: ... 192.168.7.2 on ue0|GONE from ue0`),
  then `bus reset`, `connected, speed S`, `configured (1)` and `data path works: N OUT frames ... after 1 re-inits`.
- How to read it: speed 1/3 = cause (a), bit 8 fixes it; `IN active` + `ARP for 192.168.7.2` > 0 = cause (b); `GONE from
  ue0` or the log arrives (raw) but the stack does not answer = cause (c).
- These lines also land in the boot log; read it with `make bootlog` even when USB stays dead.

### Build [V]

out/kernel/local-20261027-100646/kernel.development.negroni sha256
f5af17707f1294d0c1eebb5d137aeaaa8329b17d050e35f15841c4ac8d5504bf (278 applied incl. 0381; only the 4 usual dxb skips;
link out/kernel/kernel.macho). Patch sha256 0a154acb984893a42dc83040d01009a26d86c9912747bd3facf2101293a31c45 (before the review).
Compile-one of negroni_usb.c: the same 6 warnings as before the patch (old kinds); the full build shows only the old
kinds for this file. Not booted; no image.

### Review (Opus, 2026-10-27)

Fixed in the patch (sha256 c706cfd146c6a80d42d746c78f86346124ec099bff6b6acd9fccc28a3965e254, compile-one: the same 6
old warnings; no full build yet): (1) the ue0 address list, ifnet_set_flags and SIOCAIFADDR ran in ud_thread; a stuck
stack would block ep0 and the "reboot" command; now a thread call. (2) No ARP answer to a group sender MAC. (3) With
`negroniusb_phyfix=0` the re-init set `hp.reinit_next` that nothing cleared, and its line said "see the reconnect
lines"; now no PHY flags and "off (negroniusb_phyfix=0)".
Checked, no change: default 0 is the old behaviour (512 everywhere, no watch, no ARP code, same log path, same ue0
setup code); descriptor offsets 70-71 / 77-78 are wMaxPacketSize of ep 0x81 / 0x01; SETEPCONFIG and the pad rule use the
same value; high speed keeps 512; the state lines read only (PHY reads as hp_watch does every 100 ms). 0371 counts from the
re-init like after an hp_watch reconnect; 0375 runs in its own thread and its OUT timer is not reset by a re-init.
Open [I]: the trigger counts from SET_INTERFACE alt 1; with usblog.sh the first host frames (settime + ARP) come ~1-3 s
after en10 appears, so 10 s is enough; a quiet host (no usblog, en10 inactive) gives 3 re-enumerations, then lines
only. The 3 tries come back only after a working frame (not after an unplug).
