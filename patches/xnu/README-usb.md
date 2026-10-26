# USB Ethernet gadget (bsd/dev/negroni_usb.c)

The base driver comes from slop (patches 0072-0077, 0081, 0119: DWC3 at 0x0a600000, ep0, VBUS override, CDC-ECM,
live log). Our patches: 0210 (UDP command server), 0212 (settime), 0282 (bus reset drops the data endpoints),
0360 (panic mode, README-panic.md), 0361 (throughput, this file), 0366 (reconnect after unplug or a Type-C
re-attach, this file). Host side: docs/usb-network.md.

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
