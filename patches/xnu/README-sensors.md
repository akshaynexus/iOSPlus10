# Sensors: SLPI start (patch 0376) and what phase 2 needs

Plan: docs/sensors-plan.md (all motion/light sensors sit on SLPI buses; the stock path is the only path
today). Marks: **[V]** seen in source, DT, firmware or a build. **[I]** inference. **[U]** unknown, a test
must decide. Nothing in this file ran on the phone.

## 0376 negroni-slpi-start (phase 1, default off)

New file `bsd/dev/negroni_slpi.c` (own kernel thread, lines `NEGRONI SLPI: <step> ...`). Hooks:
`negroni_ufs.c` calls `negroni_slpi_init()` right after `negroni_adsp_init()`; `negroni_adsp.c` exports
`negroni_adsp_phase()` (0 not asked, 1 thread runs, 2 thread done; release/acquire) and
`negroni_adsp_rails_held()`. The ADSP code path itself is unchanged except `rails_on = false` after the
failure-path unvote (review F3). `negroni_spmi.c`: the QDSS debug-arbiter QMP vote is also skipped with
`negronislpi` set (review F2: no second QMP sender at the same time).

The steps are those of 0240/0242/0248 (ADSP, proven: `THE ADSP IS UP`, GLINK step 9) with the SLPI values.
The code is a copy, not a shared descriptor: the proven ADSP file stays as it is.

| Item | SLPI value | Source |
|---|---|---|
| PAS id | 12 | [V] Linux `qcom_q6v5_pas.c` `sdm845_slpi_resource_init` (`.pas_id = 12`), used for `qcom,sm8450-slpi-pas` |
| Firmware | `slpi.mdt` + `slpi.bNN` (24 program headers, b22 BSS, hash segment b23) | [V] modem FAT `image/`, `scripts/sensors/extract-slpi-fw.sh` |
| Crash reason item | 424 | [V] `.crash_reason_smem = 424` |
| Minidump id | none | [V] the resource has no `.minidump_id` |
| AOP load_state | `slpi` | [V] `.load_state = "slpi"` |
| Proxy votes | lcx, lmx (level 384, as the ADSP) | [V] `.proxy_pd_names`; DT cx/mx supplies = the ADSP's (0x3f/0x40) |
| Carveout | 0x87f00000 + 0x1a00000 (26 MiB) | [V] live.dts `slpi_region@87F00000`; the image spans 0x88000000..0x89a00000 = 0x1a00000, relocatable |
| SMEM partition | hosts 0/3 | [V] `qcom,remote-pid = <3>` (smp2p-dsps, glink-edge) |
| SMP2P | in 481, out 430; entries `master-kernel` (bit 0 stop) and `sleepstate` (bit 12 awake); in: `slave-kernel` (fatal 0, ready 1, handover 2, stop-ack 3), `sleepstate_see` | [V] `qcom,smem = <0x1e1 0x1ae>`, interrupts-extended of remoteproc-slpi, `smp2p_sleepstate.c` PROC_AWAKE_ID 12 |
| IPCC | client 4; signal 2 = SMP2P, signal 0 = GLINK | [V] `mboxes = <&ipcc 4 2>` / `<&ipcc 4 0>` |
| GLINK | edge `dsps`, items 478/479/480 in the 0/3 partition; channels `IPCRTR` (net-id 2), `fastrpcglink-apps-dsp` | [V] live.dts glink-edge |
| SEE client service | QMI 400 (0x190) | [V] `qcom,no-wake-svc = <0x190>` |

### Boot-args

| Boot-arg | Default | Effect |
|---|---|---|
| `negronislpi=N` | 0 | 0 off (nothing runs, no line). 1: steps 0..8 (PAS start). 2: + step 9 (GLINK, listen only). 3: + step 10 (IPCRTR ours, QRTR) |
| `negronislpi_step=N` | level | stop after step N (only lower than the level) |
| `negronislpi_wait=S` | 10 | wait for ready after auth_and_reset (1..60) |
| `negronislpi_listen=S` | 15 | GLINK (level 2) / QRTR (level 3) log window (1..120) |
| `negronislpi_unvote=0` | 1 | keep the lcx/lmx votes after handover |
| `negronislpi_sleepstate=0` | 1 | no `sleepstate` entry in item 430 |
| `negronislpi_adspwait=S` | 240 | longest wait for the ADSP thread (step 0) |
| `negronislpi_pause=MS` | 0 | sleep before each write step (see the last line in the USB log) |

### Steps

| Step | Does | Writes |
|---|---|---|
| 0 | waits for the ADSP thread to end (`negroni_adsp_phase() == 2`); no wait with `negroniadsp=0` | none |
| 1 | SMEM: partition 0/3; item 481 there = the SLPI ran since the reset: stop (no second start); items 430/478-480; PAS is_supported(12) logged only (0241) | none |
| 2 | ADSP area entry `slpi.pak`, its table (bounds of every entry inside the pack, pack inside the area, pack <= 12 MiB), `slpi.mdt` (ELF32, <= 48 headers), SHA-256 of every segment file, the span fits the carveout | none |
| 3 | RPMh lcx.lvl/lmx.lvl 384 | RPMh |
| 4 | AOP QMP `{class: image, res: load_state, name: slpi, val: on}` (waits up to 1 s for an empty mailbox) | QMP mailbox, IPCC 0/0 |
| 5 | PAS init image (12, ELF header + hash segment), PAS mem setup (12, 0x87f00000, 0x1a00000) | TrustZone |
| 6 | zero the carveout, write each PT_LOAD at p_paddr - min, read back (SHA-256); each write offset is checked against the carveout again | carveout only |
| 7 | our SMP2P item 430 (TCSR mutex 3), entries `master-kernel` = 0, `sleepstate` = 0x1000; IPCC 4/2 | SMEM 0/3 |
| 8 | PAS auth and reset (12); poll `slave-kernel` for ready/handover/fatal; handover drops the votes unless the ADSP still holds them | TrustZone, RPMh |
| 9 | GLINK items 478 (32 bytes) + 479 (16 KiB) in 0/3, VERSION; level 2: every OPEN of the SLPI is logged, none is answered | SMEM 0/3, IPCC 4/0 |
| 10 | level 3: OPEN_ACK + our OPEN for `IPCRTR` only, 8 RX intents, QRTR HELLO; logs HELLO, NEW_SERVER (service, version, instance, node, port), DEL_SERVER, BYE, NEW_LOOKUP, DATA | SMEM 0/3 |

After the steps, with a running SLPI, the thread stays as the crash watch (0248): every 200 ms `slave-kernel`
for FATAL, and GLINK poll (so the SLPI never finds our side dead). FATAL: last words (item 424), `stop` bit +
up to 5 s for STOP-ACK, PAS shutdown; no restart in this boot. A failure after step 5 and before ready: PAS
shutdown (12) and the votes dropped (unless the ADSP holds them).

Safety:

- [V code] Writes go only to: the SLPI carveout (step 6), SMEM items 430/478/479 in the 0/3 partition (TCSR
  mutex 3), the QMP mailbox, IPCC doorbells (clients 0 and 4), RPMh lcx/lmx. Nothing on the ADSP edge, nothing
  in the ADSP carveout, no USB, no charger, no PMIC write.
- [V code] The ADSP and the SLPI share three things with no lock: the AOSS QMP mailbox, TCSR hardware mutex 3
  (the mutex is per processor, so two APPS threads both "own" it), the APPS RPMh vote on lcx/lmx. Step 0 runs
  the SLPI thread only after the ADSP thread ends, and the SLPI keeps the lcx/lmx vote when the ADSP holds it.
- [V code] SLPI items (430, 478-481) are looked up and allocated only in the 0/3 partition (no global
  fallback, as Linux `qcom_smem_get(host)`); only the crash reason 424 may come from the global partition.
  The SMEM item walk checks padding and item ends against the free pointers (DSP-written headers).
  GLINK messages longer than the RX FIFO stop GLINK with a line (no silent hang).
- [I] The SLPI does not own the Type-C port or the charger (the ADSP charger PD does, README-usb.md 0374).
  So the SLPI start does not touch the USB link. Test it alone first (`negroniadsp=0`) to prove that.
- [U] Whether the SLPI firmware votes PMIC rails of its own (sensor LDOs) through its RSC. That is its job and
  does not touch USB rails [I].

Review (Opus, medium): ACCEPT WITH FIXES; all of F1-F8 applied (F1 partition-only items, F2 SPMI QDSS QMP
guard, F3 ADSP `rails_on`, F4 oversize GLINK messages, F5 QRTR handler set before the IPCRTR open, F6
release/acquire on `adsp_phase`, F7 SMEM header bounds, F8 intents left for RX_INTENT_REQ). Not done (F9,
info): the PAS metadata page is not freed on failure; no AOP `load_state slpi off` after a failed start (Linux
sends it); VERSION_ACK > 1 accepted as the ADSP code does; `e_phentsize` assumed 32.

### Firmware on the phone

`scripts/sensors/extract-slpi-fw.sh` (needs `out/firmware/modem/modem.img`) writes `out/firmware/slpi/` and
`out/firmware/adsp/slpi.pak` (26 files, 9662464 bytes [V]). `scripts/fw/build-areas.sh` then puts `slpi.pak`
into the ADSP area (`mkadsparea.py`: 45 files, 29392896 of 33554432 bytes used [V]); `checkarea.py adsp` checks
the pack too. `scripts/fw/write-areas.sh` writes the area (owner approval; userdata blocks N-11265 .. N-3074).
The ADSP area table has 64 entries (44 in use), so the SLPI goes in as one pack entry with its own table
(`NEGRSLPI`, 32 entries, 4 KiB header). Old kernels ignore the extra entry.

### Test (RAM boot, battery > 30 %)

1. `negronislpi=1 negroniadsp=0 negronipanic=30 negronipanicreason=2` (PAS start alone, no ADSP).
2. `negronislpi=2 negroniadsp=0 ...` (+ GLINK listen).
3. `negronislpi=3 negroniadsp=0 ...` (+ QRTR).
4. With the ADSP: `negroniadsp=1 negronislpi=3 ...` (SLPI after the ADSP thread).

Expected lines (guess [I] until the phone shows them):

```
NEGRONI SLPI: level 1, steps 0..8 (UNTESTED: PAS id 12, carveout 0x87f00000 + 0x1a00000)
NEGRONI SLPI: 1 SMEM partition 0/3 at 0x..., ... 
NEGRONI SLPI: 1 no SLPI SMP2P item 481: the SLPI has not run since the reset
NEGRONI SLPI: 2 slpi.pak: 26 files, 9436 KiB, at area offset 0x...
NEGRONI SLPI: 2 slpi.mdt: 24 program headers, load 0x88000000..0x89a00000 (26624 KiB), 9355 KiB of segments, relocatable
NEGRONI SLPI: 5 TRUSTZONE ACCEPTS THE SLPI SIGNATURE
NEGRONI SLPI: 5 TrustZone takes the carveout 0x87f00000 + 0x1a00000
NEGRONI SLPI: 6 segments written at 0x87f00000 and read back OK
NEGRONI SLPI: 8 TRUSTZONE HAS RELEASED THE SLPI FROM RESET; waiting 10 s for ready
NEGRONI SLPI: 8 +N ms: SLPI SMP2P item 481 appears (...)
NEGRONI SLPI: 8 +N ms: slave-kernel = 0x2 READY        (or 0x6 READY HANDOVER)
NEGRONI SLPI: 8 THE SLPI IS UP after N ms
NEGRONI SLPI: 9 GLINK: the SLPI offers version 1 features 0x...: version 1 ok (features 0x1)
NEGRONI SLPI: 9 GLINK: the SLPI opens "IPCRTR" (rcid N): not ours, left unanswered       (level 2)
NEGRONI SLPI: 9 GLINK: version ok, the SLPI opened N channel(s): IPCRTR (rcid N), ...
NEGRONI SLPI: 10 QRTR: HELLO from node 9                                                 (node number [U])
NEGRONI SLPI: 10 QRTR: NEW_SERVER service 400 (0x190) version 1 instance 0 node 9 port 0x... SNS client (sns_client, SEE)
NEGRONI SLPI: 10 SNS CLIENT SERVICE 400 IS THERE: node 9 port 0x... version 1 instance 0
NEGRONI SLPI: done (level 3, asked 0..10, complete at 10); the SLPI runs
NEGRONI SLPI: 10 watch: polling slave-kernel every 200 ms for FATAL, GLINK too
```

Failure lines to look for: `step N (name) failed: ...`, `SLPI REPORTS FATAL` + `SLPI LAST WORDS`,
`NO READY FROM THE SLPI` (then PAS shutdown), `the ADSP area (44 files) has no slpi.pak` (area not rewritten).

[V] Build (with the review fixes): `out/kernel/local-20261027-004027/kernel.development.negroni` sha256
`07f6194ef8cff8bf08f0bb1c8fb11a9dbf5add9efaea6ffffe19996a89e6996a` (275 applied incl. 0376; only the 4 dxb
skips; link out/kernel/kernel.macho). compile-one: negroni_slpi.c and negroni_adsp.c without warnings. Not booted.

## Phase 2: what is still missing for sensor data

### A. The SLPI asks the HLOS for files (FastRPC reverse RPC `apps_std`)

[V] SLPI strings: `apps_std`, `adsp_default_listener`, `adsp_default_listener_register`,
`file:///libadsp_default_listener1_skel.so?adsp_default_listener1_skel_handle_invoke&_modver=1.0` (b08, b13),
`/dev/fastrpc-smd`, `sns_registry_osa.c:fopen failed | tries=%d/%d | file=%s | error=%i`, `opendir failed | ...
dir=%s`, `readdir`, `fread`, `fwrite`, `fclose`, `skip loading output directory '%s'`,
`no update of sns_reg_config version` (b13). [I] Without answers the registry stays empty and the physical
drivers do not register (they need `bus_type`/`bus_instance` from the registry).

Files the SLPI names in its image ([V] strings; the full list comes from the phase-2 log, which must log every
`apps_std` call with its path):

| Path | Used for | Content source |
|---|---|---|
| `/vendor/etc/sensors/sns_reg_config` (b13) | the registry config: `output=/mnt/vendor/persist/sensors/registry/registry`, `config=/odm/etc/sensor/config`, hw keys from `/sys/devices/soc0/*` [V vendor.img, sensors-plan 1.4] | vendor.img |
| `/mnt/vendor/persist/sensors/registry/registry/` (opendir/readdir + one file per group, 319 groups + `sns_reg_version` [I]) | calibrated registry (bus, IRQ, orientation, factory calibration) | persist dump (device data: never in git) |
| `/odm/etc/sensor/config/` (opendir + `*.json`) | JSON configs, read when the registry version is old [I] | odm.img |
| `/vendor/etc/sensors/config` (b05) | default config dir | vendor.img |
| `/sys/devices/soc0/{hw_platform,platform_subtype,platform_subtype_id,platform_version,soc_id,revision}` | config filters (`soc_id` 457 [I], `hw_platform` QRD [I]) | fixed strings in the server |
| `/mnt/vendor/persist/engineermode/pressure_cali_data` (b13, OnePlus) | pressure calibration; no pressure sensor on this SKU [V plan 1.1] | answer "not found" |
| `/odm/etc/camera/self_ois.ocfg` (b13) | camera OIS (SLPI cam_isp driver) | not needed for sensors; "not found" |
| `/mnt/vendor/persist/sensors/cam_*` (b13, writes) | camera debug dumps | drop writes |
| `/root/data/vendor/pddump/rfs/slpi` (b08) | PD dump path (remote FS) | not needed |

Writes (`fwrite`: registry updates, calibration) go to RAM and are dropped in phase 2 (log them).

Protocol to implement (in the kernel; no userspace FastRPC daemon on iOS) [I from Linux `drivers/misc/fastrpc.c`
and postmarketOS `hexagonrpcd`; none of these sources is in out/src yet, add them to
`scripts/setup/get-references.sh` first]:

1. GLINK channel `fastrpcglink-apps-dsp` on the `dsps` edge (DT intents `<0x64 0x40>`): open it like IPCRTR
   (0376 step 9 logs whether the SLPI opens it).
2. Message `struct fastrpc_msg {int pid; int tid; u64 ctx; u32 handle; u32 sc; u64 addr; u64 size;}` (40 bytes),
   answer `struct fastrpc_invoke_rsp {u64 ctx; int retval;}`. `ctx` low bits carry the PD (SENSORS_PD = 2);
   `addr` is the bus address of one buffer with the argument table (`fastrpc_remote_arg`, page list) and the
   in/out data. `sc` = REMOTE_SCALARS (method << 24 | in bufs << 16 | out bufs << 8 | handles).
3. Attach to the sensors PD: handle 1 (FASTRPC_INIT_HANDLE), method INIT_ATTACH with our tgid
   (Linux `fastrpc_init_attach(fl, SENSORS_PD)`, ioctl FASTRPC_IOCTL_INIT_ATTACH_SNS).
4. Listener: open the remote `adsp_default_listener` interface, call `adsp_default_listener_register`; then the
   `adsp_listener` loop (`next2`: the SLPI returns one reverse call, we answer it in the next `next2`).
   Method numbers and argument layouts of `adsp_listener` and `apps_std` [U]: take them from hexagonrpcd's
   IDL headers.
5. `apps_std` calls to serve: fopen (path, mode) -> handle, fread, fwrite (drop), fseek, ftell/flen, fclose,
   opendir/readdir/closedir, stat [I]. Serve from an in-kernel read-only table.
6. Buffers: `addr` must be a bus address the SLPI can read: the SLPI FastRPC context banks are apps SMMU SIDs
   0x541-0x543, IOVA pool 0x80000000 + 0x78000000 (live DT `qcom,msm_fastrpc`). Reuse the 0324/0325 apps-SMMU
   code (stage-1 context or bypass S2CR). Owner approval: it writes the shared SMMU.
7. Data for the table: a new firmware pack (registry directory + JSON configs + `sns_reg_config`, ~330 small
   files) in the ADSP area (13.8 MB free before the SLPI pack, ~4 MB after it [V]) or a new area.

### B. The servreg locator and the sensor PD

[V] `slpius.jsn`: domain `msm/slpi/sensor_pd`, `qmi_instance_id 90`, service `tms/servreg`; `slpir.jsn` the same
for `root_pd`. [I] The SLPI asks the HLOS servreg locator (QMI service 0x40 on QRTR) for its domains; without a
locator the sensor PD may not start (the same open item as the ADSP charger PD). 0376 step 10 logs what the SLPI
announces; phase 2 adds a locator answer for `msm/slpi/root_pd` and `msm/slpi/sensor_pd` (instance 90)
(Linux `qcom_pd_mapper.c` style) if `service 400` does not appear.

### C. sns_client (QMI service 400, protobuf)

[I] (Qualcomm SEE, open `sns_client.proto` / libssc; message numbers must be checked against the SLPI answers):

| QMI message | Direction | TLVs |
|---|---|---|
| 0x20 SNS_CLIENT_REQ | request | 0x01 payload (bytes: `sns_client_request_msg`), 0x10 use_jumbo_report (u8) |
| 0x20 response | response | 0x02 result, 0x10 client_id (u64), 0x11 result code |
| 0x21 SNS_CLIENT_REPORT_IND | indication | 0x01 client_id, 0x02 payload (`sns_client_event_msg`) |
| 0x22 SNS_CLIENT_JUMBO_REPORT_IND | indication | the same, larger payload |

Protobuf messages (field numbers [I], libssc):

- `sns_client_request_msg {1 suid (sns_std_suid {1 fixed64 low, 2 fixed64 high}), 2 uint32 msg_id,
  3 susp_config {1 client_proc_type, 2 delivery_type}, 4 request (sns_std_request {1 batching, 2 bytes payload})}`.
- SUID lookup: suid = 0xabababababababab / 0xabababababababab, msg_id 512, payload `sns_suid_req {1 string
  data_type, 2 bool register_updates, 3 bool default_only}`; event 768 `sns_suid_event {1 data_type,
  2 repeated suid}`.
- Attributes: msg_id 1 (attr request), event 128 `sns_std_attr_event` (name, vendor, rates, ranges).
- Stream: msg_id 513 `sns_std_sensor_config {1 float sample_rate}`; events 1025 `sns_std_sensor_event
  {1 repeated float data, 2 status}`, 1026 physical config event. ALS/prox on-change: msg_id 514 [U].
- `sns_client_event_msg {1 suid, 2 repeated event {1 msg_id, 2 fixed64 timestamp, 3 bytes payload}}`.
- Data types to look up: `accel`, `gyro`, `mag`, `ambient_light`, `proximity` (+ `rotv`, `gravity`,
  `tilt_to_wake` later). Units: m/s^2, rad/s, uT, lux, near/far.
- C encoder/decoder: varint, length-delimited, fixed64, fixed32/float only (no generated code needed).
- QMI framing over QRTR: reuse `negroni_wlan_qmi.c` (0266) encode/decode with a QRTR client port on the SLPI
  node.

### D. Order of phase 2

1. Boot `negronislpi=3`, read which channels and services the SLPI offers (proves or refutes B).
2. FastRPC attach + listener + `apps_std` with only `sns_reg_config` and the registry directory; log every call.
3. QMI 400 client: SUID lookup for `accel` (expect a non-empty list once the registry is served).
4. Streams, then the IOHIDEventService side (docs/sensors-plan.md phase 2 of that file).
