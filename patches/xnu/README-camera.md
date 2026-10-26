# Camera patches (0310-0329)

Plan, hardware tables and levels 3-5: `docs/camera-plan.md`. Knowledge-base entry: `docs/notes.md` section 13.
Marks: **[V]** seen in a source (file:line given), **[I]** inference. Nothing here has run on the phone yet.

| Patch | Boot-arg | What it does | Proof line |
|---|---|---|---|
| 0310 `negroni-cam-camcc-cci` | `negronicam=1` | new `bsd/dev/negroni_cam.c` (own kernel thread): GCC camera clocks, camcc titan top GDSC, camcc AHB/CAMNOC/CCI0 clocks from the 19.2 MHz TCXO, CCI0 version + reset; then everything off | `NEGRONI CAM: level 1 OK: camcc + CCI0 up` |
| 0311 `negroni-cam-imx789-chip-id` | `negronicam=2` | level 1 + rear main IMX789 (slot 0) power-up, CCI0 M0 chip-ID read, vendor power-down; `negroni_rpmh_cam_rail` in `negroni_rpmh.c` (whitelist + enable=0 off command) | `NEGRONI CAM: chip id 0x0789 (expected 0x0789, ...): MATCH` |

Default (`negronicam` absent or 0): no camera register access, no thread. `negronicam_pause=N` waits N ms
(max 2000) after each step, for a phone camera on the screen log.

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
