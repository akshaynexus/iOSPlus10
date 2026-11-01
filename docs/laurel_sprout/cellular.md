# Mi A3 cellular (dual nano-SIM, MPSS.AT.4.3.1 on SM6125)

Goal (owner): SIM detection for both slots, network registration, mobile data and, if reachable, voice/SMS under
iOS 16.7.16 (20H392, iPhone10,3 userland). Status 2026-11-01: step 1 (kernel QMI client: SIM 1/2 status, provisioning,
modem facts; radio kept off by its IPA self-check) [V] booted (boot 20:02: the kernel reads SIM state; iOS saw no SIM, half-done-audit.md row 3). The bridge to iOS and the online fix
(section 9, patch 2786): built + host test, NOT BOOTED. Path decision, data, SMS, voice, Settings, modem restart: section 9. The IPA phone test: section 10.
Status later on 2026-11-01: IPA handshake [V] passes on the phone (boot 22:50); DMS mode 5 blocked ONLINE. Radio online + data (2940-2942, `laurel-celld`): built + host test, NOT BOOTED, data [I] until a phone ping: **section 11, read it first.**

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
| (a) native | kernel QMI client + an `AppleBasebandPCI` stand-in that speaks Apple QMUX to CommCenter | **last / research.** CommCenter needs BBUpdater boot, Apple QMI services and activation [I from §3]; no port did it [V]. Evidence again in section 9.1 |
| (b) bridge daemon | our daemon talks QMI (through the kernel) and feeds iOS (status bar, Settings) | **built 2026-11-01, section 9**: a SpringBoard hook on STTelephonyStateProvider, no daemon. Shape from scion, another layer [V] |
| (c) minimum viable | kernel QMI UIM/NAS/DMS/WDS client; IPA + a data interface | **first (chosen).** Everything stays in the kernel next to TopazModem's QRTR; no iOS daemon needed for SIM/registration/data |

Order: (1) SIM status both slots + modem facts [done, this patch], (2) IPA v4.2 AP side -> radio ONLINE -> registration +
signal, (3) data: WDA/WDS + GSI channels + an iOS interface, then the status-bar bridge (b), (4) SMS (WMS 0x05) and voice
(VOICE 0x09 + audio routing through the ADSP/APR path of 2500) last.

### Why the radio stays off in step 1 [V scion, I for trinket]

scion (same Qualcomm QMI/IPA design, IPA 4.11) saw the modem go ONLINE and crash in `enl2_dl` (LTE L2 downlink) a few
seconds later in every run until the AP IPA handshake passed. Our modem sees the smp2p "ipa" entry (topaz answers 1:
valid, clock off) but nobody sends INIT_MODEM_DRIVER. A modem crash on the Mi A3 also stops Wi-Fi (WLAN firmware runs on
the modem, topaz has no modem restart). Rule: a failure turns off only its feature. So SET_OPERATING_MODE online is gated
by the self-check `ipa_up()` = `laurel_ipa_state()` (AP IPA side done, patch 2780, section 6). SIM status works in low power mode (Android shows SIM
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

## 6. Step 2 as built: IPA v4.2 AP side (patches 2775 + 2780; booted 2026-11-01 17:00: modem crash, section 8; 2782 changes the order below)

### Step 2 facts

| Fact | Value | Source |
| --- | --- | --- |
| IPA firmware PAS id | 15 | [V] trinket.dtsi `qcom,ipa_fws { compatible "qcom,pil-tz-generic"; qcom,pas-id <0xf>; qcom,firmware-name "ipa_fws"; memory-region <&pil_ipa_fw_mem> }`; ipa.c `IPA_SUBSYSTEM_NAME "ipa_fws"`, loaded by `subsystem_get()` = subsys-pil-tz |
| Firmware region | 0x57500000 + 0x10000 (pil_ipa_fw_mem) | [V] hardware-map.md, laurel_sprout-trinket-memory.dtsi |
| Firmware files | vendor `/firmware/ipa_fws.mdt` 7020 = `.b00` 212 (ELF header + 5 phdrs) + `.b01` 6808 (hash); `.b02` 12040, `.b03` 128, `.b04` 320 | [V] test-ipa.sh (ext4 reader = debugfs, byte-equal) |
| Segment layout | phdr 2 PT_LOAD paddr 0 filesz 0x2f08 memsz 0x4000; 3 at 0x4000 (0x80); 4 at 0x4080 (0x140); phdr 1 hash (type 2) at 0x5000 not loaded; all relocatable (flags bit 27) | [V] ELF of ipa_fws.mdt |
| PAS span (mem_setup size) | 0x5000 (page end of 0x4080 + 0x140) | [V] pas_test |
| QMI 0x31 INIT_MODEM_DRIVER TLVs | 0x10 platform 3, 0x11 hdr, 0x12/0x13 v4/v6 route (index hi 7), 0x14/0x15 v4/v6 filter, 0x16 modem mem 0xBF0+0x140C, 0x17 ctrl endpoint 9, 0x19 proc ctx, 0x1F/0x20 quota 0xA50/0x60, 0x21/0x22 drop stats 0xBF0/0; no 0x18 (first boot), no 0x1A (zip size 0), no 0x1B-0x1E (v4.2 tables not hashable) | [V] ipa_qmi_service.c + _v01.c TLV table + ipa_utils.c ipa_4_2_mem_part |
| Init writes | BCR = 0, TX_CFG bit 12 (PA_MASK_EN) cleared, IDLE_INDICATION_CFG = 256 (debounce, const non-idle off), CLKON open, QSB 8/12, COMP_CFG bits 7/8/15, hashing off, resource groups | [V] ipa3_init_hw / ipa3_enable_dcd for IPA_HW_v4_2 |
| Modem's QMI 0x31 service | instance 0x201, node 0, port 0x19, ~270 ms after auth_and_reset | [V] USB log 2026-11-01 07:21 / 07:45 / 08:12 boots |
| SMP2P "ipa" query | not seen in the 08:12 boot (inbound item has 1 entry: slave-kernel) | [V] USB log; answer bits: 0 = response complete, 1 = clock on [V] ipa.c ipa3_freeze_clock_vote_and_notify_modem |

### What runs (laurel_ipa.c)

1. TopazModem's watch thread sees READY + GLINK -> the IPA thread starts: RPM IPA clock 201000 kHz (active + sleep set)
   -> SMMU SIDs 0xE0 (and 0xE2) identity -> registers (`ipa3_init_hw`, read-back check) -> firmware: UFS (60 s
   wait), active slot from the boot_a/boot_b GPT attribute, `vendor_<slot>` then the other, ext4 reader, `.mdt` +
   loadable `.bNN` -> shared PAS loader (2775) PAS 15 -> GSI_STATUS bit 0 within 1 s -> local memory tables (SRAM
   direct window, canary read-back) -> SMEM item 497 (0x2000 bytes).
2. Watch thread: NEW_SERVER 0x31:0x101 at port 0x4015; INIT_MODEM_DRIVER from port 0x4016 to 0x31:0x201; our service
   answers INDICATION_REGISTER, INSTALL_FILTER_RULE (echoes the rule ids), FILTER_INSTALLED_NOTIF, CONFIG,
   INIT_MODEM_DRIVER_CMPLT; MASTER_DRIVER_INIT_COMPLETE goes to the client that registered for indications once
   the INIT_MODEM_DRIVER answer is in (as ipa_qmi_service.c).
3. On = INIT_MODEM_DRIVER answered success + CMPLT received. Then `laurel_ipa_state()` is true and laurel_cell.c sends
   DMS SET_OPERATING_MODE online.
4. Off (one line, no restart, the radio stays low power): ipa=0, any failed step, no service 0x31:201 60 s after the
   hardware, no answer in 30 s, a QMI error, no CMPLT 60 s after the answer, modem crash, watch end, modem=0.
5. SMP2P "ipa" query answer: 3 when the clock vote is acked and the IPA is not off, else 1 (as before). Answered once.

Shared PAS loader (2775, `bsd/dev/topaz_pas.c`): is_supported -> init_image(.mdt in the TopazModem pool) -> mem_setup
(region, span) -> zero region + copy segments at p_paddr - lowest -> auth_and_reset; shutdown only after init_image
passed. All calls through `topaz_scm()` (one lock). Users: zap shader (PAS 13, same log lines as 2153) and IPA (PAS 15).
TopazAudio and the modem loader keep their own code (not switched).

### Expected lines (USB log)

```
LaurelIPA: RPM ipa clock 201000 kHz (active + sleep set): acked
LaurelIPA: IPA_VERSION ........, SHARED_MEM_SIZE ........: 8192 bytes at offset 0x..., IPA_STATE ........
LaurelIPA: registers set: BCR 00000000, TX_CFG ........, COMP_CFG ........, SRC_RSRC_GRP_01_0 00003f03, IDLE_INDICATION_CFG 00000100
LaurelIPA: fw: vendor_b: ipa_fws.mdt 7020 bytes, segments at 0x0-0x5000 (PAS 15, region 57500000+10000)
LaurelIPA: fw: PAS 15 is_supported 0/0 (0 ms), metadata 7020 bytes at 0xe00..000 (modem pool)
LaurelIPA: fw: init_image and mem_setup ok (.. ms), copying the segment
LaurelIPA: fw auth_and_reset: 0/0 (.. ms)
LaurelIPA: local memory set: ROUTE ........, canary deadbeef, empty table e00.....
LaurelIPA: SMEM item 497 allocated, 8192 bytes (modem filter tables)
LaurelIPA: hardware ready in ... ms (IPA_VERSION ........, GSI_STATUS .......1); next: QMI 0x31 with the modem
LaurelIPA: modem QMI service 0x31:201 up at node 0 port 19
LaurelIPA: our QMI service 0x31:101 announced at port 4015
LaurelIPA: sent INIT_MODEM_DRIVER (118 bytes, local memory at 0x...) to node 0 port 19
LaurelIPA: modem answered INIT_MODEM_DRIVER: success (.. ms)
LaurelIPA: modem request 0x20 answered (rules 0, configs 0)
LaurelIPA: sent MASTER_DRIVER_INIT_COMPLETE to the modem's client (node 0 port ..)
LaurelIPA: modem request 0x35 answered (rules 0, configs 0)
LAUREL IPA: on: v4.2 (IPA_VERSION ........), firmware PAS 15, GSI up, modem driver init complete in ... ms, master init indication sent
LaurelCell: radio on: DMS SET_OPERATING_MODE online (was low power)
LAUREL CELL: on: SIM1 present (USIM ready), SIM2 absent; modem online; SIM1 registered ...
```
(The service line can come before the hardware lines: the modem announces 0x31:201 at ~270 ms.) Off examples:
`LAUREL IPA: off: boot-arg ipa=0`, `off: TrustZone refused the IPA firmware: init_image .../...`,
`off: GSI not enabled 1000 ms after the firmware (GSI_STATUS 00000000)`, `off: modem did not answer INIT_MODEM_DRIVER in 30 s`,
`off: modem crashed: <SMEM 421 text>`. While the IPA is not on, the cell line says `radio off: AP IPA side still
starting (...)` or `radio off: AP IPA side off: <reason>`. `sysctl kern.laurel_ipa` has the IPA text.

### Host test [V]

`scripts/laurel/test-ipa.sh` (kernel files taken from the patches): qmi_test (INIT_MODEM_DRIVER bytes for restricted
0 and 0x2000, its answer: success / error / other message / cut TLV, our service: 6 messages, the indication);
pas_test part 1 (synthetic image with the stock layout: order 7-1-2-5, span 0x5000, region and metadata bytes, 6 error
paths: shutdown only after init_image passed); ext4 + pas_test part 2 with `out/ipa-fw/vendor.raw` (stock vendor, raw
ext4; sparse needs simg2img; skipped with a note when absent): 6 files byte-equal to debugfs, `.mdt = .b00 + .b01`,
`lipa_fw_load()` end to end with a simulated TrustZone (metadata = ipa_fws.mdt, region = .b02/.b03/.b04 at
0/0x4000/0x4080). Result 2026-11-01: PASS. `scripts/laurel/test-cell.sh` (2760 + the 2780 laurel_cell.c hunks): 8 of 8.

### Risks [I]

- Modem crash when ONLINE: scion's modem crashed in `enl2_dl` after ONLINE without the AP IPA handshake; with it, a
  wrong INIT_MODEM_DRIVER value or missing AP data pipes (step 3) can still crash the modem. A modem crash stops Wi-Fi
  (WLAN firmware runs on the modem; no modem restart). Test with `ipa=0` as the fallback; `cell=0` also keeps the radio off.
- No GSI channels of our own yet: `ctrl_comm_dest_end_pt` 9 (APPS_WAN_CONS) is announced but no AP pipe consumes it.
- The SMP2P query answer 3 promises a held IPA clock: the vote is never removed.
- The IPA thread writes IPA registers and SRAM while the modem runs (Linux does this before the modem boots).

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
   (Since 2786 the line starts with `part:` while the radio is not online; section 9.)
6. Step 2 (patches 2775 + 2780, kernel only; the IPA firmware comes from the phone's vendor partition, no root change):
   read the `LaurelIPA:` lines and the one `LAUREL IPA:` line. If `on`: the cell line must change to `modem online`
   and later `registered`. Watch for `TopazModem: modem crash reason` within 60 s after ONLINE (then Wi-Fi stops too):
   report the SMEM text; boot again with `ipa=0` (radio stays low power, as step 1).
7. The GPU zap shader now loads through the shared PAS loader: the `TopazGPU: zap ...` lines must be the same as before
   and `LAUREL GPU: on`.
8. Step 2 with 2782: `IPA_TEST=1 scripts/laurel/uefi-image.sh`, then `fastboot boot` (RAM, one boot; section 8).

## 8. The modem assert in the IPA handshake (patch 2782, 2026-11-01)

Phone [V, boot 17:00:47]: all AP steps passed; 105 ms after INIT_MODEM_DRIVER: `ipa_hal.c:6001: ... Failed to initialize GSI
channel: CHID 1 errval 6`; Wi-Fi, cell and IPA off. Without INIT_MODEM_DRIVER [V, ipa=0 boot 17:03, boots of 07:45 + 08:12]: no assert.

**Cause.** [V] GSI 2.2 needs the AP to allocate every channel, the modem's too, and 2780 never did: ipa.c ipa3_post_init "GSI 2.2
requires to allocate all EE GSI channel during device bootup" -> ipa3_alloc_gsi_channel -> gsi_alloc_channel_ee; mainline gsi.c
`modem_alloc = version == IPA_VERSION_4_2`, "hardware quirk". [V] gsi_alloc_channel sends no ALLOCATE on GSI 2.2 (it expects this
step). [V] IPA_4_2 table: pipe 5 Q6_CMD_PROD = channel 1 of EE 1 = the CHID of the assert. [I] This is the cause of this assert: the
firmware is closed, only a boot proves it. [I] errval 6 = GSI_STATUS_INVALID_PARAMS, from the AP's msm_gsi.h enum only.

**Not the cause.** Timing [V]: Android writes /dev/ipa at early-boot; ipa3_qmi_service_init runs from the IPA ready callback, so
INIT_MODEM_DRIVER always comes after post_init; ours: hardware ready at 98 ms, modem's 0x31:201 at 268 ms. `local memory at 0x0` [V]:
SHARED_MEM_SIZE 00000415 = base 0, 8360 bytes; stock adds 8 * base, mainline too. All 13 TLVs = stock values (host test); no hash TLVs is
right (trinket.dtsi qcom,ipa-fltrt-not-hashable); no 0x18 is right (first boot). [U] Android's modem boot moment relative to /dev/ipa.

**Fix (2782).** New order: clock, SMMU, registers, firmware, GSI_STATUS, recheck, channels, local memory, SMEM 497, only then
QMI. Channels (laurel_ipa_gsi.c): table in stock pipe order (10 AP, 5 modem, 2 uC; EE 0 by CH_CMD + context state, others by generic
command + SCRATCH_0 code, polled: no GSI interrupt handler). Self-checks: version + layout + registers again after the firmware, channels
per EE >= 10, ENABLED_PIPES >= 14, code 1 for each channel (stock also accepts 2-6), ERROR_LOG 0, every SRAM word read back, GSI_STATUS
again before NEW_SERVER. A failure: `LAUREL IPA: off: <why>`, no message to the modem, Wi-Fi not touched. Host test: gsi_test, gate_test.

**What no self-check covers (risk that stays).** The modem firmware runs its own IPA + GSI init after INIT_MODEM_DRIVER and asserts on any
error; there is no restart, so Wi-Fi stops for that boot. The AP cannot read the modem's channels. Open points [U]: other modem channels and
the steps after channel init; stock's AP command channel + immediate commands (HDR_INIT_LOCAL, table init) are replaced by SRAM writes;
no AP consumer on pipe 9 (ctrl_comm_dest_end_pt); uC handlers. So **the handshake stays off by default**: uefi-image.sh + shim.sh pass ipa=0.

**Evidence to remove ipa=0.** `IPA_TEST=1` image, `fastboot boot`, 3 boots, each with: `GSI channels allocated: 10 AP, 5 modem, 2 uC`;
`modem answered INIT_MODEM_DRIVER: success`; `LAUREL IPA: on:`; `LAUREL WIFI: on` + Wi-Fi associated; no `modem crash reason` for 10 minutes.
Expected [I], new lines only: `LaurelIPA: after the firmware: IPA_VERSION 0c030300, SHARED_MEM_SIZE 00000415: 8360 bytes at offset 0x0
(same), .. pipes`, `LaurelIPA: GSI channels allocated: ...`, `LaurelIPA: self-check passed, hardware ready in .. ms (...)`.
Off examples: `off: GSI channel 1 of EE 1 (pipe 5): ALLOCATE refused, code 7, GLOB_IRQ .., ERROR_LOG ..`. A new assert text = the next cause.

**Modem restart (design note, not built; why not: section 9.5).** It would make every modem assert cost seconds, not Wi-Fi for the boot: PAS 4 shutdown, SMEM GLINK +
SMP2P reset, QRTR + WLFW state reset, modem load again; stock adds ipa3_q6_pre_shutdown_cleanup + gsi_halt_channel_ee and TLV 0x18 = 1.

**CORRECTION (section 11, boot 22:50): 5 is not only an old value: DMS repeats it for the whole boot. The text below was wrong on that point.**

**`modem shutting down` in the cell line.** [V] The decode is right: only raw 5 gives this text; table = scion hakios.mpss.c:5212; message 0x2D;
TLV 1, the same tlv() reads the revision correctly. [V] It is one old read: GET_OPERATING_MODE runs once, ~450 ms after modem start (and after
SET); no DMS indication is registered; the 17:04:06 line repeats that value. [V] After the read: WLFW up at 730 ms, both USIMs reach ready,
no FATAL. So 5 was the answer then; the modem is not shutting down. [I] 5 and error 0x4a (07:45; [I] info unavailable) are the modem's values
before it has a mode. [V] Bug: laurel_cell.c blocks ONLINE on opmode 5 or < 0 and never reads again, so the radio cannot go ONLINE after
`LAUREL IPA: on`. **Fixed by patch 2786 (section 9.2): read again every 10 s until online.**

## 9. iOS side and the online fix (patch 2786 + `userland/laurel/cell`; 2026-11-01, built + host test, NOT BOOTED)

Evidence commands: `scripts/debug/cell-statusbar-re.sh`, `cell-dis.sh`, `cell-method-list.py` (20H392 iPhone10,3 shared cache, output in `out/re-cell`).

### 9.1 Path decision

**(b) a status bar bridge, now. (c) data next, only after the IPA test. (a) CommCenter stays out.**

| Path | Evidence | Decision |
| --- | --- | --- |
| (a) CommCenter + stand-in `AppleBasebandPCI` + QMI bridge | [V scion `userland/mkjobs.py`, 20 crashes with CommCenter's own log] 11 SIGSEGV after "Could not find AppleIPAppender service", 9 SIGABRT after "Unable to communicate with AppleBaseband driver": a stub of one driver leaves the other crash. [V 20H392] the job needs an ADT `baseband` node (`_LimitLoadToDeviceTree`); links `libBBUpdaterDynamic`, `libQMIParserDynamic`, Apple QMUX over PCIe pipes. [I] Apple QMI extensions, BB update boot and activation have no reference anywhere | Not now. Months, and no partial result on the screen |
| (b) SpringBoard bridge from kernel state | [V 20H392, below] one small layer feeds every telephony reader in SpringBoard; [V scion] a SpringBoard hook on sysctls reached the bar on 16.5 | **Built.** Bars, network name, SIM text. Costs nothing when the radio is off |
| (c) data: `pdp_ip0` or `en1`, IPA + rmnet + WDS | [V] the AP has no GSI rings, no event rings, no endpoint config, no AP command channel: 2782 only allocates channels. The handshake has never run with 2782 | **Next, after the IPA test passes.** Not built. Section 9.4 |

Why not scion's exact hook. Scion replaced `-[SBStatusBarStateAggregator _updateSignalStrengthItem:withData:SIMInfo:barsGetter:barsSetter:]` and forced the item on, forced at least 1 bar, and forced the signal view's mode. On 20H392:

- [V disassembly] the setter block takes `(block, value)`. Scion's call form is `(block, data, value)`: it would write the pointer as the bar count here.
- [V disassembly] the updater turns the item on only with `SIMInfo.cellularServiceState == 2` and capability enabled and not airplane mode, and takes the bars from `SIMInfo.signalStrengthBars`. So the right place is the data, not the updater: then Apple's logic stays true.
- [V] data path: `aggregator.telephonyDomain.data.primarySIMInfo`, published by `STTelephonyStatusDomainDataProvider` (made by the aggregator: `-telephonyDataProvider`), which asks `STTelephonyStateProvider`.
- [V] the provider's `_updateDataForSlot:` and `_SIMInfoForStateProvider:...` are objc_direct (plain `bl`, not in the method list): cannot be replaced. What it calls is real ObjC (`cell-method-list.py`): `subscriptionInfoForSlot:`, `isSIMPresentForSlot:`, `isCellularRadioCapabilityActive`, `isDualSIMEnabled`, `isRadioModuleDead`.
- [V] from those answers Apple's code makes `NO_SIM`, `LOCKED_SIM`, `BAD_SIM`, `NO_SERVICE`, `SEARCHING`, the operator's name, service state. Registration value 2 = in service, 1 = searching, else none [V `_serviceStateForStateProvider:...`].

### 9.2 Kernel: patch 2786 (`bsd/dev/laurel_cell.c`)

| Change | Why |
| --- | --- |
| DMS GET_OPERATING_MODE every 10 s until online, then every 60 s | [V boot 20:02] one read at ~450 ms said 5, blocked ONLINE for the boot |
| No first line while the mode is 4, 5 or unknown (at most 60 s) | The first line said `modem shutting down`: the modem's value before it has a mode [I, section 8] |
| ONLINE: 6 tries, each after the next mode read; then the line says `radio off: modem refused ONLINE 6 times, error 0x..` | [V scion] the modem answers "not ready" while it starts |
| NAS BIND_SUBSCRIPTION: 6 tries, 10 s apart. `nas2` without a binding: no polls, no registration, `SIM2: NAS not bound to this SIM` | [V boot 20:02] `nas1: BIND_SUBSCRIPTION error 0x3`, never asked again. [I] an unbound `nas2` reads the primary subscription: a false SIM2 |
| A NAS error clears old registration and signal | No old bars |
| `part:` instead of `on:` while the radio is not online; the line names data, SMS and voice as off | Audit row 3 |
| `kern.laurel_cell_state`: `state`, `radio`, `data`, `sms`, `voice`, `subN.slot`, `.sim`, `.reg`, `.bars`, `.rat`, `.op` | For the bridge. Written by the watch thread once a second |
| Bars 0-4: only when registered and with a reading. LTE/NR RSRP -115/-105/-95/-85, GSM/WCDMA RSSI -107/-103/-97/-89 [I: Android's thresholds from memory, not in this repo] | Registered and no reading = 0 bars: no fake |
| `kern.laurel_cell_ui` (write): the bridge's line for the USB log, 16 a boot, printable only | [V] syslog does not reach the USB log: `LAUREL NOTCH` has 0 hits in boot 20:02 |

Never in any of these: ICCID, IMSI, IMEI, phone number.

### 9.3 Bridge: `liblaurel-cellbar.dylib`

`userland/laurel/cell/laurel_cellbar.c` + `cellbar_state.h` (parser, also compiled by `test-cell.sh` against the kernel's own text). Build: `scripts/laurel/cell-build.sh` (also in `build-all.sh`). Root: `scripts/laurel/root-cell.sh`, feature `cell` of the table (`CELL=0`; `NOTCH=0` or `STATUSBAR=0` also leave it out: their `laurel-springboard` inserts it). Boot-arg `cell=0`: not inserted.

What it does: hooks the 5 methods above and `initWithServerHandle:stateProvider:`. Every 3 s on the main queue: reads the sysctl; on a change builds two `STMutableTelephonySubscriptionInfo` and calls Apple's `subscriptionInfoDidChangeForStateProvider:slot:` for slots 1, 2. One tick later it reads the published domain back: not equal = `off`, Apple's answers come back. Kernel state `off` (modem crash, `cell=0`): Apple's answers come back. Crash guard: `sb_wrap.c`, 2 fast SpringBoard exits = no dylib for the boot.

| iOS item | State | Source |
| --- | --- | --- |
| Signal bars | Built. Only when the kernel says registered | SIM info `signalStrengthBars`, `cellularServiceState` |
| Network name | Built. On a notched bar: Control Center and the lock screen [I]; the name or MCC-MNC | `operatorName` |
| No SIM / SIM Locked / No Service / Searching | Built, Apple's own text | SIM status + registration |
| Two rows of bars | Built, only when both SIMs are registered. [U] this layout on our 360 pt screen | `isDualSIMEnabled` |
| LTE tag | Off, true: no data path | `dataConnectionType` 0 |
| Settings > Cellular row | **Not built.** [V] the row needs capability `cellular-data` (`PreferencesUI Settings.plist`). [U] the answer on this root: the `on` line prints it. The pane reads CoreTelephony's XPC service = CommCenter: no simple path; empty pane expected [I] | XNUtils > Cellular shows the true state |
| Data, SMS, voice, calls | **Not built, and said so** in the kernel line and XNUtils | - |
| Airplane mode | Not wired to the modem. The bar hides the item [V], the modem stays as it is | Later: DMS low power |

`exec CommCenterMobileHelper` [V job plist]: launchd job started on notify events (`purplebuddy.setupdone`, `ManagedConfiguration.profileListChanged`), no KeepAlive, `EnablePressuredExit`. It is a helper, not CommCenter. [V usblog] 10 `exec` lines in the whole log of many boots, 1 in boot 20:02: no restart loop. Not touched.

### 9.4 Data: the next step (built later: section 11, without the AP command channel, and `pdp_ip0`, not `en1`)

The AP pipes are not reachable today. Order after the IPA test passes: GSI event + transfer rings for the AP's channels; AP command channel (pipe 5 CMD_PROD) + immediate commands (stock does it, 2780 uses SRAM writes); endpoint config + QMAP; WDA SET_DATA_FORMAT; WDS BIND_MUX_DATA_PORT; START_NETWORK + GET_RUNTIME_SETTINGS; an interface. Interface: `en1` with kernel ARP + DHCP answers as scion did [V, not proven by scion on the phone]; `pdp_ip0` is configured by CommCenter [V strings, I]. A data call can also assert the modem, so same rule: test image first.

### 9.5 Modem restart: not built, and why

Asked: "implement if realistic". Blind, it is not. The design is in section 8. What stops it [V code at this commit, `TopazModem.cpp`]:

- The Wi-Fi + modem driver has about 100 file-level state variables, plus function statics (`laurel_wifi_watch`, `radio_poll`). `wlfw_arrive` resets WLFW only: `ce_up`, HTC, WMI, HTT, the station state have no reset.
- `pool_alloc` has no free (16 MiB). CE rings, WMI host memory, HTT, TX, rmtfs would allocate again.
- rmtfs memory goes to `MSS_MSA` + `NAV` by hyp-assign ("the modem owns it from now on"). [V scion] the reverse assign is refused at stop. WLFW MSA and TZ's XPU state after a crash: [U]. A wrong guess is an AP fault, and that breaks the rule "never the boot". Today a crash costs Wi-Fi only.
- SMP2P item has SSR_ACK set; `modem_boot` refuses a modem that is not cold; the restart handshake has never run. WCN3990 and wifid after a restart: [U].
- A host test cannot prove any firmware reaction here. So 300+ lines that first run during a real crash, each try needing a boot.

Risk that stays (**stated**): after `INIT_MODEM_DRIVER` or ONLINE, a modem assert stops Wi-Fi until the next boot. No check can prevent it. It happens only with an `IPA_TEST=1` image. The USB log and user space go on [V usblog: lines after the 17:01 assert]. Do this when the IPA test shows asserts that need many boots, or data work starts.

## 10. Phone test: lines to read

Image and boot are the coordinator's job. Flash path: `scripts/laurel/flash-boot.sh` (`uefi-image.sh` says this ABL refuses `fastboot boot`; section 8 said RAM: use what the last boot used). One or two SIMs in, before the boot. Save the USB log.

### Step A: normal image (`ipa=0`), the bridge and the mode fix. No Wi-Fi risk

```
LAUREL IPA: off: boot-arg ipa=0
LaurelCell: operating mode low power
LAUREL CELL: part: SIM1 present (USIM ready), SIM2 present (USIM ready); modem low power; radio off: AP IPA side off: boot-arg ipa=0; data off: no AP GSI data pipes yet; SMS, voice off: not built
LAUREL CELLBAR: hooks in: waiting for SpringBoard's telephony domain
LAUREL CELLBAR: on: domain follows the kernel: SIM one ready, reg 0, bars 0; MobileGestalt cellular-data N, CellularTelephonyCapability N (the Settings row needs the first)
```

Expected on the screen [I]: `No Service`, no bars, no longer `No SIM`. `LAUREL WIFI: on`, Wi-Fi joins as before. Over SSH: `sysctl kern.laurel_cell_state`, `cat /var/tmp/laurel-cellbar.log`.

| Line | Meaning |
| --- | --- |
| `... modem shutting down; ...` as the final line, 60 s after the start | The modem really stays at 5 ([V] boot 22:50). With 2940 only in an `ipa=0` image; else section 11.6 |
| `LaurelCell: nas1: BIND_SUBSCRIPTION error 0x3`, then nothing wrong | Normal now: asked again, 10 s apart |
| `... SIM2: NAS not bound to this SIM` (only online) | 6 refusals: SIM2 gets no bars, by design |
| `LAUREL CELLBAR: off: no -[...]` or `no CoreTelephony ...` | The build differs from what section 9 read. Apple's bar stays |
| `LAUREL CELLBAR: off: the telephony domain does not hold our state ...` | The layer does not work as read. Apple's bar stays |
| `LAUREL CELLBAR: off: no STTelephonyStatusDomainDataProvider 120 s ...` | SpringBoard did not make it. Apple's bar stays |
| `LAUREL NOTCH: off: SpringBoard exited ...` (in the log file) | Crash guard: a dylib crashed SpringBoard. Boot with `cell=0` to see which |
| No `LAUREL CELLBAR` line | dyld did not load it, or the root has no feature `cell`: see `LAUREL BUILD: root ...` and the manifest |

### Step B: `IPA_TEST=1 scripts/laurel/uefi-image.sh`: the handshake, then the radio

Risk: a modem assert stops Wi-Fi for that one boot. Section 9.5. No fix for that here.

Pass, in this order:

```
LaurelIPA: after the firmware: IPA_VERSION ........, SHARED_MEM_SIZE ........: 8360 bytes at offset 0x0 (same), .. pipes
LaurelIPA: GSI channels allocated: 10 AP, 5 modem, 2 uC
LaurelIPA: self-check passed, hardware ready in .. ms (...)
LaurelIPA: sent INIT_MODEM_DRIVER (118 bytes, local memory at 0x0) to node 0 port 19
LaurelIPA: modem answered INIT_MODEM_DRIVER: success (.. ms)
LAUREL IPA: on: v4.2 (IPA_VERSION ........), firmware PAS 15, GSI up, modem driver init complete in ... ms, master init indication sent
LaurelCell: radio on: DMS SET_OPERATING_MODE online (was low power, try 1)
LaurelCell: DMS SET_OPERATING_MODE online: ok
LaurelCell: operating mode online
LAUREL CELL: on: SIM1 present (USIM ready), ...; modem online; SIM1 registered 404-45 Airtel LTE rssi -71 rsrp -98 bars 2; ...
LAUREL WIFI: on: ...
```
Then 10 minutes with no `TopazModem: modem crash reason`, Wi-Fi joined, bars on the screen. 3 boots like this = the evidence of section 8 to remove `ipa=0`. Not one boot.

Fail, first match:

| Line | Meaning | Wi-Fi | Next |
| --- | --- | --- | --- |
| `LAUREL IPA: off: GSI channel N of EE M (pipe P): ALLOCATE refused, code ...` | AP self-check. No message went to the modem | Stays | Read `code`, `GLOB_IRQ`, `ERROR_LOG`; order or table of 2782 |
| `LAUREL IPA: off: ...` any other step, before `sent INIT_MODEM_DRIVER` | AP self-check, same | Stays | The text names the step |
| `modem crash reason: ...ipa_hal.c:6001...CHID 1 errval 6` | Same assert as 17:01: 2782 is not the cause, or not all of it | Off | Section 8 |
| `modem crash reason:` with **any other text** before `answered` | **The next cause.** Save it word for word | Off | New cause in the IPA init |
| `LAUREL IPA: off: modem refused INIT_MODEM_DRIVER (QMI error N)` | Clean refusal | Stays | A TLV value |
| `LAUREL IPA: off: modem did not answer INIT_MODEM_DRIVER in 30 s` | Modem stuck in its handler [V scion: SMP2P "ipa"] | Stays [I] | `answered IPA power query` line? |
| `LAUREL IPA: off: modem sent no INIT_MODEM_DRIVER_CMPLT in 60 s ...` | Modem's second half stopped | Stays [I] | Which `modem request 0x..` lines came |
| `LAUREL CELL: part: ... radio off: modem refused ONLINE 6 times, error 0x..` | IPA passed, ONLINE not | Stays | 0x34 = not ready: which service does it wait for |
| `modem crash reason:` within seconds after `online: ok`, e.g. `enl2_dl` | Radio needs AP data pipes (scion's crash, but handshake passed) | Off | Section 9.4 comes before ONLINE: gate ONLINE on it. New fact |
| `SIM1 searching` or `not registered`, no crash | Radio works, no network yet. No bars, by design | Stays | Antenna, band, `registration denied` text |

## 11. Radio online + data: patches 2940, 2941, 2942 + `laurel-celld` (2026-11-01, build + host test, NOT BOOTED)

Phone input [V, boot 22:50:54, `logs/laurel-boot-ipa.txt`]: the IPA handshake passes (`modem answered INIT_MODEM_DRIVER: success (21 ms)`, `LAUREL IPA: on`), no modem crash, Wi-Fi on. DMS says 5 for the whole boot, so 2786 never sends ONLINE. **Section 8's claim "5 is only an old value" is wrong.**

Evidence tool: `scripts/debug/modem-re.sh` (stock NON-HLOS to `out/re-modem`, string table; no firmware in git).

### 11.1 Why DMS says "shutting down"

| Question | Result | Label |
| --- | --- | --- |
| Is the modem going down? | No. After the 5: both USIMs reach ready (app state 7), WLFW and Wi-Fi run, the modem serves 42 services, MCFG runs at 7.8 s | [V log] |
| Does an AP path send a shutdown? | No. SMP2P: our item had only the `ipa` entry, not `master-kernel`, so bit 0 ("SMP2P graceful shutdown request" in `sys_m_smsm_mpss.c`) cannot be set. No SSCTL or sysmon client in `TopazModem.cpp` (0x2B is only a name). PIL shutdown only after a failed load | [V code, firmware strings] |
| The sequence of answers | First read error 0x4A (`INFORMATION_UNAVAILABLE`), about 6 ms later raw 5, then 5 until the log ends at 22:52:47 | [V log] |
| What 5 is | DMS maps the mode that CM reports; 5 = CM's `SYS_OPRT_MODE_PWROFF`, CM's start value, kept until a client asks for a mode | [I: Qualcomm enum names from memory; `ds_qmi_dms.c` and `cmph_send_oprt_mode` exist in the firmware, the code is not read] |
| Does the modem wait for an AP service? | Announced by us: pd-mapper, tftp, rmtfs, IPA. All asked requests are answered. Time, thermal, sensors: the modem is the server, the AP the client, so it cannot wait for them. Memshare 0x34 (AP server, not ours): GPS and FTM clients only | [V log, DT] [I for memshare] |
| PDC / MCFG activation? | The modem reads only `mcfg_hw/mbn_hw.dig` and `mcfg_sw/mbn_sw.dig` (32 bytes each) at 7.8 s and no `.mbn` after them: the digests match and the configs in EFS stay. No activation is needed by that reading. If the offline reason (below) says PRI misconfiguration, this changes | [V log] [I] |
| Android's order | qcrild: `DMS SET_EVENT_REPORT`, then low power, then ONLINE on the framework's radio power request | [I from memory: qcrild is closed, not in this repo] |
| Scion's order | OFFLINE boot; ONLINE error 52 (not ready) until tftp + servreg served; low power error 60; ONLINE then works | [V scion docs + `hakios.mpss.c:5311`] |

Conclusion: **unknown until the next boot** whether ONLINE works at 5. Next-boot lines tell: raw mode, offline reason, hardware restricted, and the answer to each request.

### 11.2 What 2940 does

- `radio_step()`: 20 s after DMS came up, 5, 4 or an unknown mode no longer blocks. One round: low power, 2 s, ONLINE, each answer in one line, then a mode read. 6 rounds at most: 10 s after a refusal, 30 s after an `ok` that changes nothing. A refused low power does not stop the round. Mode 1, 6, 7: ONLINE directly.
- The mode line has the raw value, offline reason (TLV 0x10), hardware restricted (TLV 0x11). `DMS SET_EVENT_REPORT` (TLV 0x14): the modem tells changes, the 10 s read stays.
- `DMS GET_CAPABILITIES`: one line `modem radio technologies: ...`, state key `caps=`.
- NAS: `nas1: BIND_SUBSCRIPTION primary: ok (retry N)`. **The 0x3 was not fatal**: [V log] one error line at 400 ms, and 2786 asks again after 10 s; a success had no line, so the log looked like a failure. Error 3 = `INTERNAL`, at the moment UIM starts [I].
- SMP2P `master-kernel` = 0, before `ipa` (stock order, trinket.dtsi `modem_smp2p_out`). Only with the IPA on: an `ipa=0` image stays the image that has Wi-Fi today. [I] it may or may not change the mode.
- State keys: `mode`, `caps`, `subN.plmn`, `subN.ps`, `subN.rsrp`, `subN.rssi`. No ICCID, IMSI, IMEI.

**Radio technology: LTE at most.** [V firmware] `/policyman/device_config.xml`: "open Market DSDS with L+L", `num_sims="2" max_active_voice="1" max_active_data="2"`, `primary="C H G W L T"`: no NR letter; `NR5G*` appears only as 14 task name strings. On the phone: the `modem radio technologies` line [U until the boot].

**DSDS.** [V firmware] L+L dual standby, one voice, config in `mcfg_hw/.../7+7_mode/sr_dsds`. NAS client per subscription: built in 2760 + 2786. Both SIMs in `kern.laurel_cell_state`. Dual standby preference: not sent; the modem's stored value applies [I]. `SET_DUAL_STANDBY_PREF` layout is not in this repo, so no blind request.

### 11.3 What 2941 does: the AP data pipes

`bsd/dev/laurel_ipa_data.c`, thread from `LAUREL IPA: on`, polled, kill switch `cell_data=0`.

| Pipe | GSI channel, event ring | Slots | Values |
| --- | --- | --- | --- |
| 1 APPS_WAN_PROD | 0, 0 | 128 of 2 KB | HDR 0x44, HDR_EXT 1, SEQ 0x806, STATUS 0x15 (status to pipe 10), no aggregation |
| 9 APPS_WAN_CONS | 3, 1 | 64 of 8 KB | HDR 0x2800C4, HDR_EXT 0xB, mask 0xFF000000, AGGR 0x2004D1 (6 KB, 500 us, EOF) |
| 8 APPS_LAN_CONS | 2, 2 | 8 of 8 KB | HDR_EXT 0x800, AGGR 0x4D1: default route; counted and dropped |

Sources: stock `ipa3_ep_mapping[IPA_4_2]`, `rmnet_ipa.c`, `ipa_dp.c`; mainline `ipa_data-v4.2.c`, `gsi.c`, `ipa_endpoint.c`. Decisions: channel scratch stays 0 (stock: no MCS prefetch on 4.2; scion and mainline write it); no AP command channel (tables are in SRAM; `qcom,modem-cfg-emb-pipe-flt`: the modem fills pipe 1's filter table, stock installs no AP rule there [V]); no checksum offload (4-byte QMAP, the stack computes); no status towards the AP. Memory: modem pool, about 1.4 MB. Poll: 1 ms with traffic, 10 ms after 200 quiet polls, 100 ms with no session: cost on a phone [U].

### 11.4 What 2942 does: the session and `pdp_ip0`

1. `laurel_cell_data.c`: DPM OPEN_PORT (embedded, interface 1, pipes 1 and 9), WDA SET_DATA_FORMAT (raw IP, QMAP, 16 packets or 6144 bytes). **These come before ONLINE**, as netmgrd before the RIL [I], at most 30 s. A WDA refusal: data off, radio goes on.
2. One WDS client per family (ports 0x4019, 0x401A): BIND_MUX_DATA_PORT mux 1, SET_IP_FAMILY, START_NETWORK when NAS says registered, GET_CURRENT_SETTINGS. Gaps: 10 s, after 6 tries 60 s. Packet service indication: disconnected = this family goes down, START again.
3. `laurel_pdp.c`: interface `pdp_ip0` (`IFNET_FAMILY_CELLULAR`, `IFT_CELLULAR`, point to point, raw IP, plumbers as `if_utun.c`). The data thread applies addresses by kernel ioctl. `kern.laurel_cell_net`: addresses + DNS.
4. `userland/laurel/cell/laurel_celld.c`: launchd job `com.laurel.celld` (root, `scripts/laurel/celld-job.py`). Publishes `State:/Network/Service/<id>/{IPv4,IPv6,DNS,com.apple.CommCenter}`; IPMonitor chooses the primary service, writes the route and DNS. Key names and Wi-Fi-first ranking: [I] from memory of Apple's configd; the phone test decides.

The data SIM: the modem's default subscription, primary session. Later tasks: `default-SIM` = WDS bind per subscription + NAS dual standby pref; network search = NAS PERFORM_NETWORK_SCAN; SMS, calls = WMS, VOICE clients. Each is one more client in the file pattern above, and state keys carry them to the UI.

The status bar: the bridge reads `kern.laurel_cell_state` as before and shows bars when registered. **Data tag (LTE) stays off:** `setDataConnectionType:` 0: the enum for iOS 16 is not read yet. Settings > Cellular: not built.

### 11.5 What each step risks

A modem assert stops Wi-Fi until the next boot (9.5). The USB log and user space go on [V]. All of these run only without `ipa=0`: only `IPA_TEST=1` images. `uefi-image.sh` keeps `ipa=0`.

| Step | Could assert? | Note |
| --- | --- | --- |
| `master-kernel` entry | [I] unlikely | Stock's state |
| AP pipes | [I] unlikely: AP's own channels; a GSI error is on our EE. Wrong endpoint value: packets dropped | `off:` line on a failed self-check |
| DPM, WDA | [I] unlikely: normal QMI errors | Scion saw errors, no assert |
| Low power at mode 5 | [I] low: `CM denied LPM/Reset/Shutdown cmd` string exists | Error line |
| **ONLINE at mode 5** | **[U], the main risk** | Scion's `enl2_dl` crash came without the handshake; handshake passes here |
| START_NETWORK | **[U]** | First IPA data traffic for this modem |
| First packets | **[U]** | UL filter rules are the modem's |

### 11.6 Test order

1. **Normal image first** (`ipa=0`, no Wi-Fi risk). `LaurelIPA: data: off: AP IPA side off: boot-arg ipa=0`, `LAUREL CELL DATA: off: AP IPA side off: boot-arg ipa=0`, `operating mode shutting down (raw 5, offline reason 0x.., hardware restricted N)`, `modem radio technologies: ...`, `nas1: BIND_SUBSCRIPTION primary: ok`, no `radio on:` line. Wi-Fi joins. Over SSH: `sysctl kern.laurel_cell_state kern.laurel_cell_net`.
2. **`IPA_TEST=1` image, SIMs in, Wi-Fi on.** Expected, in this order:

```
LaurelIPA: data: WAN_PROD: pipe 1, GSI channel 0, event ring 0 started, 128 slots of 2048 bytes at ...
LaurelIPA: data: WAN_CONS: pipe 9, GSI channel 3, event ring 1 started, 64 slots of 8192 bytes at ...
LaurelIPA: data: LAN_CONS: pipe 8, GSI channel 2, event ring 2 started, 8 slots of 8192 bytes at ...
LaurelIPA: data: ready: 3 pipes up, waiting for a data session
LaurelData: DPM OPEN_PORT (pipes 1, 9): ok 0x0
LaurelData: WDA SET_DATA_FORMAT: ok 0x0: link 2, up 5, down 5 (2 raw IP, 5 QMAP), down limit .. packets .. bytes
LaurelData: ipv4: BIND_MUX_DATA_PORT mux 1: ok 0x0
LaurelCell: radio on: DMS SET_OPERATING_MODE low power (reported shutting down, round 1)
LaurelCell: DMS SET_OPERATING_MODE low power: ok 0x0 (reported shutting down, round 1 of 6)
LaurelCell: operating mode low power (raw 1, offline reason 0x0, hardware restricted 0)
LaurelCell: radio on: DMS SET_OPERATING_MODE online (reported low power, round 1)
LaurelCell: DMS SET_OPERATING_MODE online: ok (reported low power, round 1 of 6)
LaurelCell: operating mode online (raw 0, ...)
LAUREL CELL: on: SIM1 present (USIM ready), SIM2 present (USIM ready); modem online; SIM1 registered ... LTE rssi .. rsrp .. bars N; SIM2 registered ...; data off: session not up yet; SMS, voice off: not built
LaurelData: ipv4: START_NETWORK (default profile, try 1)
LaurelData: ipv4: START_NETWORK: connected (ok 0x0)
LaurelData: ipv4: address a.b.c.d mask ... gateway ... mtu ...
LaurelData: interface pdp_ip0 attached (cellular, raw IP)
LaurelData: pdp_ip0: IPv4 address set (error 0)
LAUREL CELL DATA: on: pdp_ip0 IPv4, mux 1; the phone's ping proves it, not this line
LAUREL CELLBAR: celld: configd has: pdp_ip0 IPv4
```
   The first lines of step 2 can come in another order (the threads are independent); `LaurelData: WDA` always comes before `radio on`.
3. Bars on the screen. Over SSH: `ifconfig pdp_ip0`, `netstat -rn`, `ping -S <pdp_ip0 address> 8.8.8.8`: **the first real data proof.** Then Wi-Fi off in Settings: `LAUREL CELLBAR: celld: primary interface pdp_ip0`, a page in Safari, Siri. Wi-Fi on again: primary back to `en0`.
4. 3 clean boots with `no modem crash` for 10 minutes: only then `ipa=0` goes (section 8).

| Line | Meaning | Next |
| --- | --- | --- |
| `low power: error 0x3c`, then `online: ok` | As scion: normal | Read the next mode line |
| `online: error 0x34`, 6 rounds | Modem not ready: says which service? Offline reason in the mode line | Offline reason, hardware restricted |
| `modem answered ONLINE ok 6 times and stays in this mode` | The modem takes the request and does nothing. New fact | Report the mode line |
| `hardware restricted 1` | RF calibration or thermal state [I] | No radio from AP code |
| `modem crash reason:` after ONLINE | Save the text word for word. Wi-Fi off for the boot | Boot normal image |
| `modem crash reason:` after `START_NETWORK` or on first packets | Data values | Report which line was last |
| `WDA SET_DATA_FORMAT: error 0x46` and data off | Port not known: did DPM answer `ok`? | Read the DPM line |
| `START_NETWORK: error 0xe, call end reason N, verbose M` | Network or APN refused; profile 1 APN `""` was read in boot 22:50 | Telephone APN: boot-arg or profile write comes next |
| `primary interface` stays `none` with Wi-Fi off | IPMonitor did not take the keys | Dump `scutil` over SSH |

Host tests [V]: `scripts/laurel/test-cell.sh` 23 of 23 (`mode stays 5`: 6 bounded rounds; low power refused; all refused; indication; session; v6 refused; WDA refused; crash; `cell_data=0`; the daemon's parser on the kernel's text). `scripts/laurel/test-ipa.sh` PASS with `data_test` (register values against the sources, RX frames, cut frame, ring wrap, TX, full ring, kill switch). They do not prove any firmware or hardware answer.
