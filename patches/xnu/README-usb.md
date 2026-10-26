# USB Ethernet gadget (bsd/dev/negroni_usb.c)

The base driver comes from slop (patches 0072-0077, 0081, 0119: DWC3 at 0x0a600000, ep0, VBUS override, CDC-ECM,
live log). Our patches: 0210 (UDP command server), 0212 (settime), 0282 (bus reset drops the data endpoints),
0360 (panic mode, README-panic.md), 0361 (throughput, this file). Host side: docs/usb-network.md.

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
