# Mi A3 cellular (dual nano-SIM, MPSS.AT.4.3.1 on SM6125)

Goal (owner): SIM detection for both slots, network registration, mobile data and, if reachable, voice/SMS under
iOS 16.7.16 (20H392, iPhone10,3 userland). Status 2026-11-01: step 1 (kernel QMI client: SIM 1/2 status, provisioning,
modem facts; radio kept off by its IPA self-check) [V] builds on laurel-int-1, [V] host test 8/8, [U] not booted.

Labels: [V] read in source, measured on the host, or in the 20H392 root; [I] inference; [U] unknown.
Kernel patch: `patches/laurel/xnu/2760-laurel-cellular-qmi.patch` (new `bsd/dev/laurel_cell.c` + hooks in TopazModem.cpp).
Host test: `scripts/laurel/test-cell.sh` (source `tools/laurel-cell-test/`).

## 1. The Mi A3 modem interfaces (4.14 kernel, Android)

Sources: `external/laurel-kernel-oss/arch/arm64/boot/dts/qcom/trinket.dtsi` (DTo), the LineageOS copy (DTl), the
sm6125-common / laurel device trees.

| Item | Value | Source |
| --- | --- | --- |
| Modem PIL | `qcom,mss@6080000`, pil-tz-generic, PAS 4, pil_modem_mem 0x4b000000+0x7e00000, smem-id 421, sysmon 0, ssctl 0x12 | [V] DTo:1191-1233 |
| Modem smp2p | SMEM 435 in / 428 out, SPI 70, APCS bit 14; entries "slave-kernel", **"ipa" in + out** (`smp2p_ipa_1_out/in`), "wlan" | [V] DTo:1869-1904 |
| GLINK edge "mpss" | SMEM transport, APCS bit 12, SPI 68; channels **IPCRTR** (QRTR: all QMI), DS, fastrpcglink-apps-dsp, glink_ssr; glinkpkt DATA40_CNTL, DATA1/4/11 | [V] DTo:1658-1691, 1819-1856 |
| BAM-DMUX / rmnet_ctl | none | [V] DTo |
| QMI in the kernel | QRTR + qmi_interface.c; only IPA 0x31, WDA 0x1A, DFC 0x4E, SSCTL 0x2B, servreg 0x40/0x42, memshare 0x34, WLFW 0x45. **No NAS/WDS/DMS/UIM**: on Android they live in user space (qcrild, netmgrd) | [V] laurel-kernel-los drivers/soc/qcom, drivers/platform/msm/ipa |
| IPA | `qcom,ipa@5800000` (0x34000) + GSI 0x5804000 (0x2c000), SPI 257 ipa / 259 gsi, **`qcom,ipa-hw-ver = <16>` = IPA_HW_v4_2**, ee 0, `qcom,modem-cfg-emb-pipe-flt`, clock RPM_SMD_IPA_CLK, SMMU SIDs 0xE0 (AP, IOVA 0x10000000+0x30000000, IMEM 0x0c123000+0x2000), 0xE1 (WLAN), 0xE2 (uC) | [V] DTo:2380-2464, msm_ipa.h:849 |
| IPA firmware | `qcom,ipa_fws` PAS **15**, region ipa_fw 0x57500000 (0x10000) + ipa_gsi 0x57510000 (0x5000); files `ipa_fws.mdt/.b00-.b04` are in **vendor.img** `/vendor/firmware/`, not in NON-HLOS | [V] DTo:2466-2472, laurel_sprout-trinket-memory.dtsi:25-31, `7z l vendor.img` |
| rmnet | `qcom,rmnet-ipa` compatible "qcom,rmnet-ipa3" (ssr, napi, sg); `CONFIG_IPA3=y`, `CONFIG_RMNET_IPA3=y`, QRTR, RMNET | [V] DTo:2372-2378, trinket-perf_defconfig:254-618 |
| IPA QMI 0x31 | AP serves instance 1, modem instance 2; the AP sends INIT_MODEM_DRIVER when the modem's service arrives (60 s timeout), then MASTER_DRIVER_INIT_COMPLETE; the AP answers INIT_MODEM_DRIVER_CMPLT, CONFIG, INDICATION_REGISTER | [V] ipa_qmi_service.c:33-36, 515, 672-699, 1573, 1655, 1729-1759 |
| IPA clock query | modem raises smp2p "ipa" in; AP answers bit0 = answer valid, bit1 = IPA clock voted | [V] ipa.c:6038-6042, 8649 |
| SIM detect | **no** sim/uim/sim-detect nodes in any AP DT: card detect is the modem's own (UIM hot swap in MPSS) | [V] DTo, laurel_sprout DT |
| Dual SIM | `persist.radio.multisim.config=dsds`, `ro.telephony.default_network=22,22`; netmgrd + ipacm + qcrild | [V] sm6125-common-los vendor.prop:194, 207; proprietary-files.txt:572-608 |
| Mainline (6.18) | MPSS boots (`qcom,sm6125-mpss-pas`), **IPA not added**, telephony not done; mainline `ipa_data-v4.2.c` exists only for sc7180 | [V] laurel-mainline Documentation/android/MODEM.md:26-64, drivers/net/ipa/ipa_main.c:649 |

QMI over QRTR has no QMI_CTL: each client is its own QRTR port, and the modem's name server broadcasts NEW_SERVER for
every service after HELLO [V topaz 0118/0121; hackios-scion saw 88 announcements incl. DMS 2, NAS 3, UIM 11, WDS 1].

## 2. What other ports did

| Port | Cellular | Source |
| --- | --- | --- |
| ios-topaz, ios-sweet, ios-redfin, ios-apollo, topaz-evergo | none. `tools/sweet-root-tweaks.py` **drops CommCenter**: "no baseband: it crash-loops and Setup blocks on its CoreTelephony XPC" (topaz :12-14, code :67-71; apollo :134-138). topaz answers smp2p "ipa" = 1 ("valid, AP IPA power off"): unanswered, modem_cfg starves | [V] |
| ios-apollo | NOTES.md:684: put `CommCenter-noncellular` back (SBTelephonyManager polls it every second); README:95 SIM "not started" | [V] |
| **hackios-scion** (SM7325, iOS 16.5) | the only real stack: `drivers/modem/hakios.{qmi,mpss,nas,ipa,cell}.c`. Modem boot + rmtfs/servreg/tftp -> 88 services; DMS online refused until tftp/servreg served; **ONLINE without the AP IPA side: modem crash in `enl2_dl` seconds later (runs 23-28)**; IPA handshake passed with smp2p "ipa" = 3 (valid + clock on), platform_type 3, SMEM item 497, rule_id at offset 168; UIM GET_CARD_STATUS 0x2F, SWITCH_SLOT 0x46, CHANGE_PROVISIONING_SESSION 0x38 (primary GW was 0xFFFF until set; a "detected" USIM must be provisioned too); signal -83 dBm UMTS, no registration yet; data: 4 GSI channels, WDA SET_DATA_FORMAT, WDS BIND_MUX, an `en1` Ethernet interface with kernel ARP/DHCP answers (not pdp_ip0); status bar from a SpringBoard hook driven by sysctls (`_updateSignalStrengthItem:...`) | [V] hackios-scion/docs/ru/cellular.md:100-314 |
| ios-flame, UniXNU, slop, hackios-xnu-*, sweet-umi | nothing | [V] grep |
| this repo (negroni) | 0397 boots the modem for GNSS only (never ONLINE); plan.md TODO "cellular" | [V] |

## 3. What iOS CommCenter needs (20H392, iPhone10,3)

Read from the laurel root image (`7z x laurel-ios16-root.img`, CommCenter 24.7 MB) and `~/op10-apple/d22ap.adt` [V]:

- D22 (iPhone10,3) = **Qualcomm MDM9655 "mav17" over PCIe** (ADT `baseband-chipset` mav17, `baseband-pcie` on apcie). The
  Intel model is iPhone10,6.
- launchd: `com.apple.CommCenter.plist` has `_LimitLoadToDeviceTree: baseband`; `CommCenter-noncellular.plist` has
  `_LimitLoadFromDeviceTree: baseband` (runs when the ADT has no `baseband` node). Both are dropped by topaz's tweaks.
- IOKit classes CommCenter matches: **`AppleBasebandPCI`, `AppleBasebandPCIControl`** (Qualcomm/PCIe), `AppleConvergedIPCICEBB`,
  `AppleConvergedIPCICEBBControl` (Intel ICE), `IOAppleConvergedIPCBBUserClient`, `AppleIPAppenderIPCInterface*`
  (data appender); method `AppleBasebandConnectMethodNotifyBasebandPoweringDown`. Entitlements
  `com.apple.driver.AppleBasebandPCI.user-access`, `com.apple.driver.AppleBasebandPCIControl.user-access`.
- Libraries: `libQMIParserDynamic.dylib` (Qualcomm QMI), `libARI.dylib` (Intel), `libBBUpdaterDynamic.dylib` (baseband
  firmware boot/update), `AppleBasebandManager.framework`, `AppleBasebandServices.framework`, `libTelephonyIOKitDynamic`;
  capabilities `supportsUnifiedQmux` / `supportsUnifiedQmuxV2` (QMUX over the PCIe pipes).
- Data interfaces: `pdp_ip0..pdp_ip15`, per SIM ("Cellular WAN: pdp_ip%d: SIM %u").
- scion's measurement: without the kext, CommCenter-noncellular segfaults after "Could not find AppleIPAppender service",
  CommCenter aborts after "Unable to communicate with AppleBaseband driver" [V hackios-scion userland/mkjobs.py:69-87].

[I] Apple's QMUX is QMI framing over Apple's PCIe pipes, plus Apple-only services and a BBUpdater boot (firmware
personalisation, activation tickets) that the Mi A3 modem does not have. A full AppleBasebandPCI emulation means faking
the BBU boot handshake and the Apple QMI extensions: months, with no reference.

## 4. Path decision

| Path | What | Verdict |
| --- | --- | --- |
| (a) native | kernel QMI client + an `AppleBasebandPCI` stand-in that speaks Apple QMUX to CommCenter | **last / research.** CommCenter needs BBUpdater boot, Apple QMI services and activation [I from §3]; no port did it [V] |
| (b) bridge daemon | our daemon talks QMI (through the kernel) and feeds iOS (status bar, Settings) | **step 3.** Proven shape: scion's SpringBoard hook driven by sysctls [V] |
| (c) minimum viable | kernel QMI UIM/NAS/DMS/WDS client; IPA + a data interface | **first (chosen).** Everything stays in the kernel next to TopazModem's QRTR; no iOS daemon needed for SIM/registration/data |

Order: (1) SIM status both slots + modem facts [done, this patch], (2) IPA v4.2 AP side -> radio ONLINE -> registration +
signal, (3) data: WDA/WDS + GSI channels + an iOS interface, then the status-bar bridge (b), (4) SMS (WMS 0x05) and voice
(VOICE 0x09 + audio routing through the ADSP/APR path of 2500) last.

### Why the radio stays off in step 1 [V scion, I for trinket]

scion (same Qualcomm QMI/IPA design, IPA 4.11) saw the modem go ONLINE and crash in `enl2_dl` (LTE L2 downlink) a few
seconds later in every run until the AP IPA handshake passed. Our modem sees the smp2p "ipa" entry (topaz answers 1:
valid, clock off) but nobody sends INIT_MODEM_DRIVER. A modem crash on the Mi A3 also stops Wi-Fi (WLAN firmware runs on
the modem, topaz has no modem restart). Rule: a failure turns off only its feature. So SET_OPERATING_MODE online is gated
by the self-check `ipa_up` (AP IPA side done), false until step 2. SIM status works in low power mode (Android shows SIM
data in airplane mode = low power) [I].

## 5. Step 1 as built (patch 2760)

`bsd/dev/laurel_cell.c`, called from TopazModem's modem watch thread (one thread: no locks except the sysctl text):

| Client | QRTR port | Messages |
| --- | --- | --- |
| UIM 0x0B | 0x4010 | REGISTER_EVENTS 0x2E (card status), GET_CARD_STATUS 0x2F, indication 0x32 (hot swap), CHANGE_PROVISIONING_SESSION 0x38 |
| NAS 0x03 primary | 0x4011 | BIND_SUBSCRIPTION 0x45 (primary), then when online: GET_SERVING_SYSTEM 0x24 + GET_SIGNAL_INFO 0x4F every 10 s |
| NAS 0x03 secondary | 0x4012 | the same, bound to the secondary subscription (DSDS) |
| DMS 0x02 | 0x4013 | GET_REVISION 0x23, GET_OPERATING_MODE 0x2D, SET_OPERATING_MODE 0x2E online (only with `ipa_up`) |
| WDS 0x01 | 0x4014 | GET_PROFILE_SETTINGS 0x2B (3GPP profile 1: APN). START_NETWORK not sent |

- Ports 0x4010-0x4014: below TopazModem's tftp session ports (0x4100-0x140FF); pd-mapper 0x4001, tftp 0x4002, rmtfs
  0x4003, WLFW client 0x4004 [V TopazModem.cpp].
- Message ids and TLV layouts: libqmi `qmi-service-{uim,nas,dms,wds}.json` [V knowledge of libqmi; not in a local clone];
  NAS BIND_SUBSCRIPTION 0x45 from Qualcomm's NAS IDL [I]: sent with a 1-byte enum, again with 4 bytes on MALFORMED or
  INVALID_ARG; a single-SIM config answers INVALID_QMI_CMD (then the default subscription is used).
- Card status index: upper byte = slot (0-based), lower byte = application [I, libqmi]. Provisioning (as qcrild,
  ModemManager, scion): only when the modem did not provision itself; first present card -> primary GW session, second
  -> secondary GW session; USIM before SIM; any app state except "illegal" (a "detected" USIM too, scion run 37);
  2 tries per card, reset when the card leaves.
- Requests: one at a time per client, matched by message id + txn, 10 s timeout, 2 tries.
- Failures -> `off`: cell=0, modem=0, SoC map, PAS boot, SMP2P item, GLINK, modem crash, watch end (`modem_watch=N`),
  modem not READY in 90 s, no UIM service 60 s after READY, UIM GET_CARD_STATUS error or no answer. The modem, Wi-Fi,
  USB and the boot are never touched by this file.
- Privacy: ICCID, IMSI and IMEI are never read or logged.
- `sysctl kern.laurel_cell`: the same text as the line, with the live signal.

### Expected lines (USB log)

```
TopazModem: t=... ms: service b:101 port .. uim          (also 3 nas, 2 dms, 1 wds)
LaurelCell: uim: service b:101 at node 0 port .., our port 4010
LaurelCell: modem revision MPSS.AT.4.3.1.c1-00047-...
LaurelCell: card status: SIM1 card 1 app USIM/7, SIM2 card 0 app -/0, GW primary ffff secondary ffff
LaurelCell: SIM1: activate primary GW provisioning session (USIM, try 1)
LaurelCell: operating mode low power
LaurelCell: WDS: 3GPP profile 1 APN "..."; START_NETWORK not sent (no IPA/GSI data path in this kernel)
LAUREL CELL: on: SIM1 present (USIM ready), SIM2 absent; modem low power; radio off: no AP IPA driver yet (QMI 0x31 INIT_MODEM_DRIVER): ONLINE without it can crash the modem and with it Wi-Fi; data off (no IPA path; APN "...")
```

Off examples: `LAUREL CELL: off: boot-arg cell=0`, `off: modem up, no QMI UIM service in 60 s (N QRTR services)`,
`off: modem crashed: <SMEM 421 text>`, `off: UIM service does not answer (message 0x2f, 2 tries)`.
After step 2 (radio on): `... modem online; SIM1 registered 404-45 Airtel LTE rssi -71 rsrp -98`. A new line comes on a
change of SIM, registration, PLMN or radio (at most every 10 s), not on a signal change.

### Host test [V]

`scripts/laurel/test-cell.sh`: compiles `laurel_cell.c` taken from the patch with stub headers and a simulated modem
(libqmi TLV layouts). 8 scenarios, each in its own process: one SIM in low power (provisioning slot 1 -> primary, no
SET_OPERATING_MODE, sysctl text), dual SIM (slot 2 -> secondary, NAS needs the 4-byte enum), IPA forced up (slot 2 ->
primary, online, `registered 404-45 Airtel LTE rssi -71 rsrp -98`, then hot swap out), no UIM service, UIM silent, cell=0,
modem never READY (no second line after a crash), no SIM. Result 2026-11-01: 8 of 8 pass. It found two bugs before the
first boot (the first line came before provisioning, and before the first signal answer).

## 6. Step 2: IPA v4.2 AP side (next) [I plan]

1. RPM vote for RPM_SMD_IPA_CLK (TopazRpm `topaz_rpm_write`, "clk2"/"ipa" key "KHz" [U exact resource]); smp2p "ipa" answer
   3 (valid + clock on) when the clock is voted.
2. IPA firmware PAS 15 (`ipa_fws.mdt`) from the phone's `vendor_b` (ext4: needs a small ext4 reader, or the files copied
   into the iOS root by a root script) through `topaz_scm()` only.
3. SMMU: stream 0xE0 (and 0xE2) identity through `topaz_smmu_identity` (one lock, 2404); IPA memory init with the v4.2
   partition table of `ipa_v3/ipa_utils.c` (`ipa_4_2_mem_part` [U name]); SMEM item 497 (filter tables) only when the IPA
   is up (scion: the item without a working IPA crashed the modem).
4. QMI 0x31: our server (instance 1) + client of the modem's (instance 2): INIT_MODEM_DRIVER with the v4.2 layout and
   platform_type of the downstream driver; answer INIT_MODEM_DRIVER_CMPLT, CONFIG, INSTALL_FILTER_RULE(_EX),
   FILTER_INSTALLED_NOTIF; then `ipa_up = true` -> SET_OPERATING_MODE online -> NAS registration + signal.
5. Self-check of every step, one line `LAUREL IPA: on|off: ...`; IPA off = radio stays off, Wi-Fi untouched.

Step 3 (data): WDA SET_DATA_FORMAT (QMAP, embedded endpoint), WDS BIND_MUX_DATA_PORT, GSI channels for the
modem<->AP endpoints, WDS START_NETWORK + GET_RUNTIME_SETTINGS, and an iOS interface. scion used an `en1` Ethernet
interface with kernel ARP/DHCP answers because iOS configures pdp_ip only through CommCenter [V scion; I for iOS].

## 7. Test steps (owner, after the next combined boot image)

1. No root change is needed for step 1 (kernel only). Build the kernel (`scripts/bg.sh laurel-kernel
   scripts/laurel/kernel-linux.sh`) and the boot image as usual; `fastboot boot` (RAM).
2. Insert one or two nano-SIMs before the boot. Read the USB log: `LaurelCell:` lines and the one `LAUREL CELL:` line.
3. Wi-Fi must behave as before: `LAUREL WIFI: on: ...`; no `TopazModem: modem crash reason` line.
4. Over SSH: `sysctl kern.laurel_cell`. Hot swap: pull a SIM tray: a new `LAUREL CELL: on:` line with `SIM? absent`.
5. If `off: modem up, no QMI UIM service`: the `TopazModem: service ...` list at 3 s / 20 s (glink_summary) shows what the
   modem announced.
