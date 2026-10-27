# GNSS through the modem: patch 0397 (2026-10-27, GNSS kernel agent; UNTESTED ON HARDWARE)

Owner: "location services/gps isn't working, we need that fixed". The NE2211 has no GNSS chip; the GNSS engine is in
the modem (MPSS). Patch `0397-negroni-gnss.patch` starts the modem from XNU, serves what it needs from the HLOS
(read-only), runs a QMI LOC client and gives the fixes to userland. Plan and background: `docs/location-plan.md`
sections 2, 3C and 7. Marks: [V] seen in source/DT/firmware/a test, [I] inference, [U] unknown.

## Files

| File | What |
|---|---|
| `bsd/dev/negroni_gnss.c` (new) | the feature: steps 0-13, GLINK/QRTR, RMTFS/TFTP/servreg servers, DMS/LOC clients, run loop, `/dev/negroni_gnss`, `kern.negroni_gnss` |
| `bsd/dev/negroni_gnss_core.h` (new) | pure parts (FAT16 reader, IEEE-754 without FPU, QMI TLV lookup, TFTP path map); host-tested |
| `bsd/dev/negroni_ufs.c` | `negroni_ufs_part_open/read`: READ-ONLY access to `modem_a`, `modemst1`, `modemst2`, `fsg`, `fsc` on any LUN (allowlist); the init call |
| `bsd/dev/negroni_rpmh.c` | `negroni_rpmh_arc_vote` also takes `mss.lvl` (never `cx.lvl`) |
| `bsd/dev/negroni_spmi.c` | `negroni_qmp_lock/unlock`: one lock for the AOSS QMP mailbox (charger debug vote + GNSS) |
| `bsd/dev/negroni_slpi.c` | `negroni_slpi_phase()` (the GNSS thread waits for the SLPI start steps, as the SLPI waits for the ADSP) |
| `bsd/conf/files` | `negroni_gnss.c` |
| `patches/xnu/tests/gnss-core-test.c`, `scripts/kernel/test-gnss-core.sh` | host test of `negroni_gnss_core.h` (header taken from the patch) |

Ported code: the RMTFS, TFTP and service-registry servers and the QRTR name-service part follow HakiOS
`xnu/files/bsd/dev/hakios.mpss.c` (APSL 2.0, Copyright (c) 2025-2026 the HakiOS authors; reference tree
`out/src/hackios-next`, commit 88513176b1e96ecf0b764cd62c6f4e6ac71345e3), same licence as XNU. QMI LOC/DMS numbers:
libqmi `qmi-service-loc.json`, `qmi-service-dms.json`, `qmi-flags64-loc.h`, `qmi-enums-loc.h` at
gitlab.freedesktop.org/mobile-broadband/libqmi 3454c2c619d516fd46a08fe16c6eebdee061857d (copies in `out/src/libqmi/`).
PAS/SMEM/SMP2P/GLINK: our `negroni_slpi.c` (0376) with the modem's numbers.

## Rules it follows

- On by default. `negronignss=0` is the only boot-arg (kill switch). No probe mode.
- Self-check = the steps. Any failure: the modem is stopped (SMP2P stop + up to 5 s for STOP-ACK), PAS shutdown
  (asked again every 100 ms, up to 50 times, as Linux does for `decrypt_shutdown`), RMTFS buffer given back only
  after TrustZone took the modem down (else it stays assigned: outside XNU's RAM, not used again), AOP `modem off`, `mss.lvl` vote dropped, then ONE line `NEGRONI GNSS: off: <reason>`.
- After `on`: a modem crash (SMP2P `slave-kernel` FATAL), a dead GLINK, the LOC service going away, or 3 lost liveness
  answers (one LOC request per 30 s) -> the same stop and one `off:` line. No restart in that boot.
- Never writes a partition: the UFS path for other LUNs has only READ(10); the LUN of a read is set per command
  (`ufs_read_lun`), every write uses `su.lun` (the root LUN 0); the panic path clears `ufs_read_lun`. The modem's
  RMTFS and TFTP writes go into kernel RAM (lost at reboot).

## Values

| What | Value | Source |
|---|---|---|
| PAS id, crash reason item | 4, 421 | Linux `sm8450_mpss_resource` [V] |
| carveout | 0x8bc00000 + 0x13200000 | `mpss_region@8bc00000` [V]; modem.mdt load span 0x8bc00000..0x9ee00000, relocatable [V] |
| SMEM host, SMP2P items | 1; in 435, out 428 (`master-kernel`) | `qcom,smp2p-modem` `qcom,smem = <0x1b3 0x1ac>` [V] |
| IPCC | client 2: signal 2 SMP2P, signal 0 GLINK | DT `mboxes` [V] |
| GLINK | edge mpss, items 478/479/480 in partition 0/1, channel IPCRTR | DT glink-edge [V] |
| rails | `mss.lvl` 384 until handover | DT `mx-supply` = `rpmh-regulator-msslvl` [V]; `cx.lvl` not voted (shared with USB/UFS) |
| AOP | `{class: image, res: load_state, name: modem, val: on/off}` | Linux `load_state = "modem"` [V] |
| firmware | UFS LUN 4 `modem_a` (FAT16, 4096-byte sectors, 16 KiB clusters, long names): `image/modem.mdt` + `modem.b00..b31` (27 segment files, 107 MiB), `image/*.jsn`, `image/modem_pr/...` for TFTP | backup GPT `gpt-sde-head.bin` [V], `out/firmware/modem/modem.img` [V] |
| RMTFS backing | UFS LUN 5 `modemst1` 3 MiB, `modemst2` 3 MiB, `fsg` 3 MiB, `fsc` 128 KiB, read into RAM | backup GPT `gpt-sdf-head.bin` [V] |
| RMTFS buffer | 0xa8000000 + 0x280000, assigned HLOS + MSS_MSA (VMID 3 + 15, RW) | size from `qcom,rmtfs_sharedmem@0` [V]; no `qcom,vm-nav-path` on waipio [V]; address = Mu map "Kernel" region [I] |
| QMI | RMTFS 14 (v1 i0), TFTP 4096 (1), servreg locator 64 (257); clients DMS 2, LOC 16 | HakiOS, libqmi [V] |

## Steps and expected log lines (in order)

Times are [I]. `N` = a number. One `on:` or one `off:` line ends the start.

```
NEGRONI GNSS: starting in 20 s (modem PAS 4, carveout 0x8bc00000 + 0x13200000, RMTFS buffer 0xa8000000; negronignss=0 turns it off)
  (20 s later)
NEGRONI GNSS: step 0 (wait for the DSP threads) ok in 0 ms
NEGRONI GNSS: 1 SCM PAS is supported (modem) -> 0, answer 0x... (N ms)
NEGRONI GNSS: 1 SMEM partition 0/1 at 0x80..., 0x... bytes; no modem SMP2P item 435 (the modem has not run)
NEGRONI GNSS: step 1 (SMEM survey) ok in N ms
NEGRONI UFS: partition "modem_a" (read only): LUN 4, first block 0x1206, 307200 KiB
NEGRONI GNSS: 2 modem_a: FAT16, 4096-byte sectors, 16 KiB clusters, 19193 clusters
NEGRONI GNSS: 2 modem.mdt: 32 program headers, load 0x8bc00000..0x9ee00000 (313344 KiB), 109321 KiB of segments, relocatable
NEGRONI GNSS: 2 service registry: N services from the image/*.jsn files
NEGRONI GNSS: step 2 (firmware) ok in N ms
NEGRONI UFS: partition "modemst1" (read only): LUN 5, first block 0x2820, 3072 KiB   (also modemst2, fsc, fsg)
NEGRONI GNSS: 3 modemst1 3072 KiB, modemst2 3072 KiB, fsc 128 KiB, fsg 3072 KiB in kernel memory (writes stay there)
NEGRONI GNSS: step 3 (modem file systems) ok in N ms
NEGRONI GNSS: 4 RMTFS buffer 0xa8000000 + 0x280000 mapped, pattern ok, zeroed
NEGRONI GNSS: step 4 (RMTFS buffer) ok in N ms
NEGRONI RPMH: ARC mss.lvl level 384 -> hlvl N
NEGRONI GNSS: step 5 (rails) ok in N ms
NEGRONI GNSS: step 6 (AOP QMP) ok in N ms
NEGRONI GNSS: 7 SCM PAS init image (modem) -> 0, answer 0 (N ms)
NEGRONI GNSS: 7 SCM PAS mem setup (modem) -> 0, answer 0 (N ms)
NEGRONI GNSS: step 7 (PAS init) ok in N ms
NEGRONI GNSS: 8 109321 KiB of segments written at 0x8bc00000 and read back OK
NEGRONI GNSS: step 8 (load) ok in N ms               (expect a few seconds)
NEGRONI GNSS: step 9 (SMP2P) ok in N ms
NEGRONI GNSS: 10 SCM assign the RMTFS buffer to HLOS+MSS -> 0, answer 0 (N ms)
NEGRONI GNSS: 10 SCM PAS auth and reset (modem) -> 0, answer 0 (N ms)
NEGRONI GNSS: 10 +N ms: slave-kernel = 0x6 READY HANDOVER     (HakiOS SM7325: 0x6 after 63 ms)
NEGRONI GNSS: mss.lvl vote dropped (handover)
NEGRONI GNSS: 10 THE MODEM IS UP after N ms
NEGRONI GNSS: step 10 (start) ok in N ms
NEGRONI GNSS: 11 GLINK: the modem opens "DS" (rcid N): not ours, left unanswered        (maybe; also others)
NEGRONI GNSS: 11 GLINK UP after N ms: IPCRTR open (lcid 1 rcid N), 8 intents
NEGRONI GNSS: step 11 (GLINK) ok in N ms
NEGRONI GNSS: 12 QRTR: HELLO from node 0: answered, our 3 servers announced
NEGRONI GNSS: 12 QRTR: service 43 (SSCTL) version 1 instance 18 at 0:0x...
NEGRONI GNSS: 12 QRTR: service 66 (servreg notifier) ...
NEGRONI GNSS: RMTFS: the modem opens /boot/modem_fs1 (modemst1, 3072 KiB)        (also fs2, fsc, fsg)
NEGRONI GNSS: servreg: the modem asks where "tms/servreg" is: 1 domain(s)
NEGRONI GNSS: TFTP: the modem writes (kept in RAM) "/readwrite/server_check.txt" (...)
NEGRONI GNSS: TFTP: the modem reads "/readonly/firmware/image/modem_pr/..." (N bytes, block N, window N)
NEGRONI GNSS: 12 QRTR: service 2 (DMS) version 1 instance 0 at 0:0x...
NEGRONI GNSS: DMS: operating mode 1 (0 online, 1 low power, ...)        [U] which mode
NEGRONI GNSS: 12 QRTR: service 16 (LOC) version 2 instance 0 at 0:0x...
NEGRONI GNSS: 12 LOC service up after N ms (N services; RMTFS N reads N writes; TFTP N; servreg N)   (HakiOS: ~30 s)
NEGRONI GNSS: step 12 (QRTR services) ok in N ms
NEGRONI GNSS: 13 LOC: engine lock = 1 (1 none, 2 MI, 3 MT, 4 all)
NEGRONI GNSS: 13 LOC: operation mode standalone: OK
NEGRONI GNSS: step 13 (LOC) ok in N ms
NEGRONI GNSS: on: modem up (PAS 4), LOC service at 0:0x..., /dev/negroni_gnss; a session runs while it is read
  (when negroni-locd or `cat /dev/negroni_gnss` reads)
NEGRONI GNSS: LOC: session started (a reader of /dev/negroni_gnss)
NEGRONI GNSS: FIRST fix 1: 12.9716000 77.5946000, hacc 25 m, 7 satellites, 41 s after the session start
NEGRONI GNSS: session: N reports, last fix age N ms; RMTFS N writes (RAM), TFTP N     (every 5 min)
NEGRONI GNSS: LOC: session stopped (no reader for 30 s)
```

Off lines (one of them, then the stop lines `stop: slave-kernel = ...`, `mss.lvl vote dropped (modem stopped)` when the
modem had been started):

| Line | Meaning |
|---|---|
| `off: negronignss=0` | kill switch |
| `off: step 0 (...): the ADSP/SLPI start threads still run after 600 s` | another DSP start hangs |
| `off: step 1 (...): the modem's SMP2P item 435 is there ...` | the modem ran since the reset (warm reboot from Android?) |
| `off: step 2 (...): no partition modem_a ...` / `modem_a: ...` / `modem.bNN missing ...` | firmware |
| `off: step 3 (...): partition modemst1: not found ...` | RMTFS backing |
| `off: step 4 (...): the RMTFS buffer 0xa8000000 does not hold a pattern` | the region is not plain RAM for us |
| `off: step 5 (...): RPMh mss.lvl level 384 vote failed` | RPMh |
| `off: step 7 (...): TrustZone refuses the modem metadata (...)` | PAS auth of the header |
| `off: step 8 (...): modem.bNN does not read back ...` | carveout write |
| `off: step 10 (...): TrustZone does not assign the RMTFS buffer ...` | SCM/hypervisor memory assign |
| `off: step 10 (...): no READY from the modem after 10000 ms[: last words]` | modem did not boot |
| `off: step 11 (...): GLINK: not up after 15000 ms (...)` | GLINK |
| `off: step 12 (...): no LOC service (16) after 180 s (N services; RMTFS ...)` | the modem waits for something we do not serve |
| `off: step 13 (...): LOC: register events: no answer in 5 s` | LOC does not answer |
| `off: the modem crashed (SMP2P FATAL)[: last words]; modem stopped` | crash after on |
| `off: the modem stopped answering LOC (3 requests lost); modem stopped` | hang after on (watchdog bite) |

## Userland interface

`/dev/negroni_gnss` (root:wheel 0440) and `sysctl kern.negroni_gnss` give the same text; `pread(fd, buf, 1024, 0)`:

```
state=on session=1 engine=on reports=57 reason=ok
fix=12 final=1 utc_ms=1793124000123 lat=12.9716000 lon=77.5946000 alt_m=920.50 ealt_m=834.10 hacc_m=7.50 vacc_m=12.00 speed_mps=0.10 course_deg=- sats=9 age_ms=420
locd=12.9716000 77.5946000 7.50 920.50 12.00 0.10 -1
```

- Line 1 always. `state` = `starting|on|off`, `reason` = `ok` or the off reason.
- Line 2 after the first fix (stays with `age_ms` growing). `final=0` = an intermediate fix (session status
  IN_PROGRESS). `-` = the report did not carry the value. `alt_m` = above sea level (falls back to ellipsoid).
- Line 3 only while the fix is younger than 3 s: negroni-locd's text form (`LAT LON HACC ALT VACC SPEED COURSE`,
  `-1` = unknown, `VACC -1` = no altitude; docs/location-plan.md 6.4). Take it once per new `fix=` number.
- Each read of the device is demand: a LOC session (periodic, 1 s, standalone, intermediate reports on) runs while
  the device was read in the last 30 s, and stops after that (GNSS off, the modem idles in low power). The sysctl
  is not demand.

## USB, Wi-Fi and boot safety

- [V notes 48/55/58] The USB drop after the ADSP start is the ADSP charger PD (Type-C role flip by its TCPM, PHY
  rails). The modem image has no USB/Type-C role; this patch writes no GPIO, clock, PMIC, PHY or USB register.
  The only RPMh vote is `mss.lvl` (modem rail). `cx.lvl` is not voted: an APPS cx vote from our DRV replaces the
  UEFI vote (README-camera "MMCX"), and USB/UFS run on CX.
- UFS: the firmware read (107 MiB) and the partition reads are 1 MiB READ(10) commands under the UFS lock, after a
  20 s settle; root I/O interleaves. No write path to LUNs 4/5 exists.
- SMEM partition 0/1, IPCC client 2, carveout 0x8bc00000: modem only. QMP: shared lock with negroni_spmi.c; the ADSP
  (0240) and SLPI (0376) threads are waited for (they take no lock). TCSR mutex 3: same wait.
- Wi-Fi (WCN6855 over PCIe/MHI) has its own QRTR; nothing shared.
- Boot: everything is on a kernel thread; no step blocks the boot. A failure before the start leaves the modem in
  reset; after the start it is stopped and shut down by TrustZone.

## Risks for the first RAM boot (`fastboot boot`)

1. [U] RMTFS buffer at 0xa8000000: HakiOS (SM7325) saw a phone RESET at the first sector write with some buffer
   places and with only HLOS+MSS; it worked with HLOS+MSS+NAV (their DT has `qcom,vm-nav-path`, ours does not [V]).
   A reset here = the phone reboots into boot_a (USB back after the reboot). If it happens, the test answer is
   `negronignss=0`, then another region or adding NAV (VMID 0x2b) is the next step.
2. [U] SCM memory assign under the hypervisor (Gunyah) for a region outside XNU's RAM: refused -> clean off at step 10.
3. [U] Without the IPA the modem may stall or crash later; HakiOS saw no crash until DMS ONLINE (we never send
   online). A crash = clean off line.
4. [I] A modem watchdog bite gives no SMP2P FATAL; the liveness check catches it after <= 90 s.
5. [U] GNSS in the modem's default mode: if LOC answers PHONE_OFFLINE, the code asks DMS for low power mode once.
6. [I] Power: the modem in low power idles; the GNSS session runs only while the device is read.
7. [U] Boot-time cost: ~110 MiB read from UFS + 306 MiB carveout zero + read back: a few seconds of one CPU, 20 s
   after the start of the thread.
8. Cold start without XTRA/assistance: [I] 30 s to several minutes outdoors with open sky.

## Test plan

1. Host: `scripts/kernel/test-gnss-core.sh` (PASS + FAT PASS against `out/firmware/modem/modem.img`).
2. Build (main session): one kernel with 0397; RAM boot (`fastboot boot`), USB log (`make usblog`).
3. Read the lines above in order. Stop at the first `off:` line; it names the step.
4. On the phone: `cat /dev/negroni_gnss` once per second outdoors (e.g. `while :; do cat /dev/negroni_gnss; sleep 1;
   done` over SSH); expect `session=1`, then `fix=` within minutes, `locd=` with each fresh fix.
5. Crash watch check (only if the owner asks): none needed; a natural crash prints `off: the modem crashed`.
6. USB must stay up through all of it (watch the Mac side of `make usblog`).

## Open unknowns

- Which DMS mode the modem boots in; whether LOC works in it without ONLINE.
- Whether the modem needs the `ipa` SMP2P entry or the IPA QMI service even in low power mode.
- Whether the modem reads more TFTP files than `modem_pr/...` (e.g. `/readwrite/...` reads before writes: answered
  "file not found", as tqftpserv does without the file).
- The NMEA/SV-info indications are not registered (not needed for `CLLocation`).
