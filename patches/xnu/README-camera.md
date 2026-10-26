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
| 0317 `negroni-cam-smmu-s1` | `negronicam_smmu=3` (default from level 5) | frame + HFI buffers anywhere in RAM, mapped at 32-bit IOVAs through an apps-SMMU stage-1 context of ours (helper of 0249) | `SMMU context N ON`, `camera DMA through SMMU context N`, `device address 0x10c00000 (SMMU IOVA)` |
| 0318 `negroni-cam-ios-stream` | `negronicam=7` | `/dev/negronicam`: frame stream for iOS (HakiOS `/dev/hakios-camera` ABI), session on first read | `level 7: /dev/negronicam for iOS`, `ios session: start`, `ios session: N frames in M ms` |

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
- Memory: the frame buffers (0.75 MiB TPG, 30 MiB sensor) stay allocated for the device nodes. 0315 asked for them
  below 4 GiB: impossible on this port (see 0317 below).

## 0317, 0318 and 0249: DMA addressing and the stream for iOS (2026-10-27, build only)

### The bug [V]

0243 (audio ring), 0315 (frames) and 0316 (HFI 5 MiB) called `kmem_alloc_contig` with `max_pnum = atop(4 GiB) - 1`.
All XNU RAM on this port is at 0x840000000 or higher (ADT `--dram 840000000:C0000000`), so these allocations always
failed: no camera level that needs a frame buffer or the ICP queues could run, and audio step 14 always stopped.
A 32-bit DMA master (IFE, ICP, the ADSP's 32-bit buffer addresses) can reach our RAM only through an SMMU
translation. Gunyah turns an S2CR BYPASS entry into FAULT (README-wifi.md "2026-10-26 panic fix"), so the only
path is a stage-1 context bank of our own, as Android does with iommu-dma (IOVAs from the DT windows).

### The helper (0249, `bsd/dev/negroni_smmu_s1.c`)

- Generic copy of the 0324/0325 Wi-Fi sequence: `struct negroni_s1 { name, streams[] (SMR id/mask), ... }`,
  `negroni_s1_on`, `negroni_s1_map_kva(iova, kva, size)` (any physical layout, 4 KiB pages), `negroni_s1_report`,
  `negroni_s1_fsr`, `negroni_s1_off`. 3-level 4 KiB tables, 39-bit IOVA, 36-bit PA, MAIR index 0 Normal NC (the CPU
  cleans/invalidates), CBAR S1_TRANS_S2_BYPASS VMID 0, CBA2R VA64, TCR/TCR2/TTBR0 (ASID = bank), TLB sync, SCTLR on,
  then S2CR (translate, bank), then the SMR valid bit. Every global write is read back; on a refusal everything is put
  back before any DMA.
- Every apps-SMMU access is one 32-bit `ldr`/`str` through `negroni_mmio.h` (0255). Global page 0-1 and the
  context-bank pages are mapped separately (kernel_map, not io_submap).
- No collision with Wi-Fi: the helper takes free SMRs and context banks from the TOP index down, 0324/0325 from the
  bottom up; a context bank is free only by the U-Boot qcom-hyp-smmu.c rule (CBAR S2_TRANS, or S1_TRANS_S2_BYPASS
  with VMID 0xff; the rule 0325 uses), SCTLR.M = 0 and no valid S2CR into it; a taken bank gets VMID 0, so the other
  user's rule sees it as used; CBAR/CBA2R are restored at the end; each SMR is read again right before it is
  written; an existing valid SMR that overlaps one of our stream sets stops the setup (a double match is a conflict
  fault) unless it equals ours with a non-translate S2CR (then it is reused and restored).
- Claim lock: `negroni_smmu_claim_lock` (`extern lck_mtx_t`, declared in `negroni_smmu_s1.h`, defined in
  `negroni_smmu_s1.c`) is held from the free-entry scan to the last SMR/S2CR/CBAR write and over the teardown; the
  CBAR is read again right before it is written. The Wi-Fi code (0324/0325) is OUTSIDE this lock until it takes it
  too; until then only the top-down/bottom-up split, the CBAR rule and the re-reads keep the two apart.
- SCTLR: 0324's value (M, TRE, AFE, CFRE, ASIDPNE). The Wi-Fi 0325 rewrite uses HUPCF and no CFRE (DT wlan fault
  flags); here a context fault aborts the access [I].
- `negroni_s1_map_kva` returns ETIMEDOUT when the TLB sync after the map does not finish.
- TODO: one shared `negroni_smmu.c` should replace this helper and `negroni_wlan_smmu.c` (0324/0325). 0324 was not
  edited here (the Wi-Fi agent owns it).

### Audio (0249) [V source, I effect]

Android maps the speaker buffers through the apps SMMU: `qcom,msm-audio-ion` (live.dts:24782-24791) has
`iommus = <&apps_smmu 0x1801 0>`, `qcom,iommu-dma-addr-pool = <0x10000000 0x10000000>`, `qcom,smmu-sid-mask = 0xf`;
`msm_audio_ion.c msm_audio_ion_get_phys` gives the ADSP the dma-buf IOVA of that context ORed with `sid << 32`.
No carveout (`msm-audio-ion-cma` is not used with SMMU on). HakiOS `redwood_sound.c space_on` does the same on its
phone. Source lines: `out/src/op-modules/vendor/qcom/opensource/audio-kernel/dsp/msm_audio_ion.c:37`
(`MSM_AUDIO_SMMU_SID_OFFSET 32`), `:276-279` (the IOVA ORed with the SID bits), `:901-904` (SID from the iommus cell
and `qcom,smmu-sid-mask`). 0249: ring from `kmem_alloc_contig` anywhere, a stage-1 context for SID 0x1801, the ring at IOVA 0x10000000,
the ADSP address `0x1_1000_0000`. `negroniaudio_smmu=0` keeps the 0243 physical path. Proof line:
`NEGRONI AUDIO: 14 ring 8192 bytes at phys 0x8........ -> ADSP address 0x110000000 (SMMU stage 1, SID 0x1801)`
(after `NEGRONI AUDIO: SMMU context N ON ...`).

### Camera DMA (0317)

- `negronicam_smmu=3` is the default when `negronicam>=5` (absent boot-arg); `=1`/`=2`/`=0` keep the 0312 paths
  (they fail at the buffer: `has no 32-bit address ... use negronicam_smmu=3`).
- Streams (live.dts:22589, 22629): IFE one SMR 0x800/0x460 (exactly the 8 SIDs); level 6 adds the ICP SMRs
  0x2000/0x420, 0x2040/0x420, 0x2100/0x420, 0x2080/0x400 (exactly the 14 SIDs; the wider 0x2000/0x5e0 of the
  level-3 report would also catch the JPEG/CDM streams). One context bank for all.
- IOVAs (Android windows, live.dts:22583-22672): frames from 0x10c00000 (inside the IFE io window 0x100000 +
  0xffe00000 and the ICP io window), with at least 1 MiB of unmapped IOVA after each buffer. HFI: Android's layout with a fw_uncached region
  (cam_icp_hw_mgr.c): one 8 MiB block, [0, 7 MiB) at 0x10400000 = sec heap, qtbl, cmd q, msg q, dbg q at 1 MiB steps
  + SFR; [7, 8 MiB) at 0x800000 = shared memory; FWUNC_IOVA/SIZE 0x10400000/0x700000; IO 0x10c00000 + 0xcf400000,
  IO2 0xe0800000 + 0x1e700000 (around the discard window 0xe0000000 + 8 MiB, cam_icp_mgr_hfi_resume).
- Power down: the HFI block is unmapped/freed only after the SMMU teardown (`negroni_s1_off` removes the
  0x10400000/0x800000 mappings first), and it is kept (leaked on purpose, `HFI block ... KEPT`) when the ICP PAS
  shutdown fails, because the ICP may still write it.
- Fault lines: `SMMU context N after the frame|after NO FRAME|after the HFI init: FSR ... stream ...`.
- 0317 also: the ICP PAS SCM loop resumes up to 2000000 times and logs the count (as 0240, main session request).

### Stream for iOS (0318, `negronicam=7`)

- Nothing runs at boot; `/dev/negronicam` (root:mobile 0660: the reader is mediaserverd, which runs as mobile,
  uid/gid 501) is published. The first `read()` after an `open()` starts a session
  thread: level 1-5 bring-up (sensor path, or TPG with `negronicam_src=1`), a ring of 3 frame places (kernel memory,
  15.3 MB each for 4000x3008 RAW10, mapped at IOVAs from 0x10c00000), the 0315 pipe with frame increment 0, then:
  at each RDI0 SOF (CSID path irq bit 4 or 12) the next place's IOVA goes to `WM_IMAGE_ADDR` + RUP/AUP; BUF_DONE
  (bit 14) marks the written place ready. Without SOF bits in 3 frames it programs at BUF_DONE instead.
- ABI = HakiOS `hakios.camera.h` (`out/src/hackios-next/userland/src/hakios.camera.h`, MIT) with own names: a
  120-byte header (magic `NCFRAME1`, width, height, stride, format 1 RAW10, bayer `negronicam_bayer` (default 0
  RGGB [I]), black 64 [I], sequence, mach time, exposure lines, line ns 10636 [I], gain x256 linear (unity 256, max
  4096), frame lines 3134, margin 48, sensor 1, focus none); `read()` = newest frame not read yet (1 s, the first
  6 s), EAGAIN on time-out, EIO after a fault; `write()` commands: EXPOSURE (SMIA 0x0202/3, 0x0204/5 with Sony code
  1024 - 1024/gain [I], 0x0340/1, group hold 0x0104), SENSOR (only 1), KEEP/FOCUS ignored.
- The session ends after the last close, 1 s without a read, no frame for 1.5 s, or an SMMU context fault (then
  EIO until reboot): stream off, `cam_down()`, ring freed. Log: `ios session: start`, `ios session: 30 frames in N ms,
  L late address updates, R read`, `ios session: end (why) after N frames`.
- capture() is split into `pipe_start()`; the register blocks are mapped once per boot (no VA leak per session).
- Userland plan: `docs/camera-ios-2026-10-27.md`.

### Boot-args for the camera test boot

| Goal | Boot-args |
|---|---|
| frames into memory, IFE through our SMMU context (first test) | `negronicam=5 negronipanic=30 negronipanicreason=2` |
| TPG only (no sensor power) | `negronicam=5 negronicam_src=1 ...` |
| ICP (needs the ADSP area with CAMERA_ICP) | `negronicam=6 ...` |
| stream for iOS (after level 5 passes) | `negronicam=7 ...` (TPG stream: add `negronicam_src=1`) |
| audio ring through the SMMU | the audio args as before (`negroniadsp_step=15 ...`); `negroniaudio_smmu=0` = old path |

Expected level-5 proof lines (new in 0317, then the 0315 lines):

```
NEGRONI CAM: SMMU S1 setup: sCR0 ... IDR0 ... IDR1 ...: N SMRs, N contexts, N pages of 0x1000
NEGRONI CAM: SMMU stream 0x800 mask 0x460: SMR<n> (free, was 0 / S2CR ...) -> context <c>
NEGRONI CAM: SMMU context <c> free: CBAR ... CBA2R ...
NEGRONI CAM: SMMU SMR<n> = 0x84600800, S2CR<n> = <c>
NEGRONI CAM: SMMU context <c> ON: SCTLR 0x1027 TTBR0 ...
NEGRONI CAM:   camera DMA through SMMU context <c>: IFE IOVAs from 0x10c00000
NEGRONI CAM: level 3 OK: CPAS/CAMNOC up, IFE DMA SMMU S1, ICP DMA not needed
NEGRONI CAM: SMMU context <c>: IOVA 0x10c00000-0x10cbbfff -> phys 0x8........ (752 KiB)
NEGRONI CAM:   buffer TPG: phys 0x8........, device address 0x10c00000 (SMMU IOVA), ...
NEGRONI CAM:   FRAME DONE: ...
NEGRONI CAM: SMMU context <c> after the frame: FSR 0 (no fault) ...
NEGRONI CAM: TPG frame sanity: PASS ...
```

A refusal reads `SMMU ... reads X after writing Y (the hypervisor refused it?)` or `SMMU ... already matches it:
somebody's entry, left alone`, then `SMMU S1 context not set up (errno N); nothing of ours stays written`.
