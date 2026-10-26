# Wi-Fi kernel changes (0260-0269)

Plan, hardware facts and stages: [docs/wifi-plan.md](../../docs/wifi-plan.md).

## 0260-negroni-wlan-pcie-inventory.patch

File: `bsd/dev/negroni_wifi.c` (the slop survey: 0106 steps 1-4, 0109 cmd-db, 0120 PCIe link
steps 5-9, 0122 RPMh supply votes). Made in `out/kernel/wt-wifi` (branch `wifi`) with
`git diff base -- bsd/dev/negroni_wifi.c`.

- New step 10 `step_pci_caps`: reads the endpoint's command/status (0x04), BAR0 (0x10) and walks
  the capability list (pointer 0x34; ID 0x05 MSI, 0x11 MSI-X). It prints `NEGRONI WIFI: 10 ...`.
  It only reads (`rd`); it writes no config register, assigns no BAR and enables no vector.
- It runs only after step 9 found 17cb:1103 (step 9 returns false on another ID, the loop stops).
- New boot-arg `negroniwlan=1` (default 0): runs steps 1..10. Same as `negroniwifi=10`. The Volume
  Up probe menu (`negroni_keys.c`, max 4 Wi-Fi steps) still wins when it runs.
- The normal config keeps `negroniwifi=4` (steps 1-4 read only, `config/negroni-ne2211.toml`).

Risk: `negroniwlan=1` runs the existing write steps 5-8 (GCC GDSC and clocks, five RPMh supply
votes, WLAN_EN high, PCIe PHY + root port + iATU, PERST release, link training). These steps have
never run on a phone [V: no `NEGRONI WIFI` line in `logs/usblog-*.txt`; slop NOTES:805 "no
supply/link/chip response tested"]. Ask the owner before the first boot with it.

Expected log on success: `NEGRONI WIFI: 8 link UP`, `NEGRONI WIFI: 9 bus 1 device 17cb:1103`,
`NEGRONI WIFI: 10 BAR0 ...`, `NEGRONI WIFI: 10 interrupt inventory: MSI present, ...`, badge
`WIFI OK 10`.

Build: applies on `base` in name order with all committed `patches/xnu/0*.patch` and links in
the local Xcode 15.4 kernel build (see `docs/reviews/codex-2026-10-25.md`). Not run on the phone.

### Phone test 2026-10-25 and the 0260 change (regenerated 2026-10-25)

Photo of the panel (survey to step 10, GPU kept on) [V]: `7 PHY PCS_STATUS1 0x86 (ready), pipe 0`,
`8 link up: LNKSTA 0xffff (gen 15 x63), LTSSM 0x180`, `9 bus 1 device ffff:ffff, class 0xffffff,
BAR0 0xffffffff`, `done (asked 10)`. Step 9 stopped (the ID is not 17cb:1103), so 0261 did not start.

- [V] "link up" was false: the root port's LNKCTL/LNKSTA read (DBI + 0x80) returned 0xffffffff, and
  bit 29 of all-ones looks like DLLLA. PARF_LTSSM 0x180 = LTSSM_EN (bit 8) + state 0 (DETECT_QUIET,
  pci-msm.c mask 0x3f) [I: bit 7 unknown].
- Change: step 8 treats a 0xffffffff LNKSTA as "link DOWN (DBI does not answer)" and stops; it prints
  the LTSSM state (`state 0x..`). Step 9 treats a 0xffffffff ID as "no answer" and clears `linked`, so
  step 10 and `negroni_wifi_pcie_handles` (0261) cannot run.
- New log lines: `NEGRONI WIFI: 8 link DOWN: the root port's LNKSTA reads 0xffffffff (DBI does not
  answer), LTSSM 0x.. (state 0x..)`, `NEGRONI WIFI: 8 link UP|DOWN: LNKSTA ... (state 0x..)`,
  `NEGRONI WIFI: 9 stop: bus 1 config space reads 0xffffffff (no answer: no link)`.
- The GCC (2 MiB) and TLMM (840 KiB) maps of the survey moved to `ml_io_map_unmappable` in patch
  0290 (io_submap budget, notes.md "io_submap").
- Why the DBI does not answer and the chip is not detected: notes.md section 16 (part 2, open).

## 0262-negroni-wlan-power-up.patch

File: `bsd/dev/negroni_wifi.c` only (survey steps 4, 6, 7, 8; slop lines, changed in our patch).
Made in `out/kernel/tree-wifi2` (patched-tree.sh, commit after 0261). Sources: the phone's kernel
(out/src/op-kernel e9da592: `drivers/pci/controller/pci-msm.c`, `cnss2/power.c`, `cnss2/pci.c`),
`out/live.dts`, the vendor `waipio-pcie.dtsi`, Linux `pcie-qcom.c`, `pinctrl-sm8450.c`, `gcc-sm8450.c`.
It runs only in the opt-in write steps (`negroniwifi>=6` or `negroniwlan>=1`); the default
`negroniwifi=4` gets only one more read line in step 4.

| Step | Change | Source |
|---|---|---|
| 4 | also prints PARF DBI base (0x350/0x354), slave space size (0x358/0x35c), ATU base (0x634/0x638) as ABL left them; PARF/PHY mapped once (step 7 reuses them) | read only |
| 6 | GPIO95 CLKREQ# -> function 1 `pcie0_clkreqn`, 2 mA, pull-up | live.dts `pcie0_clkreq_default`, pinctrl-sm8450.c PINGROUP(95) |
| 6 | BT_EN (GPIO81) low -> 100 ms before WLAN_EN | cnss2 power.c `cnss_select_pinctrl_enable` |
| 6 | XO_CLK GPIO204 high, 200 us, WLAN_EN high, 1 ms + 5 ms, XO_CLK low (eGPIO pin: bit 12 claims it for the TLMM) | cnss2 power.c:819-904 `cnss_set_xo_clk_gpio_state`, live.dts `qcom,xo-clk-gpio` |
| 7 | DBI/iATU decode, recipe 0 (default, vendor): after the core BCR, PARF 0x350 = 0, 0x358 = 0x4000000, ATU base untouched; recipe 1 (`negroniwifi_dbi=1`, Linux): DBI 0x60000000, ATU 0x60001000, 0x358 = 0, 0x35c = 0x80000000 | pci-msm.c:4394/4422 + DT `qcom,slv-addr-space-size`; pcie-qcom.c:440-465 |
| 7 | after the PHY: reads the root port DBI ID, LNKCAP, ELBI SYS_STTS; ID 0xffffffff -> stop | pci-msm.c reads LNKCAP before PERST |
| 8 | LNKCTL2 target speed Gen2 (2.5/5 GT/s) | cnss2 pci.c `cnss_pci_enumerate` (QCA6490 "link issues if it boots up with Gen3") |
| 8 | link = LNKSTA DLLLA and ELBI XMLH_LINK_UP; up to `negroniwifi_tries` (default 3, 1..10) tries: PERST low + LTSSM_EN off, 100 ms, PERST high, 1 ms, LTSSM_EN, 1 s wait | pci-msm.c `msm_pcie_link_train`, cnss2 LINK_TRAINING_RETRY_MAX_TIMES 3 |

Why recipe 0 is the default [V source, I effect]: it is what the phone's own kernel does after the
core reset (the same BCR the survey pulses in step 7), so the reset value of the ATU base is the one
the vendor uses with its iATU at 0x60001000. The 0120 code wrote Linux's DBI/ATU addresses without
Linux's slave-space size; then the DBI is not decoded, which matches the photo (all reads
0xffffffff). If recipe 0 still reads 0xffffffff at step 7, boot once with `negroniwifi_dbi=1`.

New log lines (`NEGRONI WIFI:`):
- `4 PARF DBI base H:L, slave space H:L, ATU base H:L` (only when CFG AHB runs at step 4)
- `6 CLKREQ GPIO95 cfg 0x.. (function 1, pull-up), PERST low, WLAN_EN low`
- `6 BT_EN is low: wait 100 ms before WLAN_EN (cnss2 PMU sequencing)`
- `6 XO_CLK GPIO204 pulsed around WLAN_EN (cfg 0x..)`
- `6 WLAN_EN out 1, PERST out 0, XO_CLK out 0, SW_CTRL in N, BT_EN in N, CLKREQ in N`
- `7 vendor|Linux recipe (negroniwifi_dbi=N): DBI base .., slave space .., ATU base ..`
- `7 root port DBI ID 17cb:xxxx, LNKCAP 0x.., ELBI SYS_STTS 0x..` or `7 stop: the DBI does not answer ...`
- `8 root port class 0x60400.., buses 0x10100, LNKCTL2 0x..2, iATU0 0x4/0x80000000`
- `8 try N: link UP|DOWN: LNKSTA 0x.. (gen G xW), ELBI 0x.. (state 0x.. NAME), LTSSM 0x..`

Reading the step 8 state [I]: DETECT_QUIET/DETECT_ACT = the chip's receiver is not seen (power,
WLAN_EN/XO_CLK, PERST or refclk/CLKREQ); POLL_* or CFG_* = the chip is seen but training fails
(PHY tuning, speed); L0 (0x11) with DLLLA = link up. [I] Not done yet: the vendor PHY table differs
from 0120's in 3 RX values (0x0e3c 0x12 vs 0x16, 0x0e40 0x01 vs 0x04, 0x10d8 0x0f vs 0x07); the PCIe PHY
LDOs (pm8350 l5/l6, vendor DT vreg-0p9/1p8) are not voted (UFS/USB use the same LDOs, so ABL leaves
them on [I]); no interconnect (pcie_noc) vote.

### Phone test 2026-10-26 (0262 rebased on slop 0125) [V]

Boot-arg `negroniwifi=10`, image out/ios16-wifi10, USB log 00:00:35: `7 root port DBI ID 17cb:0110, LNKCAP 0x524c13`,
`8 try 1: link UP: LNKSTA 0x3012 (gen 2 x1), ELBI 0x11401 (state 0x11 L0)`, `9 bus 1 device 17cb:1103`,
`10 MSI capability at 0x50 control 0x10a`, `done (asked 10)`. The vendor DBI recipe (default) works. Slop 0125
now carries its own XO_CLK pulse and the Linux slave-space writes; the rebased 0262 replaces both with the cnss2
timing and the two recipes (notes.md section 16, 2026-10-26).

## 0263-negroni-wlan-stages.patch and 0264-negroni-wlan-ipcr-rings.patch (2026-10-26)

Files: `bsd/dev/negroni_wlan.c`, `negroni_wlan_mhi.{c,h}`, `negroni_wlan_bhi.c`, `negroni_wifi.c` (comment only).
Made in `out/kernel/tree-wlan5` (full patch set, then one commit per patch). Not run on the phone.

**`negroniwlan=N` is now a level.** It runs every level from 2 up to N. The meaning of `negroniwlan=2`
changed: it stops after the BHI SBL download (0261 ran all of stage 1 with 2; that is now `negroniwlan=4`).
When the asked level is reached, the chip keeps running and every buffer it got stays allocated. On a
failure the driver resets MHI, turns bus master off and only then frees the memory.

| Level | Step | Name (log `NEGRONI WLAN: step N NAME`) | Source |
|---|---|---|---|
| 2 | 1 | PCIe link hand-over | survey step 10 |
| 2 | 2 | BAR0 claim | 0261 |
| 2 | 3 | SoC version | BAR0 + 0x224 -> amss20.bin / amss.bin; cnss2 pci.c:5164-5215 |
| 2 | 4 | DMA pool | 0261 |
| 2 | 5 | firmware area | amss*.bin, m3.bin, SHA-256 check (0261) |
| 2 | 6 | DMA path (clocks, apps SMMU) | new in 0263; gcc-sm8450.c / gcc-waipio.c, live.dts iommu-map |
| 2 | 7 | PBL check | BHI/BHIe offsets, EE 0; pm.c MHI_IN_PBL |
| 2 | 8 | BHI SBL download | 512 KiB; boot.c:247 mhi_fw_load_bhi, :493 |
| 3 | 9 | MHI READY | pm.c:193 mhi_ready_state_transition |
| 3 | 10 | MHI MMIO contexts | init.c:424 mhi_init_mmio |
| 3 | 11 | MHI M0 | + device wake; pm.c mhi_setup_event_rings |
| 3 | 12 | EE SBL | pm.c:767 DEV_ST_TRANSITION_SBL |
| 4 | 13 | BHIe full image | boot.c:566 mhi_download_amss_image, :196 |
| 4 | 14 | EE AMSS (mission) | pm.c:783 |
| 4 | 15 | IPCR channels 20/21 | + 16 RX buffers (0264); cnss2 pci.c:147-176, main.c:598 |

Order note: the task list said "AMSS download, then MHI init". Linux does MMIO + M0 before BHIe
(boot.c:546 calls mhi_ready_state_transition right after the BHI SBL; BHIe starts on the EE SBL event,
pm.c:767-781). The levels follow Linux.

Log lines (all start `NEGRONI WLAN:`):
- `start: levels 2..N, time-out T ms per wait, SMMU policy P`
- `step N NAME` before each step; `step N NAME failed: REASON` on the first error of a step (if no
  specific reason was recorded: `failed: time-out|I/O error|... (error E)`).
- `level N done (step S)`; at the end `done|stopped at step S (level N asked, error E, events seen K)`.
- `BHI SBL|BHIe image waiting T ms, status .., EE .., MHISTATUS ..` every second during a BHI wait
  (if the phone restarts during the chip's first DMA, the last line shows how long it ran).
- Step 6: `GCC AGGRE_NOC_PCIE_0_AXI 0x.. (CLK_OFF n), DDRSS_PCIE_SF_TBU 0x.. (CLK_OFF n), vote 0x62000 = 0x..`
  (report only: both branches are BRANCH_HALT_SKIP with HW clock gating, gcc-waipio.c:1756/:1971, so CLK_OFF
  reads 1 while idle; the step stops only when vote bit 12 or 19 of 0x62000 is clear, gcc-waipio.c:1761/:1976);
  `apps SMMU ... EXIDS set; SMR format not handled, DMA path not checked` when sCR0.EXIDENABLE is set;
  `apps SMMU sCR0 .. (CLIENTPD c, USFCFG u, EXIDS e), IDR0 .. (n SMRs), IDR1 .., sGFSR ..`;
  then one of `stream 0x1c01 matches SMRi .. S2CR .. (translate|bypass|fault, context k)`,
  `... has no SMR; the SMMU is in client bypass`, `... unmatched streams bypass (USFCFG 0)`,
  `... has no SMR and unmatched streams FAULT (USFCFG 1)`.
- `device entered M1; host toggled device wake (0 then 1)` (pm.c:334-363); SYSERR and EE RDDM stop the step.
- 0264: `channel 21: 16 RX buffers of 32768 bytes at 0x..`; `channel N transfer event code .. ptr .. ignored`.
- Badge (framebuffer, top right): `WLAN N` while step N runs, `WLAN OK N`, `WLAN STOP N`.

New boot-args:

| Boot-arg | Default | Meaning |
|---|---|---|
| `negroniwlan=N` | 0 (off) | survey 1..10, then driver levels 2..N (max 4 in 0264; 6 with 0265/0266) |
| `negroniwlan_to=MS` | 10000 | time-out of every wait, 100..60000 |
| `negroniwlan_smmu=P` | **1** | 0 = step 6 only reports; 1 = stop before the first DMA when a clock vote bit is clear or the SMMU surely faults stream 0x1c01 (S2CR fault, a context we did not set up, or no SMR with USFCFG 1); **2 = WRITE a bypass SMR + S2CR for stream 0x1c01 into the apps SMMU** |

**Warning: `negroniwlan_smmu=2` writes the shared apps SMMU (Gunyah emulates its global space). Use it
only with the owner's approval, and only after a boot with the default showed `unmatched streams FAULT`.**

0264 data path: one 576 KiB contiguous allocation (Normal non-cacheable view): 16 RX buffers x 32 KiB
on channel 21 (posted after START_CHAN, put back after each transfer event), 8 TX buffers x 8 KiB for
channel 20 (`negroni_wlan_mhi_tx`, one EOT transfer per packet, waits for a free buffer). Transfer events
EOT/EOB/OVERFLOW free or re-post the buffers up to the TRE the event points at; DB_MODE rings the
doorbell again. At level 4 nobody reads the RX data yet (QRTR is level 5).

[I] Open: the restart during the first BHI SBL download (2026-10-26) is not isolated (brownout at 16 %,
SMMU fault, gated TBU/NoC clock, or a missing PCIe -> DDR interconnect vote). Step 6 and the heartbeat
lines are there to tell these apart.

## 0265-negroni-wlan-qrtr.patch and 0266-negroni-wlan-qmi-wlfw.patch (2026-10-26)

Files: `bsd/dev/negroni_wlan_qrtr.{c,h}` (0265), `negroni_wlan_qmi.{c,h}` + `negroni_wlfw_tables.h` (0266),
`negroni_wlan.c` (levels 5/6, `negroni_wlan_fw_file`), `negroni_wlan_mhi.h` (levels), `bsd/conf/files` (two lines right
after `negroni_wlan.c`, which stays right after `negroni_wifi.c` for 0280/0300/0310/0350; not between `negroni_wlan_mhi.c`
and `negroni_adsp.c`, which is the context of 0330: a first version put them there and 0330 was skipped). Made in
`out/kernel/tree-wlan7` (full patch set, one commit per patch). Build-only: not run on the phone.

`negroniwlan=5` runs levels 2..5, `negroniwlan=6` levels 2..6 (`WLAN_LEVEL_MAX` is 6 now).

| Level | Step | Name (log `NEGRONI WLAN: step N NAME`) | What | Source |
|---|---|---|---|---|
| 5 | 16 | QRTR HELLO | HELLO (v1 header, src node 1 port CTRL, dst node BCAST/known, port CTRL); wait for the chip's HELLO | af_qrtr.c qrtr_hello_work, qrtr_node_enqueue:781 |
| 5 | 17 | WLFW service lookup | wait for NEW_SERVER service 0x45, version byte 1, any instance; keep node/port | ns.c ctrl_cmd_hello/announce_servers, qmi_interface.c:52 (instance = vers \| ins << 8) |
| 6 | 18 | WLFW IND_REGISTER | client id 0x4b4e454c; fw_ready, request_mem, fw_mem_ready, fw_init_done, cal_done = 1 (fw_ready_enable added: ath11k sets it, cnss2 does not, qmi.c:153-160); stop on fw_status ALREADY_REGISTERED | cnss2 qmi.c:133, ath11k qmi.c:1793 |
| 6 | 19 | WLFW HOST_CAP | num_clients 1, bdf_support 1, m3_support 1, m3_cache_support 1, cal_done 0, host_build_type 2, feature_list 0x5 | cnss2 qmi.c:271 |
| 6 | 20 | WLFW firmware memory | wait REQUEST_MEM_IND, one contiguous zeroed allocation per segment (<= 32 MiB each, <= 64 MiB total, below 36 bit), RESPOND_MEM; if an allocation fails and <= 5 segments: RESPOND_MEM with 0 segments once, the firmware asks again in smaller pieces | cnss2 qmi.c:410 + 2545, ath11k qmi.c:1886 |
| 6 | 21 | WLFW FW_MEM_READY + CAP | wait FW_MEM_READY_IND, CAP_REQ, log the ids | cnss2 main.c:509, qmi.c:499 |
| 6 | 22 | WLFW BDF download | `regdb.bin` type 4 (failure ignored unless `regdb_mandatory`), then the board file type 1 (ELF) in 6144-byte segments, file_id = board id, total_size = remaining bytes | cnss2 main.c:525-531, qmi.c:729 (names), :950 |
| 6 | 23 | WLFW M3_INFO | addr/size of the m3.bin copy in the DMA pool (pool + 0x610000) | cnss2 qmi.c:1103 |
| 6 | 24 | WLFW FW_INIT_DONE | wait FW_INIT_DONE_IND (HSP) or FW_READY_IND, MAX(negroniwlan_to, 10 s) | cnss2 qmi.c:159 ("fw_ready is replaced by fw_init_done in HST/HSP") |

Proof lines (all start `NEGRONI WLAN:`):
- `step 16 QRTR HELLO from node N` and `QRTR header vV, HELLO src port .., dst node .. port ..`
- `QRTR NEW_SERVER service 0x.. version V instance I at node N port P (from node N)` (one per service)
- `step 17 WLFW service at node N port P`, `WLFW instance 0x.. (version 1, instance id I), K servers known`
- `QMI NAME (0xID) response: result R error E` for every request (BDF segments: only on an error)
- `firmware asks segment i: 0x.. bytes, type T, C config entries`, `segment i type T: 0x.. bytes at 0x..`
- `chip id 0x.. family 0x.., board id 0x.., soc id 0x.., otp 0x..`
- `firmware version 0x.., timestamp "...", build "..."` (the strong proof: a string from the chip's firmware)
- `regdb.bin (type 4) N bytes sent in S segments, file id 0x..`, `bdwlan.elf (type 1) ...`, `host_bdf_data 0x.. (HW_XPA x)`
- `m3.bin N bytes at 0x..`, `step 24 FW_INIT_DONE_IND received (hang data offset .. length ..)`
- errors: `step N NAME failed: REASON` as in 0263 (time-out, QMI refusal with result/error, bad message,
  BYE / DEL_SERVER of the WLFW server, chip SYSERR/RDDM), then the 0263 failure path: MHI reset + bus master off,
  then the firmware segments, the IPCR buffers and the pool are freed (once).

Badge: `WLAN 16` .. `WLAN 24`, `WLAN OK 6`, `WLAN STOP N`.

Design:
- QRTR (0265): every received packet is copied out of the channel-21 RX buffer by the MHI poller into an
  8 x 8 KiB queue, then decoded by `negroni_wlan_qrtr_pump` (never inside the poller, so a handler may send).
  `negroni_qrtr_parse` checks: length multiple of 4, header fits (v1 32 bytes, v2 16 + optlen), size != 0,
  size <= rest, buffer == header + size rounded to 4, control payload >= 20 bytes for NEW/DEL_SERVER,
  DEL_CLIENT, RESUME_TX, non-DATA packets only to port CTRL (af_qrtr.c qrtr_endpoint_post). We send v1 only,
  confirm_rx 0; when the chip sets confirm_rx we answer RESUME_TX (af_qrtr.c qrtr_send_resume_tx).
- QMI (0266): one generic encoder/decoder over field tables (`negroni_wlfw_tables.h`, one v01 source line per
  field). Decode zeroes the C struct, bounds-checks every TLV, nested prefix and array count, skips unknown TLV
  types, and fails if a mandatory TLV is missing. One request in flight; the response must match msg id + txn
  id and come from the WLFW node/port. Indications (REQUEST_MEM, FW_MEM_READY, FW_INIT_DONE, FW_READY,
  CAL_DONE) are kept until a step consumes them (REQUEST_MEM can arrive before the HOST_CAP response).
- Host test: `scripts/wifi/qmi-host-test.sh TREE` (patches/xnu/tests/wlan-qmi-test.c): exact request bytes,
  a full BDF segment = 6182 bytes = WLFW_BDF_DOWNLOAD_REQ_MSG_V01_MAX_MSG_LEN (v01.h:648), decode cases, 500 k
  random/mutated inputs under ASan/UBSan. Result 2026-10-26: ALL PASS.

Firmware files: the area from `scripts/wifi/mkwlanarea.py` already holds `regdb.bin` (24278 bytes),
`bdwlan.elf` (59932), `bdwlang.elf` and `bdwlan.e01`..`bdwlan.ee1` (198 files, notes.md "Make and write the
firmware area"). No new script and no new area write is needed. Name rule (cnss2 qmi.c:729-764 + OnePlus
qmi.c:684-724): board id 0xff -> `bdwlan.elf` (`bdwlang.elf` if chip_id & 0x10); < 0xff -> `bdwlan.eNN`
(`bdwlang.eNN`); else `bdwlanHH.eLL`. [V] The NE2211 IS in the OnePlus region list: out/live.dts bootargs has
`prjname=20847` and cnss2 qmi.c:652-659 `is_prj_support_region_id` lists 20847. With region CHN_IN / EU / NA cnss2 loads
`bdwlan.b0c` / `bdwlan.b0e` / `bdwlan.b0a` (qmi.c:40-42), else `bdwlan.elf`. The vendor firmware has none of the
`bdwlan.b0x` files (only bdwlan.elf, bdwlang.elf, bdwlan.eNN), so `bdwlan.elf` is the file this phone can load.

Deviations from the task text, with reason [V source]:
- BDF type 1 (ELF), not 0: `bdwlan.elf`/`.eNN` are ELF files and cnss2 uses CNSS_BDF_ELF = 1 by default
  (main.h:355-357, main.c:56). Type 0 is CNSS_BDF_BIN (`bdwlan.bin`, not in the area).
- regdb goes first (cnss2 main.c:525), not after the BDF.
- HOST_CAP sends no `daemon_support` (no such field in this v01: v01.h:867-932) and no `mem_cfg_mode`
  (cnss2 does not set it; ath11k sends 0, the default).
- HOST_CAP TLV 0x12 `gpios` is not sent. For this project (20847) cnss2 sends one entry 0x38242F00 = GPIO 56 output
  low ("WSA", `needSupportWsa`, qmi.c:258-268 and :309-331); ath11k never sends it. Step-25 candidate if FW_INIT_DONE
  does not come.
- IND_REGISTER: fw_ready_enable is added (ath11k sets it; cnss2 does not, qmi.c:153-160).
- HELLO goes to node 0xffffffff while the chip's node is unknown (af_qrtr.c: `to.sq_node = node->nid` =
  QRTR_EP_NID_AUTO), not node 0.

[I] Open points: host_build_type 2 assumes a kernel without CONFIG_CNSS2_DEBUG (cnss2 qmi.h:312-321); the DT has
`qcom,wlan-cbc-enabled` (out/live.dts:13853), so cnss2 runs a cold-boot calibration (WLAN_MODE CALIBRATION, wait
CAL_DONE, power cycle) before mission mode; level 6 stops at FW_INIT_DONE and does not do it.

New boot-arg values: `negroniwlan=5` (QRTR), `negroniwlan=6` (QMI WLFW). Image: `out/ios16-wlan6` (config args
with `negroniwifi=10 negroniwlan=6 negronipanic=30 negronipanicreason=2`).

### What step 25+ needs (not written)

1. WLAN_CFG (0x23: CE target pipe config, service-to-pipe map, shadow registers v2/v3) and WLAN_MODE MISSION (0x22),
   ath11k qmi.c ath11k_qmi_wlanfw_wlan_cfg_send / mode_send, core.c:2278 order (cfg + mode before the CE setup);
   cold-boot calibration first if we follow cnss2 (`qcom,wlan-cbc-enabled`).
2. Copy engine (CE) rings in host memory over BAR0 (ath11k ce.c, hal.c SRNG, pci.c window/register access,
   QCA6390/WCN6855 hw params; polling, no MSI), then HTC (htc.c: service connect for WMI control, HTT data),
   then WMI (wmi.c: WMI_INIT with the resource config, wait WMI_READY/service-ready events, MAC address).
3. HTT/DP rings (dp.c, dp_rx.c, dp_tx.c) for data, then the iOS side: an IO80211 / IONetworkingFamily `en0`
   interface (design reference external/ios-sailfish patches 0174-0179), scan + WPA (wpa_supplicant-style key
   handling in user space or in the kernel).

## 0261-negroni-wlan-mhi-fw.patch

Stage 1 of the driver: claim BAR0, choose the firmware, download it over MHI (BHI + BHIe), reach
mission mode and start the IPCR channels 20/21. Made in `out/kernel/wt-wlan4` (patches up to
0260 committed) with `git add -N bsd/dev/negroni_wlan*` then `git diff HEAD`. It runs only with
boot-arg `negroniwlan=2` (default 0; the normal config has `negroniwifi=4` and no `negroniwlan`),
on its own kernel thread, after survey step 10 passed. A failure stops the thread and never blocks
boot. Every wait has a time-out (`negroniwlan_to`, default 10000 ms like cnss2, clamped 100..60000).
No MSI: the host polls the event-ring read pointers (this XNU has no GICv3 ITS).
Review and fixes: [docs/reviews/wifi-0261-2026-10-25.md](../../docs/reviews/wifi-0261-2026-10-25.md).

Files in the patch:
- `bsd/dev/negroni_wlan.h` — the seam: the survey hands over its mapped PCIe0 handles
  (`negroni_wifi_pcie_handles`); the driver entry point `negroni_wlan_start`.
- `bsd/dev/negroni_wlan_mhi.h` — MHI register offsets, states, ring/context structs, pool size.
- `bsd/dev/negroni_wlan.c` — BAR0 sizing and claim, firmware area read, DMA pool, the sequence,
  the failure path (MHI reset + bus master off before the pool is freed).
- `bsd/dev/negroni_wlan_mhi.c` — READY, contexts, event rings, M0 + device wake, EE waits,
  event-ring polling, channel start.
- `bsd/dev/negroni_wlan_bhi.c` — BHI (SBL) and BHIe (full image) register transfers.
- `bsd/dev/negroni_wifi.c` — `negroniwlan=2` starts the driver after step 10 (survey unchanged).
- `bsd/dev/negroni_ufs.c` — `negroni_ufs_wlan_area_read` (32 MiB area before the ADSP area).
- `bsd/conf/files` — the three new `.c` files.

Sequence (Linux order, op-kernel `drivers/bus/mhi/host`) [V source, I untested on the chip]:
1. BAR0: size probe (all-ones, decode off), place it at the first size-aligned address of the
   0x60300000 window (0x60400000 for a 2 MiB BAR), check the read-back, memory + bus master on.
2. SoC version (BAR0 + 0x224) -> `amss20.bin` if (major & 0xf) == 2, else `amss.bin`.
3. DMA pool (contiguous, below the 36-bit mask), Normal non-cacheable second view
   (`ml_io_map_unmappable`, WCOMB). Firmware + m3 from the area; a SHA-256 mismatch stops.
4. The chip must be in PBL (EE 0, no SYSERR). BHI loads the first 512 KiB (SBL) (`boot.c`
   `mhi_fw_load_bhi`).
5. MHICTRL RESET clear, MHISTATUS READY, then the MMIO contexts (`pm.c`
   `mhi_ready_state_transition` -> `init.c` `mhi_init_mmio`), event-ring elements + doorbells,
   M0 request, MHISTATE M0, device-wake doorbell 127 = 1.
6. EE SBL (EE event or BHI_EXECENV), then BHIe loads the whole image (`pm.c`
   `DEV_ST_TRANSITION_SBL` -> `boot.c` `mhi_download_amss_image`).
7. EE AMSS, then START_CHAN 20 and 21.

All 64-bit doorbells and base registers are written high word first (`main.c` `mhi_write_db`).

Mapping change 2026-10-25 [V source, I untested]: BAR0 (2 MiB) maps with `ml_io_map_unmappable(...,
VM_WIMG_IO 0x7)` (kernel_map, not the 8 MiB io_submap); the failure path unmaps it after
`wlan_quiesce`. The pool's WCOMB view is now unmapped with its 16 KiB-rounded size: `ml_io_unmap`
of 0x691000 bytes would have panicked in `pmap_remove_options` (MACH_ASSERT is on in this
DEVELOPMENT build, `mach_assert.h`; the end address must be page aligned, pmap.c:4294).

### Boot log lines (all start "NEGRONI WLAN:")

| Line | Meaning |
|---|---|
| `stage 1 start (MHI firmware download, time-out N ms per wait)` | the thread started |
| `reusing survey PCIe handles, chip 17cb:1103` | step 10 handed over a live link |
| `the PCIe survey did not hand over a live link; stop` | step 10 did not pass; nothing runs |
| `BAR0 64-bit 0x200000 bytes at 0x60400000, MHI REGLEN 0x.. VER 0x..` | BAR0 sized, placed and mapped |
| `endpoint config space reads 0xffffffff / BAR0 size probe ... / BAR0 reads back ...; stop` | BAR0 could not be claimed |
| `SoC version 0x.. (major N) -> firmware amss20.bin|amss.bin` | TCSR_SOC_HW_VERSION |
| `DMA pool N bytes at 0x8..` | contiguous DMA pool (contexts, rings, firmware, m3, vector) |
| `firmware area has N files` | the WLAN area header parsed (magic NEGRWLAN, version 1) |
| `no firmware area header (error N)` | the area is missing or not written; stop |
| `<file> N bytes loaded, sha-256 OK` | amss*.bin, then m3.bin, copied from the area |
| `<file> ... sha-256 MISMATCH; stop` / `not found` / `out of range` / `read error` | a load failure; stop |
| `BHI off 0x.., BHIe off 0x.., execution environment N, MHISTATUS 0x..` | MHI boot offsets read |
| `the chip is not in PBL ...; stop` | EE not 0 or SYSERR before BHI |
| `BHI SBL N bytes at 0x.., session N` | SBL (first 512 KiB) download started |
| `MHISTATUS READY (0x..), execution environment N` | the SBL runs, MHI READY |
| `MHI ctx ch 0x.. ev 0x.. cmd 0x.., chdboff 0x.. erdboff 0x..` | contexts and MMIO bases programmed |
| `MHI state M0, device wake asserted` | M0 reached |
| `execution environment SBL (1, seen in BHI_EXECENV|an EE event)` | ready for BHIe |
| `BHIe image N segments (N byte vector) at 0x.., seq N` | full-image (FBC) download started |
| `execution environment AMSS (mission) (2, seen in ...)` | the chip reached mission firmware |
| `channel 20 started` / `channel 21 started` | IPCR out/in channels up |
| `stage 1 complete: mission mode, IPCR 20/21 up, m3 N bytes ready at 0x..` | success |
| `BHI SBL|BHIe image error/timed out ... / status reads 0xffffffff` | a boot-interface transfer failed |
| `MHICTRL RESET never cleared / MHISTATUS never READY / SYSERR ... / never reached M0 / never reached SBL|AMSS` | an MHI step failed |
| `channel N start timed out / failed, completion code 0x..` | START_CHAN failed |
| `MHI reset requested and bus master off, command 0x..` | failure path: the chip can no longer DMA; then the pool is freed |
| `stage 1 done|stopped (error N, events seen N)` | the thread ended; `done` = success |

### Make and write the firmware area

The area is 32 MiB and holds the WLAN firmware files from the stock modem image (198 files,
23146496 bytes used on NE2211_16.0.3.530). Stage 1 reads `amss*.bin` and `m3.bin`; the board
files and `regdb.bin` are for stage 2. `mkwlanarea.py` refuses a directory without amss*.bin or m3.bin.

```
scripts/bg.sh wifi-fw scripts/wifi/extract-fw.sh          # out/firmware/wlan/ (git-ignored)
scripts/wifi/mkwlanarea.py out/wlan-area.bin              # 32 KiB header + files, 4 KiB aligned
```

The header is 32 KiB: `"NEGRWLAN"`, u32 version 1, u32 count, then up to 256 entries of
`{char name[48]; u32 offset; u32 size; u8 sha256[32]}` (88 bytes each). The kernel checks the magic,
the version and each file's SHA-256.

Write the area to the userdata partition (N = partition size in 4096-byte blocks), right before the
ADSP area, with the owner's approval (this overwrites part of userdata; `fastboot flash userdata`
erases it). The read side (`negroni_ufs_wlan_area_read`) uses the same block map:

```
WLAN fw area   N-19457 .. N-11266     (8192 blocks)
dd if=out/wlan-area.bin of=/dev/block/by-name/userdata bs=4096 seek=$((N-19457)) conv=notrunc,fsync
```

Never commit the firmware files or the area image.

## License boundary

- Protocol reference: Linux `ath11k` (BSD-3-Clause-Clear) and `drivers/bus/mhi` (GPL-2.0); we read
  them, we do not copy them.
- iOS interface reference: `external/ios-sailfish/xnu/patches/0174`, `0175`, `0178`, `0179`
  (no license file: design only).
- Step 10 is new code; it uses only PCI-spec offsets.
