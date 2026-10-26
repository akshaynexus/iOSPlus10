# Camera patches (0310-0329)

Plan, hardware tables and levels 3-5: `docs/camera-plan.md`. Knowledge-base entry: `docs/notes.md` section 13.
Marks: **[V]** seen in a source (file:line given), **[I]** inference. Nothing here has run on the phone yet.

| Patch | Boot-arg | What it does | Proof line |
|---|---|---|---|
| 0310 `negroni-cam-camcc-cci` | `negronicam=1` | new `bsd/dev/negroni_cam.c` (own kernel thread): GCC camera clocks, camcc titan top GDSC, camcc AHB/CAMNOC/CCI0 clocks from the 19.2 MHz TCXO, CCI0 version + reset; then everything off | `NEGRONI CAM: level 1 OK: camcc + CCI0 up` |
| 0311 `negroni-cam-imx789-chip-id` | `negronicam=2` | level 1 + rear main IMX789 (slot 0) power-up, CCI0 M0 chip-ID read, vendor power-down; `negroni_rpmh_cam_rail` in `negroni_rpmh.c` (whitelist + enable=0 off command) | `NEGRONI CAM: chip id 0x0789 (expected 0x0789, ...): MATCH` |
| 0312 `negroni-cam-cpas-smmu-votes` | every level (`negronicam_votes=1`), `negronicam=3` | votes before the first camcc access: RPMh `mmcx.lvl` NOM + BCM CN0/MM1/MM0/SH0/MC0 (`negroni_rpmh_cam_bcm`); level 3: CPAS top + CAMNOC (version, IFE_RDI_WR QoS, error logger), apps-SMMU state of the IFE and ICP stream groups (`negronicam_smmu`) | `level 3 OK: CPAS/CAMNOC up, IFE DMA bypass, ICP DMA bypass` |
| 0313 `negroni-cam-clocks-csiphy` | `negronicam=4` | `mxc.lvl` NOM (256), camcc PLL0 1200 MHz + PLL3 864 MHz, CPHY_RX/CSI1PHYTIMER/CSID 400 MHz, IFE0 432 MHz, IFE0 GDSC; CSIPHY1 C-PHY 3 trios (v2.1.0 tables) | `trio N status ... normal`, `level 4 OK: capture clocks + CSIPHY1 C-PHY configured` |
| 0314 `negroni-cam-imx789-stream` | `negronicam=4` | IMX789 FTM table (116 writes, stream on), frame counter 0x0005, stream off on every path | `IMX789 frame counter 0x.. -> 0x.. -> 0x..: MOVES (sensor streams)` |
| 0315 `negroni-cam-csid-ife-rdi` | `negronicam=5` | CSID0 + IFE0 RDI0 frame-based WM -> contiguous buffer < 4 GiB; TPG13 frame, then sensor frame; `/dev/negronicam-tpg`, `/dev/negronicam-sensor` | `FRAME DONE`, `TPG frame sanity: PASS`, `SENSOR frame sanity: PASS`, `level 5 OK` |
| 0316 `negroni-cam-icp-pas-hfi` | `negronicam=6` | CAMERA_ICP from the ADSP area into camera_region, PAS 33, HFI init + SYS_INIT | `ICP READY: HFI init response SUCCESS`, `ICP message: ... HFI_MSG_SYS_INIT_DONE` |

Default (`negronicam` absent or 0): no camera register access, no thread. `negronicam_pause=N` waits N ms
(max 2000) after each step, for a phone camera on the screen log.

More boot-args (0312-0316): `negronicam_votes=0|1` (default 1: RPMh MMCX + camera BCM votes before the first camcc
access), `negronicam_smmu=0|1|2` (0 report only, 1 default: stop before DMA when a needed stream group would fault or
translate, 2 add a bypass SMR/S2CR pair and remove it at power down), `negronicam_src=1|2|3` (1 TPG only: no sensor
power, all capture clocks at TCXO; 2 sensor only; 3 default: TPG frame, then sensor frame), `negronicam_drate=0`
(C-PHY data-rate entry; only 0 is carried), `negronicam_settle=N` (default 52).

## Build (macOS; done 2026-10-26)

- Kernel: `scripts/bg.sh kernel-cam scripts/kernel/build-local.sh` (full patch set, 64 patches/xnu at the time)
  -> `out/kernel/local-20261026-082431/kernel.development.negroni`, sha256
  `fe5d2ef5253470fb3adb0de8a2ef0cf4420a0f30a5d6bbce7862304af2ee8dfc`. Report: 0310 and 0311 applied (review fixes F1-F3 in); skipped: the 4 usual
  dxb patches and another agent's 0274-negroni-charger-glink (does not apply on negroni_adsp.c:1644; not camera).
  Kernel and image were built under one `out/kernel/.lock` hold.
- Image: `scripts/bg.sh ios16-cam env IOS16_OUT=out/ios16-cam BOOTARGS_ADD="negronicam=2 negronipanic=30 negronipanicreason=2" scripts/ios16/build.sh`
  with `out/kernel/kernel.macho` -> that kernel (config args + the three args). Hashes: `out/ios16-cam/SHA256SUMS`.
- Syntax check of one file: `scripts/kernel/compile-one.sh out/kernel/tree-X bsd/dev/negroni_cam.c`.

## Steps and the log

Every step prints `NEGRONI CAM: step N NAME`, then `... ok (T us)` or `... failed: REASON (T us)`. Indented lines
are details. After the last step (or a failure) `power down` ... `power down done`, then
`NEGRONI CAM: done (asked level L, complete|STOPPED at step N NAME)`.

| Step | Name | Registers | Bounded wait | Failure reasons |
|---|---|---|---|---|
| 1 | map | GCC 0x136000 (1 page), camcc 0xade0000 (0x20000), CCI0 0xac15000, level 2: TLMM gpio100-120 | - | map returned 0 |
| 2 | gcc camera clocks | GCC 0x36004/0x36020 (critical: enable bit set only when clear; with HWCG_EN (bit 1) set, CLK_OFF is not checked, as Linux), 0x36010/0x36018 (HF/SF AXI, halt skip) | 10 us | critical clock stays off |
| 3 | titan top gdsc | camcc 0x1320c (gdsc_clk), GDSCR 0x131dc: clear SW_COLLAPSE, poll PWR_ON, set RETAIN_FF | 500 us | all ones / HW control / no power-on |
| 4 | camcc clocks | RCGs 0x10034, 0x10018, 0x13194, 0x1312c to TCXO (ROOT_EN, UPDATE); branches 0x13164, 0x131f0, 0x1316c, 0x131ac, 0x13144 | 500 us each | UPDATE stuck / halt bit stuck |
| 5 | cci0 controller | version 0x0, IRQ masks, RESET_CMD 0x0f73f3f7 then 1, RST_DONE (IRQ_STATUS_0 bit 24), RD threshold 0x30, M0 timing | 100 ms | version 0 or all ones / no reset ack |
| 6 | sensor pins | gpio120 output low (cfg 0x200), gpio100 func 1 (0x4) | - | - |
| 7 | sensor rails | RPMh: ldoi3 2800 mV, ldoi1 1104 mV HPM, ldoc2 1800 mV HPM, ldoi7 2800 mV, ldoi5 1800 mV HPM | 100 ms per vote, EBUSY retry 1 s | REFUSED (not a DT value) / FAILED errno |
| 8 | sensor reset high | gpio120 io = 2, then 1 ms | 1 ms | - |
| 9 | mclk0 19.2 MHz | RCG 0x15000 to TCXO, branch 0x15018, then 1 ms | 500 us + 1 ms | UPDATE / halt bit |
| 10 | cci0 m0 pins + reset | gpio110/111 func 1 pull-up (0x7), RESET_CMD 0x3f1, M0 timing | 100 ms | no master reset ack |
| 11 | chip id | queue M0 Q1: SET_PARAM 0x1a1, LOCK, WRITE_DISABLE_P 0x16002b, READ 0x2a, UNLOCK; RD_DONE | 100 ms, 3 tries | NACK (ENXIO) / timeout / FIFO level / wrong id |

Expected good level-2 log (values marked `N`/`...` depend on the hardware):

```
NEGRONI CAM: level 2 (UNTESTED: camcc + CCI0 + IMX789 power + chip id)
NEGRONI CAM: step 5 cci0 controller
NEGRONI CAM:   CCI0 hw version 0x...            (not 0x0, not 0xffffffff)
NEGRONI CAM:   CCI0 reset done ack after N us
NEGRONI CAM: level 1 OK: camcc + CCI0 up
NEGRONI CAM:   cam_vana (ldoi3) on 2800 mV mode -1: ok (errno 0)
NEGRONI CAM:   cam_vdig (ldoi1) on 1104 mV mode 7: ok (errno 0)
NEGRONI CAM:   cam_vio (ldoc2) on 1800 mV mode 7: ok (errno 0)
NEGRONI CAM:   cam_vaf (ldoi7) on 2800 mV mode -1: ok (errno 0)
NEGRONI CAM:   cam_v_custom1 (ldoi5) on 1800 mV mode 7: ok (errno 0)
NEGRONI CAM:   CCI0 M0 read sid 0x1a reg 0x0016: data word 0x..8907.. -> 0x0789
NEGRONI CAM: chip id 0x0789 (expected 0x0789, IMX789 slot 0 CCI0 M0 sid 0x1a reg 0x0016): MATCH
NEGRONI CAM: level 2 OK: IMX789 answered on CCI0 M0
NEGRONI CAM: power down
NEGRONI CAM:   cam_vaf (ldoi7) off 2800 mV mode -1: ok (errno 0)      (then custom1, vio, vdig, vana)
NEGRONI CAM: done (asked level 2, complete at step 11 chip id)
```

How to read a failure [I]:
- Hang (no more lines) at step 3 or 4: the first camcc access needs a NoC or clock vote that the UEFI did not
  leave on. Next: add the `cam_ahb` interconnect vote (DT `interconnect-names = "cam_ahb"` in the CPAS node).
- `GDSC did not power on (MMCX off?)`: MMCX is not up. An MMCX vote from our DRV can replace the UEFI display vote;
  make it a separate, opt-in step.
- `no version or no reset ack`: the CCI clock does not run (check the `cam_cc_cci_0_clk` cbcr line: bit 31 = off).
- `sensor NACK` with all rails ok: wrong slave address, reset still low, or no MCLK; try `negronicam_pause=2000`
  and film the screen; then compare with slot 1 (S5KJN1, sid 0x10, register 0x0000, 0x38e1).
- `REFUSED` must never appear: it means a table edit broke a DT value. Do not bypass it.
- `WARNING: rails still voted on`: an RPMh vote failed (poisoned path after a timeout). Reboot the phone.

## Facts and sources (all [V] unless marked)

- Clocks from TCXO: each camcc source used has `F(19200000, P_BI_TCXO, 1, 0, 0)` (camcc-waipio.c:955, 988, 1257,
  1587, 1926; OnePlus kernel `out/src/op-kernel`); source select 0 = TCXO (parent maps :814, :830). The DT CCI rate
  37.5 MHz (`out/live.dts:22056`) needs PLL0 (camcc-waipio.c:989); not used. CCI 19.2 MHz standard timing:
  thigh 78, tlow 114, tsu_sto 28, tsu_sta 28, thd_dat 10, thd_sta 77, tbuf 118, trdhld 6, tsp 1
  (Linux `i2c-qcom-cci.c:255-265`; the same file maps `qcom,sm8450-cci` to `cci_v2_data`, :871).
- RCG/branch/GDSC bits: clk-rcg2.c:27-43, clk-branch.c:47 and :84-98 (HALT_DELAY 10 us; Linux polls 200 x 1 us, this code 500 x 1 us; hwcg skip :21, :80),
  gdsc-regulator.c:30-49, :208-350; DT GDSC `out/live.dts:1015-1024` (timeout 0x1f4, retain-regs).
- CCI registers and command codes: camera-kernel `cam_cci_hwreg.h`, `cam_cci_dev.h:242-253` (commands), :75
  (`CCI_VERSION_1_2_9` 0x10020009); init order `cam_cci_soc.c` `cam_cci_init`/`cam_cci_init_master`; read sequence
  `cam_cci_core.c` `cam_cci_read`.
- Slot 0 sensor node `out/live.dts:22204-22238`: clocks camcc 0x4c = `CAM_CC_MCLK0_CLK` (binding header 76),
  cci-master 0, gpios tlmm 100 / 120, flags 1 / 0, regulators and voltages 22220-22230. Pins: `pinctrl-waipio.h:1735,
  1747-1748` (function 1), REG_BASE 0x100000 (:13); pull values `pinctrl-msm.c:330-333`.
- Rails: RPMh nodes `out/live.dts:11083-11092` (ldoc2), 11672-11681 (ldoi1), 11708-11715 (ldoi3), 11738-11747
  (ldoi5), 11771-11778 (ldoi7). HPM raw value 7: `rpmh-regulator.c:287`; DT mode enum
  `qcom,rpmh-regulator-levels.h:69-71`. pm8350c_l2 has only camera consumers in the live DT.
- Power order: module file `semco_imx789_MP` (`out/camera/modules.txt:49-50`). The OnePlus kernel has no in-kernel
  IMX789 power table; it tests `sensor_id == 0x789` (`oplus_cam_sensor_core.c:201`).
- [I] No MMCX/MXA ARC vote and no interconnect vote (the UEFI display keeps them). [I] Polled CCI: the IRQ line
  SPI 0x1cc (`out/live.dts:22061`) has no handler and stays disabled in the GIC.

## Risks

- A wrong rail voltage can damage the sensor. Every voltage comes from the live DT with file:line, is checked at
  run time against the regulator node range, and is whitelisted a second time in `negroni_rpmh_cam_rail`.
  A missing or zero value is refused.
- Only the slot 0 rails are touched. pm8350c_l2 (VIO) is shared by all camera modules only.
- Bus hang on the first camcc/CCI access (no NoC vote) hangs one CPU or the phone; the run is opt-in and in its own
  thread. Use `negronipanic=30` so a panic reboots.
- The camera is never left on: the power-down runs after success and after every failure.

## Levels 3-6 (patches 0312-0316, 2026-10-26, build only)

All [V] facts have file:line in the `negroni_cam.c` comments. Nothing ran on the phone.

### Steps (continued from the table above)

| Step | Name | Registers | Bounded wait | Failure reasons |
|---|---|---|---|---|
| 0 (first, all levels) | rpmh mmcx + camera noc votes | RPMh ARC `mmcx.lvl` 256; BCM CN0, MM1 (enable bit), MM0, SH0, MC0 (avg 1, peak 3 GB/s; x/y from the cmd-db unit/width as Linux bcm-voter.c) | 1 s EBUSY retry, 100 ms per vote | `MMCX vote` / `BCM vote` (missing cmd-db entry, RPMh timeout) |
| 12 | cpas + camnoc | CPAS top 0xac13000 +0/+4/+8 versions; CAMNOC 0xac19000: SBM 0x2240/0x2280, IFE_RDI_WR 0x5230-0x5248; at power down QCHANNEL 0x5c/0x60 | 12.5 ms (qchannel) | `CPAS top does not answer` |
| 13 | apps smmu camera streams | 0x15000000 sCR0, IDR0, SMR/S2CR; with `negronicam_smmu=2` one SMR + S2CR bypass per group | - | `a camera stream group would fault or translate` (IFE at level >= 5, ICP at level 6) |
| 14 | capture clocks | `mxc.lvl` 256; PLL0 (camcc +0x0) / PLL3 (+0x3000) Lucid EVO configure + RUN + LOCK_DET; RCGs 0x1104c, 0x15104, 0x13174, 0x11018; IFE0 GDSC 0x11004; 7 branches | 200 us lock, 500 us RCG/branch/GDSC | `PLL did not lock`, `IFE0 GDSC did not power on`, `branch clock did not start` |
| 15 | csiphy1 c-phy 3 trios | 0xace6000: reset 0x1000/0x1014, common 0x1018/0x101c/0x1084, data-rate regs, 37 regs x 3 trios, irq 0x102c-0x1054, release 0x1000 = 0x0e | 3048 us after release | `only data-rate entry 0` |
| 16 (level 4) | imx789 ftm table + stream on | 116 CCI writes, then 3 reads of 0x0005 | 100 ms per CCI transaction | `CCI write`, `the sensor does not stream` |
| 16-17 (level 5) | csid0 + ife0 map; tpg13 -> ... -> memory; imx789 -> ... -> memory | CSID 0xacb7000 (reset 0x0c/0x10, RX 0x200/0x204, RDI0 0x500-0x54c, RUP/AUP 0x18), CSID top 0xacb6000 +0 = 0x101, IFE0 WM RDI0 0xac62000 + 0x2600, TPG13 0xacf6000 | CSID reset 100 ms; frame 1 s (TPG) / 2 s (sensor) | `NO FRAME`, `frame sanity: FAIL` |
| 18-21 (level 6) | icp clocks, icp firmware, icp pas 33, icp hfi init | camcc 0x13108/0x13128/0x13120; area via `negroni_ufs_adsp_area_read`; SCM PAS calls; LX7 CSR 0xac01000 + 0x20 + 4n | HFI init 1.5 s, SYS_INIT 5 s | `TrustZone refuses ...`, `no HFI init response`, `no SYS_INIT_DONE` |

### Expected good level-5 log (abridged; values marked `..` depend on the hardware)

```
NEGRONI CAM: level 5 (UNTESTED: camcc + CCI0 + IMX789 power + chip id + CPAS/CAMNOC + SMMU check)
NEGRONI CAM: step 1 rpmh mmcx + camera noc votes ... ok
NEGRONI CAM: level 2 OK: IMX789 answered on CCI0 M0
NEGRONI CAM:   titan camera version 0x60800 (6.8.0), cpas version 0x1..
NEGRONI CAM:   IFE DMA by physical address: YES        (or NO: then negronicam_smmu=2, see below)
NEGRONI CAM: level 3 OK: CPAS/CAMNOC up, IFE DMA bypass, ICP DMA ..
NEGRONI CAM:   cam_cc_pll0 locked: mode 0x8...0007
NEGRONI CAM:   trio 0 status 0x.. (low 5 bits 0x0: normal)
NEGRONI CAM: level 4 OK: capture clocks + CSIPHY1 C-PHY configured
NEGRONI CAM:   FRAME DONE: BUF_DONE status 0x4000 after N ms ...
NEGRONI CAM: TPG frame first bytes: .. (colour bars)
NEGRONI CAM: TPG frame sanity: PASS (non-constant data in most of the buffer)
NEGRONI CAM: IMX789 frame counter 0x.. -> 0x.. -> 0x..: MOVES (sensor streams)
NEGRONI CAM:   FRAME DONE: ...
NEGRONI CAM: SENSOR frame sanity: PASS ...
NEGRONI CAM: frames readable as /dev/negronicam-tpg and /dev/negronicam-sensor (scripts/camera/pull-frame.sh)
NEGRONI CAM: level 5 OK: raw frame(s) in memory (TPG sensor)
NEGRONI CAM: power down ... power down done
```

### How to read a failure [I]

- `IFE DMA by physical address: NO` then `STOPPED at step 13`: the IFE streams have no bypass. Boot again with
  `negronicam_smmu=2` (adds one SMR 0x800/0x460 with S2CR bypass; removed at power down). If the readback line says
  the SMMU did not take it, the hypervisor owns the SMMU: a context bank of our own is the next work (redwood_sound.c
  `space_on` pattern).
- `PLL did not lock`: MXC too low or the PLL is owned elsewhere; try `negronicam_src=1` (TPG at TCXO, no PLL).
- TPG `NO FRAME` with `RDI0 irq` SOF/EOF bits set: the CSID got the frame but the IFE write did not finish: look at
  the IFE bus violation/overflow words and the CAMNOC errlog line. No SOF at all: the TPG mux or the CSID clock.
- Sensor: trio status not `normal`, or `rx packets 0`: C-PHY settle/data-rate (`negronicam_settle=`), or the
  FTM mode does not match the trio count; `CRC errors` > 0: wrong data-rate entry.
- Frame counter `STUCK`: the sensor did not leave standby (table error) or MCLK stopped.
- Level 6: `TrustZone refuses the CAMERA_ICP metadata` = TZ rejects this signature/PAS id on this boot chain;
  `no HFI init response` with the SFR text = firmware crash (the SFR line has the reason); `no SYS_INIT_DONE` = the
  queues are not reachable (physical addresses through the ICP SMMU context).

### Firmware for level 6

`scripts/camera/extract-icp-fw.sh` copies CAMERA_ICP.mdt + .b00-.b20 (from `out/camera/x/vendor-firmware`, made by
`scripts/camera/inventory.sh`) into `out/firmware/adsp`; `scripts/audio/mkadsparea.py` now adds them (empty segment
files skipped); `scripts/fw/build-areas.sh` makes the ADSP area (44 files; test build: 19728068 of 33554432 bytes,
checkarea OK). The area reaches the phone only with the userdata flash (`AREAS=1 scripts/ios16/root-simg.sh`).

### Frames

`scripts/camera/pull-frame.sh` (SSH over the USB network) reads `/dev/negronicam-tpg` / `-sensor` into
`out/camera/frames/`, and `scripts/camera/raw-to-png.py` writes a PNG (half-size RGB with gray-world white balance,
`--full` gray, `--bayer gray|RGGB|BGGR|GRBG|GBRG`; the IMX789 Bayer order in this mode is not known [I]).
Header: 64 bytes `NCAMRAW1`, u32 version, width, height, stride, bytes, data type, bits, packing, source, valid.

### Build

`scripts/bg.sh cam3-build scripts/camera/build-kernel.sh` (full kernel under `out/kernel/.lock`; no boot image: the
main session builds one combined image). Results: notes.md section 13 and docs/plan.md.

### Boot-args (for the combined image)

| Goal | Boot-args |
|---|---|
| first phone test (recommended) | `negronicam=5` (votes, levels 1-5: TPG frame then sensor frame; stops before DMA when the IFE streams are not in bypass) |
| if the log says `IFE DMA by physical address: NO` | `negronicam=5 negronicam_smmu=2` |
| TPG only (no sensor power, no camcc PLL, all at 19.2 MHz) | `negronicam=5 negronicam_src=1` |
| sensor streaming without CSID/IFE | `negronicam=4` |
| ICP (needs the new ADSP area on userdata) | `negronicam=6` (+ `negronicam_smmu=2` if needed) |
| film the screen log | add `negronicam_pause=500` |
| tuning | `negronicam_settle=N` (C-PHY settle count, default 52), `negronicam_votes=0` (no RPMh votes: 0310/0311 behaviour) |

Keep `negronipanic=30 negronipanicreason=2` as in the other test images.

### Risks (levels 3-6)

- Votes from this DRV replace this DRV's earlier votes: MMCX 256, MXC 256 (NOM: gpu_cc_pll0 shares vdd_mxc,
  gpucc-waipio.c:98-110) and the BCM values are chosen at or above what
  the display needs [I]; they stay after the run. A lower UEFI need is not a problem; a higher one (unlikely) would
  be lowered.
- `negronicam_smmu=2` writes the apps SMMU; under Gunyah the write can fault or be ignored (the readback tells).
- 2026-10-26 panic fix: the Wi-Fi SMR scan (0263) panicked with ESR 0x96000010 (SEA) because Gunyah emulates the
  apps SMMU global space only for single 32-bit `ldr w, [x]` / `str w, [x]` accesses (ESR ISV=1); a writeback,
  pair, 64-bit or WZR access gets an SEA injected (docs/notes.md section 27). [V] The camera code (0312 `l3_smmu`)
  already uses the 0310 `rd()`/`wr()`: noinline functions with one inline-asm `ldr %w0, [%1]` / `str %w0, [%1]` and
  `"r"` operands, so no change was needed (0255 `negroni_mmio.h` has the same accessors for the Wi-Fi code).
- [I] `negronicam_smmu=2` is expected to read back as FAULT: the Android driver (arm-smmu-qcom.c:2288, mainline
  `bypass_quirk`) says this hypervisor treats S2CR TYPE bypass as blocked. DMA through this SMMU needs a stage-1
  context (as the Wi-Fi `negroniwlan_smmu=3`, 0324); the camera has no such path yet.
- The sensor streams only while the frame wait runs; the stream off runs on every path (also on a failed write after
  the stream-on entry).
- C-PHY settle count and data-rate entry are inferences; a wrong value gives CRC/ECC errors, not damage.
- ICP: TrustZone loads and starts the firmware; a failed auth leaves the ICP in reset; PAS shutdown runs at power down
  after any PAS step.
- Memory: the frame buffers (0.75 MiB TPG, 30 MiB sensor, both below 4 GiB) stay allocated for the device nodes.
