# Charger over GLINK: the ADSP charger PD (patch 0274)

Status 2026-10-26: code done, builds, **untested on the phone**. Boot-args `negroniadsp=1
negronichg_glink=1 negronichg_ma=1500`. Image `out/ios16-chg3`.

[V] = read in a file or a log (cited). [I] = inference. [U] = unknown.

## 1. Why

- [V phone log `logs/usblog-20261026-131747.txt` 13:17:51-13:22:48] The HLOS cannot reach the PM8350B
  charger: `charger CHGR APID -1 EE 7 USBIN APID -1 EE 7`; the SMB5 PPIDs 0x10-0x13/0x15 are not in
  the APID map (0x14 and 0x16 belong to EE 4). The SPMI debug arbiter is fused off:
  `fuse 0x221c8784 = 0x4900000, bit 18 clear`. Patch 0273 cannot write the charger.
- [V same log] With USB in, VBUS 4.87-4.94 V, the input current `iin` is 725-1000 mA and stays at
  ~1000 mA under load (998-1000 mA in 9 of 15 polls). The battery current is 0..+146 mA at idle and
  -351..-1289 mA under load. The phone takes ~1 A from USB and the load takes all of it. The cell
  voltage stays at 3.52-3.69 V. [I] The charger runs at a ~1000 mA input limit (hardware default
  after XBL/ABL), so the net charge is near zero.
- [V `out/live.dts:6637-6645`] The ADSP owns the charger: node `qcom,pmic_glink`,
  `qcom,pmic-glink-channel = "PMIC_RTR_ADSP_APPS"`, `qcom,subsys-name = "lpass"`,
  `qcom,protection-domain = "tms/servreg", "msm/adsp/charger_pd"`, child `qcom,battery_charger`
  with `oplus,chg_ops = "plat-pmic"`, `qcom,voocphy_support = <1>`.
- [V `out/src/op-modules/vendor/oplus/kernel/charger/charger_ic/oplus_battery_sm8450.c`] OxygenOS
  sets the input limit and charging enable only with `pmic_glink_write` (`write_property_id`
  :879-895, `oplus_chg_set_input_current` :7911, `smbchg_charging_enable` :8270-8290).

## 2. The battery percentage

Out of scope for 0274: the percentage problem (the "12 % after a night on the charger" report) is
patch 0275 (separate agent). Facts found here and handed over:
- [V `iokit/Kernel/arm/NegroniBattery.cpp` 0271-0273] NegroniBattery reads no fuel gauge; `soc 1150`
  is its own voltage/coulomb estimate (1/100 %).
- [V `out/live.dts`] no `qcom,qpnp-qg` node; `qcom,external_gauge` at :6804. OxygenOS takes the SoC
  from the OEM read buffer word 3 (see 4) because `voocphy_support = 1` = ADSP_VOOCPHY
  [V `oplus_battery_sm8450.c:10727-10745`, `oplus_charger.h:617-623`].
- [V] VADC 3693 mV per cell (13:17:51) and fastboot `battery-voltage 7382` (3691 mV per cell) agree:
  the cell is really low; the phone did not charge.
- 0274 publishes the PD's SoC as the registry key `NegroniChargerGlinkSOC` (1/100 %) for 0275; it
  does not change the percentage.

## 3. Transport

- GLINK over SMEM to the ADSP (edge `lpass`, IPCC client 3 signal 0), patch 0242
  (`bsd/dev/negroni_adsp.c`, API `negroni_glink_poll/_up/_set_rx/_send`, one recursive lock).
- Channel name `PMIC_RTR_ADSP_APPS` [V live.dts:6639; Linux `drivers/soc/qcom/pmic_glink.c`
  `pmic_glink_rpmsg_id_match` `.name = "PMIC_RTR_ADSP_APPS"`]. It is a third channel on the same
  edge as `IPCRTR` and `adsp_apps` [V docs/audio-plan.md GLINK row: channels IPCRTR, adsp_apps,
  PMIC_RTR_ADSP_APPS, fastrpcglink-apps-dsp].
- 0242 knows only channels 0..1. 0274 adds channel 2 (`NEGRONI_GLINK_PMIC`, lcid 3) with small hunks
  in `negroni_adsp.c`/`.h` (0242 itself is not changed): the table entry; the remote OPEN of this
  name is answered only when `negronichg_glink=1` (`negroni_chg_glink_wanted()` in the name match);
  step 9 still opens and waits for channels 0..1 only (`NEGRONI_GLINK_STEP9`); new call
  `negroni_glink_open(c, intents, wait_ms)` (under gl_lock: send our OPEN, wait for both opens, give
  4 RX intents of 4096 bytes). The channel is internal to 0242's static table, so a hunk is needed.
- No extra framing: one pmic_glink message = one GLINK TX_DATA [V Linux `pmic_glink_send` ->
  `rpmsg_send`].

## 4. Message formats (all fields u32 little endian)

Header `struct pmic_glink_hdr { owner, type, opcode }` (12 bytes)
[V `out/src/op-kernel/include/linux/soc/qcom/pmic_glink.h:38-47`; Linux `include/linux/soc/qcom/pmic_glink.h`].

| Field | Value | Source |
|---|---|---|
| owner | 32778 = 0x800a (`MSG_OWNER_BC`, Linux `PMIC_GLINK_OWNER_BATTMGR`) | oplus_battery_sm8450.h:46 [V] |
| type | 1 request/response, 2 notify | :47-48 [V] |

| Opcode | Name | Request body (after hdr) | Size | Answer |
|---|---|---|---|---|
| 0x30 | BC_BATTERY_STATUS_GET | battery_id 0, property_id, value 0 | 24 | `{hdr, property_id, value, ret_code}` 24 B |
| 0x31 | BC_BATTERY_STATUS_SET | battery_id 0, property_id, value | 24 | same, ret_code 0 = ok |
| 0x32 | BC_USB_STATUS_GET | battery_id 0, property_id, value 0 | 24 | 24 B |
| 0x33 | BC_USB_STATUS_SET | battery_id 0, property_id, value | 24 | 24 B |
| 0x04 | BC_SET_NOTIFY_REQ (type 2) | battery_id, power_state, low_capacity, high_capacity (all 0) | 28 | ack with opcode 0x04 |
| 0x07 | BC_NOTIFY_IND (from the ADSP, type 2) | - | - | `{hdr, notification}` 16 B: 0x30 battery, 0x32 USB (plug), 0x34 wireless, 0x80 generic |
| 0x10000 | OEM_OPCODE_READ_BUFFER | data_size = 512 | 16 | `{hdr, data[128], data_size}` 528 B |

Structs [V `oplus_battery_sm8450.h`: `battery_charger_req_msg`, `battery_charger_resp_msg`,
`battery_charger_set_notify_msg`, `battery_charger_notify_msg`, `oem_read_buffer_req_msg/resp_msg`
:120-129, `MAX_OEM_PROPERTY_DATA_SIZE 128` :43]. A model-name answer is 144 B
(`battery_model_resp_msg`, property 18). `ret_code` 512 = `BATTMNGR_EFAILED` (i2c failure) [V .h:117].

Property ids (OnePlus enum, `oplus_battery_sm8450.h`; ids 0..23 = Qualcomm `qti_battery_charger.c` and
Linux `qcom_battmgr.c` sm8350 [V]; the OPLUS ids count on from there with `OPLUS_FEATURE_CHG_BASIC`
[I: set in the OnePlus build]):

| Battery (0x30/0x31) | id | Unit | USB (0x32/0x33) | id | Unit |
|---|---|---|---|---|---|
| BATT_STATUS | 0 | 1 charging, 2 discharging, 3 not charging, 4 full | USB_ONLINE | 0 | 0/1 |
| BATT_CAPACITY | 4 | 1/100 % (`DIV_ROUND_CLOSEST(v, 100)`, :3054) | USB_VOLT_NOW | 1 | uV (`/1000` = mV, :9511) |
| BATT_VOLT_NOW | 7 | uV | USB_CURR_NOW | 3 | uA |
| BATT_CURR_NOW | 9 | uA | USB_INPUT_CURR_LIMIT | 5 | **uA** (`current_ma * 1000`, :7822, :7640) |
| BATT_CHG_CTRL_LIM | 10 | FCC uA (`fcc_data * 1000`, :11931) | USB_ADAP_TYPE | 7 | power_supply usb type |
| BATT_TEMP | 12 | 1/100 C (`/10` = decidegree, :3060) | USB_SUSPEND_PMIC | 26 | 1 = input suspended |
| BATT_CHG_EN | 24 | 1 enable (`smbchg_charging_enable` :8285), 0 disable (:9136) | USB_IN_STATUS | 47 | low byte = plug status (:8729) |

OEM read buffer words [V `oplus_battery_sm8450.c:338-344` and `fg_bq27541_*`]: [0] temperature
0.1 C, [1] current uA (`/1000` = mA, :10759-10790), [2] voltage uV (`/1000`, :10640), **[3] SoC in 1/100 %**,
[4] remaining capacity, [5] cycle count, [6] FCC, [7] cc, [8] SoH, [9] suspend, ...

Operations of 0274:

| Goal | Message |
|---|---|
| battery status | 0x30 ids 0, 4, 7, 9, 10, 12 + 0x10000 OEM buffer |
| USB input status | 0x32 ids 0, 1, 3, 5, 7, 26, 47 |
| set USB ICL | 0x33 id 5 value mA*1000; 500 mA steps to `negronichg_ma` (default 1500, cap 2000 = live.dts:6652-6654 charger/PD/QC input limit; Android clamps to pd_curr_max, :7960-7962); back one step when USB_VOLT_NOW < 4500 mV (4550 above 4100 mV per cell), as `oplus_chg_set_input_current` :7911-7990 does with 100 mA steps |
| input un-suspend | 0x33 id 26 value 0, only when id 26 reads non-zero |
| enable charging | 0x31 id 24 value 1 |

## 5. Ready and notifications

- Linux mainline [V `pmic_glink.c:213-263`]: clients get `SERVREG_SERVICE_STATE_UP` when the PDR
  notifier (QMI servreg over QRTR, service `tms/servreg`, path `msm/adsp/charger_pd`) says UP **and**
  the rpmsg channel exists. Then `qcom_battmgr` sends BATTMGR_REQUEST_NOTIFICATION (0x04, type 2)
  [V `qcom_battmgr.c:1587-1612`].
- OnePlus downstream [V `out/src/op-kernel/drivers/soc/qcom/pmic_glink.c:170-195, 547-556`]: the
  PDR UP event does **not** notify the clients; `pmic_glink_init_work` (run after the rpmsg probe =
  the GLINK channel is open) sends `PMIC_GLINK_STATE_UP`. `battery_chg_subsys_up_work` then sends
  BC_SET_NOTIFY_REQ and waits 200 ms before the ICL [V `oplus_battery_sm8450.c:3396-3430`].
- 0274 uses the downstream rule without PDR/QRTR: channel open both ways = up; the first property
  read with `ret_code 0` = READY. No write before READY. After READY: BC_SET_NOTIFY_REQ, a one-time
  dump of battery ids 0..24 and USB ids 0..11 (reads only, to check the id table on this firmware),
  then the ICL and the charging enable. A USB notification (0x07 with 0x32) starts the next cycle
  after 2 s instead of 20 s. A cycle where no read is answered clears READY (writes stop).
- [U] Whether the charger PD starts without an HLOS servreg locator / PD mapper. 0243 step 10 has a
  small servreg locator for audio_pd; if the PMIC channel never opens with `negroniadsp_step=9`, test
  with `negroniadsp_step=10` (QRTR + locator) next.

## 6. NegroniBattery integration

- `bsd/dev/negroni_chg_glink.h`: `negroni_chg_glink_get()` copies the last status (under a mutex).
- NegroniBattery (0274 hunks only for the GLINK state): the status line shows `chg=glink
  icl=NNNNmA` (the PD's USB_INPUT_CURR_LIMIT read back) once the PD is READY, else the 0272 SPMI
  values. Registry: `NegroniChargerGlinkReady`, `NegroniChargerGlinkIclMa`, `NegroniChargerGlinkSOC`,
  `NegroniChargerGlinkStatus`, `NegroniChargerGlinkVbusMv`, `NegroniChargerGlinkChargeEnable`.
- Charger lines (`NEGRONI BATTERY: glink: ...`): `start`, `PMIC_RTR_ADSP_APPS is open`, `the charger
  PD answers ...: READY`, `subscribe to notifications`, `battery properties (id=value/ret): ...`,
  `usb properties ...`, `USB in`, `set the input limit (try N of 5)`, `write USB_INPUT_CURR_LIMIT
  500 mA (uA) = 500000: ok`, `input limit read back: 1500 mA`, `write BATT_CHG_EN = 1: ok`,
  `soc 12.34% (oem gauge; capacity 1234) vbat ... icl 1500 mA ...` (on change, else every 15 cycles
  = 5 min). Errors are bounded (40 lines, then every 100th).
- Threads: the client runs on its own kernel thread, started by `NegroniBattery::start`; it waits up
  to 600 s for GLINK (`negroni_glink_up(IPCRTR)`, ADSP step 9), then logs `glink: GLINK is up after N s`
  or `glink: off: GLINK is not up after 600 s`. No hook in the ADSP thread. GLINK has one recursive lock (regenerated 0242); after the ADSP steps this thread is the only
  one that polls GLINK (every 50 ms while idle), so the audio channels get their RX callbacks from it
  too. A send can block ~1.2 s; NegroniBattery's work loop never waits on GLINK (it reads a copy).

## 7. Cost and risk of `negroniadsp=1`

- The ADSP must be booted by 0240/0241 (steps 1..8: rails, AOP QMP, PAS init/auth with TrustZone,
  carveout load, SMP2P) and GLINK by 0242 (step 9). This is the stage with SoC-reset risk: a DSP
  fault or a second start without a stop-ack can reset the phone [V audio-plan.md "Risks of stage a",
  HackiOS note]. Default off. Since the regenerated 0242/0243 the default last step is 9:
  `negroniadsp=1` alone = GLINK up, no audio (no `negroniadsp_step` needed).
- The ADSP firmware area must be on the device (end of userdata, `NEGRADSP`, docs/audio-plan.md);
  without it step 2 fails and 0274 logs `charger glink: off (GLINK is not up ...)`.
- A running charger PD runs its own policy (JEITA, OPLUS fast charging, VOOCPHY) [I]. The HLOS
  OPLUS algorithm (`oplus_chg_*`, mmi_chg, thermal steps) is absent here: the PD may use its defaults.
- The plug edge counts only in a cycle where a USB read answered (a lost cycle keeps the last state).
- [U] After a remote CLOSE, 0274 re-advertises our RX intents on the re-open; whether the ADSP accepts
  our old lcid without a new OPEN from us is unknown.
- [U] The PD may change the ICL by itself on plug/APSD events. 0274 checks the read-back each cycle
  and writes again (5 ramps per plug).
- [U] Sign of BATT_CURR_NOW / OEM current on this firmware: logged raw, not used for the SoC.
- [U] BATT_VOLT_NOW may be the pack (2S) or the cell: 0274 halves values above 5000 mV only for the
  AICL point; NegroniBattery keeps the VADC voltage.
- 0274 writes only through the PD (no SPMI). With `negroniadsp` set, the 0273 debug path stays read
  only (no double owner).

## 8. Test order (owner approval for each flash)

1. `fastboot boot` the `out/ios16-chg3` boot image (no partition write). The ADSP firmware area must
   be on userdata (audio-plan.md).
2. `make usblog`, `grep "NEGRONI ADSP\|NEGRONI BATTERY"`: step 9 `GLINK UP`, then
   `glink: PMIC_RTR_ADSP_APPS is open`, `READY`, the property dump, `input limit read back`.
3. Check with USB in at idle: `ibat` in the raw line must go clearly positive (> +500 mA) and
   `iin` above 1000 mA when the adapter allows it.
