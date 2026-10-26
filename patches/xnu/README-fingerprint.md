# Fingerprint patches 0350-0353 (Goodix optical G7 under the display)

Facts, plan and iOS design: `docs/fingerprint-plan.md`. All boot-args default off.

## 0350 stage A: `bsd/dev/negroni_fp.c` (`negronifp=1|2`)

| Boot-arg | Default | Meaning |
|---|---|---|
| `negronifp` | 0 | 1 = steps 1-8 (clocks, SE probe, LDO, reset, chip-ID frames); 2 = also the IRQ poll (step 9) |
| `negronifp_delay` | 15 | seconds after boot before step 1 (the USB console is up at ~13 s) |
| `negronifp_hz` | 4800000 | SPI clock; the SE runs on XO 19.2 MHz, divider = ceil(19.2 MHz / hz) |
| `negronifp_mode` | 0 | SPI mode 0-3 (bit 1 CPOL, bit 0 CPHA) |
| `negronifp_ldo` | 1 | 0 = no RPMh vote for `ldoc11` (pm8350c_l11 3.0 V); with 1 the power-down sends the off vote (`negroni_rpmh_vreg_disable`) |
| `negronifp_keep` | 0 | 1 = leave the sensor powered and the SE clocks on after the steps |
| `negronifp_poll` | 60 | seconds of IRQ polling with `negronifp=2` |

Expected log (USB console, `make usblog`):

```
NEGRONI FP: start (negronifp=2, Goodix optical G7 [DT], QUP1 SE2 0xa88000, TLMM 36-42)
NEGRONI FP: step 1 map (QUP1 wrapper, SE, GCC pages, TLMM 36-43)
NEGRONI FP: pins at start: irq40 ctl 0x... in 0, rst41 ctl ... , id42 ..., spi36-39 ctl ...
NEGRONI FP: step 2 GCC: QUP1 AHB/core votes, s2 RCG to XO 19.2 MHz, s2 clock
NEGRONI FP: APCS vote 0x..., CBCR m_ahb ... s2 ...
NEGRONI FP: s2 RCG before: CMD 0x... CFG 0x...
NEGRONI FP: step 3 SE probe (first read of 0xac0004 / 0xa88000: may fault if the XPU/TEE owns the SE): QUP HW version, firmware protocol, FIFO
NEGRONI FP: QUP1 hw 3.x.y, SE fw rev 0x..., (protocol 1: SPI), IF_DISABLE 0x0, HW_PARAM0 ...: tx fifo 16 words x 32 bits
NEGRONI FP: step 4 SE init: FIFO mode, 8-bit packing, SPI mode and clock
NEGRONI FP: SPI 4800000 Hz (div 4 of 19.2 MHz), mode 0
NEGRONI FP: step 5 pins: reset low, irq input pull-down, id input pull-up, SPI pins to qup10
NEGRONI FP: fp id (TLMM 42, pull-up) = 1 (DT goodix_optical_G7: fp-id 1)
NEGRONI FP: step 6 power: RPMh ldoc11 (pm8350c_l11) 3000 mV
NEGRONI RPMH: ... / NEGRONI FP: ldoc11 vote rc 0
NEGRONI FP: step 7 reset: 41 low 5 ms, high, 20 ms
NEGRONI FP: irq40 before reset 0, after reset 1 (rose within 20 ms: the chip answers the reset)
NEGRONI FP: step 8 chip ID over SPI (frames [I]: Goodix F1 read of reg 0x0000; then 8 clocked bytes)
NEGRONI FP: F1 00 00 -> (8 bytes): xx xx xx xx xx xx xx xx
NEGRONI FP: chip answered (bytes differ from 00/ff): candidate chip id xxxx
NEGRONI FP: step 9 IRQ poll (TLMM 40): touch the sensor area
NEGRONI FP: irq 0 -> 1 at 1234 ms
NEGRONI FP: irq poll done (N changes)
NEGRONI FP: power down (done): reset low, pins to gpio, SE clock votes back, ldoc11 off
NEGRONI FP: ldoc11 off vote rc 0
NEGRONI FP: end
```

Stop lines (each one ends the thread after the reverse power-down):
`stop: SE2 firmware is not SPI` (protocol 0 = no firmware loaded on this SE, or another protocol:
the qupfw/TZ configuration decides; then a GPIO bit-bang SPI is the next option),
`stop: FIFO interface disabled on this SE (GPI DMA only)` (as QUP0 SE4 for the touch),
`clock X does not come on`, `s2 RCG update does not complete`, `tx/rx did not finish ... cancel`.
A chip-ID answer of all `00` or all `ff` means MISO is idle: wrong SE, wrong mode, or the sensor
needs a different frame (the real protocol is in the TEE application; the frames are a guess).
The expected chip ID value is not known from any source we have.

## 0351 stage B: NegroniFramebuffer.cpp (`negronifp_hl=1|2`)

| Boot-arg | Default | Meaning |
|---|---|---|
| `negronifp_hl` | 0 | 1 = disc after each copy + panel HBM-on DCS set once; 2 = disc only |
| `negronifp_hl_x`, `_y` | 540, 2080 | disc centre in panel pixels (1080x2412) [I placeholders: the stock value is a runtime property, not in the DT or the images] |
| `negronifp_hl_r` | 95 | disc radius in panel pixels (4..400) |

Log: `NEGRONI FP HL: highlight on (mode 1): disc at 540,2080 radius 95 panel px, panel HBM once`,
then `NEGRONI FP HL: panel HBM on: ok (11 packets)` (or `failed (N packets)` when a DCS write
failed: 0250's `negroni_dsi_dcs_write` returns non-zero after three DSI failures). The disc is
white; in mode 1 the whole panel is in HBM (DCS 0x53 = 0xE0, DBV 0xEFF) until reboot or display sleep
(0258's off sequence; no HBM-off path is called). The HBM-off set is in the code (`negroni_fp_hbm(false)`)
for later stages. With `negronifp_hl` > 0 every GPU frame waits on its copy fence in `presentFinish`
(like `negronibadge=1`), so the disc is on every frame. Frames the display engine shows directly
(zero-copy) carry no disc.

## 0352 stage C part 1: MCU frames (`negronifp=3`)

| Boot-arg | Default | Meaning |
|---|---|---|
| `negronifp` | 0 | 3 = steps 1-8, 10 (MCU frames), 9 (IRQ poll) |
| `negronifp_wrap` | 2 | 0 = plain SPI frames only, 1 = the 5120-SPI transport (`CC F2 seq` write, `BB F1 00 00` read) only, 2 = both |
| `negronifp_irqwait` | 100 | ms to watch the IRQ pin after each frame |

0352 also changes step 6: the ldoc11 vote retries `EBUSY` 40 x 50 ms (the RPMh voter is shared with Wi-Fi/BT/camera)
and a failed vote stops the thread (`stop: the ldoc11 vote failed (errno N): the sensor is unpowered`).

Expected log:

```
NEGRONI FP: step 10 MCU frames [I]: public Goodix MCU message pack (A0 len sum | cmd len payload 0xAA-sum), plain SPI and the 5120-SPI transport (CC F2 seq / BB F1 00 00)
NEGRONI FP: plain nop (00 x4, no checksum) tx (12 bytes): a0 08 00 a8 00 05 00 00 00 00 00 88
NEGRONI FP: plain nop ... rx (16 bytes): xx ...
NEGRONI FP: plain query mcu state (AE 55) tx (9 bytes): a0 05 00 a5 ae 02 00 55 a5
NEGRONI FP: irq40 changed 3 ms after the frame (now 1): the MCU reacts            <- proof 1
NEGRONI FP: plain query mcu state (AE 55) rx (16 bytes): ...
NEGRONI FP: plain query mcu state (AE 55): VALID message pack at byte 0: cmd b0 payload 2 bytes (ACK)   <- proof 2
... firmware version (A8 00 00), read otp (A6 00 00), read sensor reg 0 (82 00 00 00 04), then the same with "wrap"
NEGRONI FP: MCU probe result: VALID message pack from the chip: the G7 MCU speaks the public Goodix MCU protocol (plain SPI)
```
Other verdicts: `bytes on MISO but no valid message pack: the chip answers, the framing differs`,
`MISO idle: no answer to the public frames (wrong SE, mode, clock, or a different protocol)`.
Frame check (goodix.py): `AE 55` -> protocol `ae 02 00 55` + checksum `(0xaa - (0xae+0x02+0x00+0x55)) & 0xff = 0xa5`;
pack `a0 05 00` + `0xa5`.

## 0353 stage C part 2: one capture (`negronifp=4`)

| Boot-arg | Default | Meaning |
|---|---|---|
| `negronifp` | 0 | 4 = 3 + step 11 (capture) |
| `negronifp_img` | 183456 | capture buffer bytes (364 x 252 x 2), 64 .. 1 MiB |
| `negronifb_te` | 0 | 1 makes `negroni_fb_te_wait` count real TE frames; 0 = 17 ms timed wait |

Expected log:

```
NEGRONI FP: step 11 capture [I]: panel HBM on, 2 TE frames, MCU get image (20 01 00), HBM off, bounded read into the buffer; /dev/negroni-fp
NEGRONI FP: capture: panel HBM on rc 0
NEGRONI FP: capture: TE wait 2 (frames counted)              (or: -1 (TE counter off (negronifb_te=0): 17 ms timed))
NEGRONI FP: plain get image tx (10 bytes): a0 06 00 a6 20 03 00 01 00 86
NEGRONI FP: capture: irq40 changed (level 1)
NEGRONI FP: capture: panel HBM off rc 0            (HBM is off right after the frame + IRQ wait (<= 100 ms): the exposure is at the frame, the readout needs no light)
NEGRONI FP: capture rx (16 bytes): ...
NEGRONI FP: capture: 183456 bytes read of 183456 (00: N, ff: N, 200 distinct values)
NEGRONI FP: capture: VARIED DATA: pull /dev/negroni-fp and run scripts/fp/raw-to-png.py
```
`idle bytes only: the public get-image frame is not the G7 readout command [I]` is the negative result. The
read stops early after 16 idle 64-byte pieces when no piece looked like data (1 KiB), so a negative run is fast.
Pull: `scripts/net/ssh-phone.sh scp root@phone:/dev/negroni-fp out/fp/capture.bin` (or `cat /dev/negroni-fp >
/tmp/c.bin` on the phone, as root: the node is 0600), then `scripts/fp/raw-to-png.py out/fp/capture.bin`
(`--self-test` checks the converter). The node exists with `negronifp` >= 1 (header only, len 0, before a capture).
The bulk read sends the `BB F1 00 00` read header once under one chip select; the public 5120 driver re-sends it per
256-byte read (protocol.py:182) [difference noted, not tested].

## Test image

`out/ios16-fp`: config args + `negronifp=2 negronifp_hl=1 negronipanic=30 negronipanicreason=2` (stages A/B).
`out/ios16-fp3`: config args + `negronifp=3 negronifp_hl=2 negronipanic=30 negronipanicreason=2` (stage C probe; the disc
without HBM; `scripts/fp/build-test-image.sh fp3`). Capture image: `scripts/fp/build-test-image.sh fp4 "negronifp=4 negronifp_hl=2 negronifb_te=1 negronipanic=30 negronipanicreason=2"`.
Flash with `IOS16_OUT=out/ios16-fp scripts/flash/ios16.sh boot --yes` (owner approval; boot_a only).
