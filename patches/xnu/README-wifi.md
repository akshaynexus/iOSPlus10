# Wi-Fi kernel changes (0260-0269, 0320-0329)

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
  0320 corrects this: Linux writes MHISTATE M2, then (device wake held) wake_get + wake_put; the line is now
  `device entered M1; host wrote M2 and device wake 1 (pm.c:341-359)`.
- 0264: `channel 21: 16 RX buffers of 32768 bytes at 0x..`; `channel N transfer event code .. ptr .. ignored`.
- Badge (framebuffer, top right): `WLAN N` while step N runs, `WLAN OK N`, `WLAN STOP N`.

New boot-args:

| Boot-arg | Default | Meaning |
|---|---|---|
| `negroniwlan=N` | 0 (off) | survey 1..10, then driver levels 2..N (max 4 in 0264; 6 with 0265/0266) |
| `negroniwlan_to=MS` | 10000 | time-out of every wait, 100..60000 |
| `negroniwlan_smmu=P` | **1** (3 was the default for a few hours of 2026-10-27; back to 1 after the 0249 SEA) | 3 = the 0324/0325 stage-1 context, opt-in (see "0325"); 0 = step 6 only reports; 1 = stop before the first DMA when a clock vote bit is clear or the SMMU surely faults stream 0x1c01 (S2CR fault, a context we did not set up, or no SMR with USFCFG 1); **2 = WRITE a bypass SMR + S2CR for stream 0x1c01 into the apps SMMU** |

**Warning: `negroniwlan_smmu=2` writes the shared apps SMMU (Gunyah emulates its global space). Use it
only with the owner's approval, and only after a boot with the default showed `unmatched streams FAULT`.**

### 2026-10-26 panic fix (0255, 0263, 0324)

- [V] The first boot of out/ios16-everything panicked in step 6: `Kernel data abort` at `_wlan_dma_path+0x170`
  = `ldr w12, [x9], #0x4` (the SMR scan), far = SMMU mapping + 0x800 (SMR0), ESR 0x96000010 (synchronous
  external abort). The plain reads of sCR0/IDR0/IDR1/sGFSR just before it worked (docs/notes.md section 27).
- [I] Cause: Gunyah traps and emulates the apps SMMU global space (0x15000000, pages 0 and 1). It emulates only
  single-register 32-bit loads/stores with ESR ISV=1. The compiler made the scan a post-index load (no ISV), so
  the hypervisor injected an SEA. A pair, a 64-bit access or a store from WZR gets the same (the OnePlus sm8450
  arm-smmu.c:62-67 comment on WZR stores; Linux readl/writel are `ldr %w0,[%1]` / `str %w0,[%1]`).
- Fix: new `bsd/dev/negroni_mmio.h` (patch 0255): `negroni_mmio_rd32` / `negroni_mmio_wr32`, one inline-asm
  `ldr w, [x]` / `str w, [x]`, value operand `"r"` (never WZR). 0263 (`SRD`/`SWR`) and 0324 (`SR`/`SW`) use them
  for every apps-SMMU access; the dsb barriers stay. 0324 also limits the scan to `qcom,num-context-banks-override`
  0x4e contexts and `qcom,num-smr-override` 0x78 SMRs (live.dts apps-smmu).
- [I] `negroniwlan_smmu=2` is expected to fail: the Android driver (arm-smmu-qcom.c:2288, mainline `bypass_quirk`)
  says this hypervisor treats S2CR TYPE bypass as blocked, so a bypass entry reads back as FAULT. The path for
  DMA through this SMMU is the stage-1 context, `negroniwlan_smmu=3` (0324).

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

### What step 25+ needs (written 2026-10-26: 0320-0324 below)

1. WLAN_CFG (0x23: CE target pipe config, service-to-pipe map, shadow registers v2/v3) and WLAN_MODE MISSION (0x22),
   ath11k qmi.c ath11k_qmi_wlanfw_wlan_cfg_send / mode_send, core.c:2278 order (cfg + mode before the CE setup);
   cold-boot calibration first if we follow cnss2 (`qcom,wlan-cbc-enabled`).
2. Copy engine (CE) rings in host memory over BAR0 (ath11k ce.c, hal.c SRNG, pci.c window/register access,
   QCA6390/WCN6855 hw params; polling, no MSI), then HTC (htc.c: service connect for WMI control, HTT data),
   then WMI (wmi.c: WMI_INIT with the resource config, wait WMI_READY/service-ready events, MAC address).
3. HTT/DP rings (dp.c, dp_rx.c, dp_tx.c) for data, then the iOS side: an IO80211 / IONetworkingFamily `en0`
   interface (design reference external/ios-sailfish patches 0174-0179), scan + WPA (wpa_supplicant-style key
   handling in user space or in the kernel).

## 0320-0324: WLAN_CFG/MODE, copy engines, HTC/WMI, passive scan, SMMU stage 1 (2026-10-26)

Files: `bsd/dev/negroni_wlan_ce.{c,h}` (0320 header, 0321 code), `negroni_wlan_wmi.{c,h}` (0322, 0323),
`negroni_wlan_smmu.c` (0324), `negroni_wlan_qmi.c` + `negroni_wlfw_tables.h` (0320), `negroni_wlan.c`,
`negroni_wlan_mhi.{c,h}`, `bsd/conf/files` (new lines right after `negroni_wlan_qmi.c`). Made in
`out/kernel/tree-wmi` (patched-tree.sh, then one commit per patch; deleted after). Build-only: not run on the phone.
Reference: Linux ath11k (BSD-3-Clause-Clear) for WCN6855 hw2.x (PCI 17cb:1103 = WCN6855, ath11k pci.c:32):
values and sequences only, our own code. Design reference only (no license file): external/ios-spes 0099
(WCN6750 CE/HTC/WMI scan), external/ios-sailfish 0169-0179 (QCA6174 + the iOS side).

`negroniwlan=N` now goes to 10 (`WLAN_LEVEL_MAX`). After the last asked level (>= 4) a keep-alive poller runs.

| Level | Step | Name (`NEGRONI WLAN: step N NAME`) | What | Source |
|---|---|---|---|---|
| 7 | 25 | WLFW WLAN_CFG | host "WIN", 9 target CE pipes, 14 service routes, 30 shadow registers v2 (493-byte message) | ath11k qmi.c:2695, hw.c:1623/:1720, ce.c:840 |
| 7 | 26 | WLFW WLAN_MODE mission | mode 0, hw_debug 0 | ath11k qmi.c:2640, :2841-2869 |
| 8 | 27 | CE rings | one 304 KiB DMA area: pointer area, CE0 src 16, CE3 src 32, CE1 dst 32 + status, CE2 dst 64 + status, 2048-byte buffers; ring registers through the BAR0 window (0x310c); read-back check of the CE0 base | ce.c:914, hal.c:998/:268/:347, pci.c:75-128 |
| 8 | 28 | HTC READY | the first CE message: HTC endpoint 0 READY, credits and credit size | htc.c:521 |
| 9 | 29 | HTC connect | HTT data (no credit flow), WMI control (1 credit), SETUP_COMPLETE_EX | htc.c:593, :763, wmi.c:9072 |
| 9 | 30 | WMI SERVICE_READY | SERVICE_READY (+ SERVICE_AVAILABLE) + SERVICE_READY_EXT (+ EXT2 with service 220) | wmi.c:576, :5037, :5177, :8155 |
| 9 | 31 | WMI INIT | resource config of ath11k_init_wmi_config_qca6390 (72 words), no host memory chunks, no hw mode TLV | hw.c:58, wmi.c:4188, :4258, :4469 |
| 9 | 32 | WMI READY | status, MAC; compared with ADT `/chosen mac-address-wifi0` | wmi.c:7346 |
| 10 | 33 | WMI channel list | PDEV_SET_HW_MODE DBS (answer optional), SCAN_CHAN_LIST 38 channels, all passive, split by the WMI max message | core.c:2203, wmi.c:2590 |
| 10 | 34 | WMI VDEV_CREATE STA | vdev 0, type STA, chip MAC, pdev id of SERVICE_READY_EXT, streams = RF chains | wmi.c:726 |
| 10 | 35 | WMI passive scan | START_SCAN (ath11k timings, passive), SCAN events, MGMT_RX beacons: one line per new BSS | wmi.c:2264, :7630, :7799 |

### 0320: WLAN_CFG + WLAN_MODE, keep-alive, DMA-address seam, HOST_CAP option, M1 fix

- WLAN_CFG tables (`negroni_wlan_ce.h`): target CE config and service map exactly as
  `ath11k_target_ce_config_wlan_qca6390` / `..._service_to_ce_map_...` (CE0 host->target HTC control, CE1
  target->host HTT + HTC control, CE2 target->host WMI, CE3 host->target WMI, CE4 host->target HTT, CE5 pktlog,
  CE6/CE8 target memcpy/IPA, CE7 host-only). Note: WMI goes out on **CE3**, not CE0; HTC control replies come on
  CE2. Shadow list = the ath11k order: the 20 non-CE, non-LMAC rings of `hw_srng_config_template`, then the CE
  rings of the host CE table (CE0 src, CE1 dst + status, CE2 dst + status, CE3 src, CE4 src, CE5 dst + status, CE7
  src). The host writes ring pointers at BAR0 0x8fc + 4 x index; the firmware copies them to the ring registers.
- Not sent (deviations, with reason): WLAN_INI (ath11k only, firmware log over WMI; cnss2's v01 has no such
  message), shadow v1 (ath11k sends none), msi_cfg TLV 0x16 (cnss2 only; no MSI), shadow v3 (KIWI only).
- Cold-boot calibration: not done; not required on the ath11k path (wcn6855 hw2.x `coldboot_cal_mm/ftm` false,
  audit section 0).
- DMA-address seam: every address the chip gets now goes through `negroni_wlan_dma_map(pa, size)` (pool,
  BHI/BHIe, ring contexts, IPCR TREs, firmware segments, m3, CE area). Identity unless `negroniwlan_smmu=3`.
- Keep-alive (audit 2.4): after the last level the thread drains MHI, QRTR and the CE rings every 20 ms with
  `IOSleep` (not a spinning `delay`), logs late QMI indications, prints `keep-alive N s: ...` every 60 s, and
  takes the normal failure path on SYSERR/RDDM. `negroniwlan_keep=S` stops it after S seconds (default 0 = until
  a chip error).
- `negroniwlan_hostcap=android` (or `=1`): HOST_CAP with feature_list 0x7 (+ DRV: cnss2 reads
  `qcom,drv-supported` from the PCIe controller node, `pci_qcom.c:157-168`, live.dts:20821; correction of the
  0266 text, which looked in the wlan node) and gpios {0x38242f00} (WSA GPIO 56 low, project 20847,
  cnss2 qmi.c:258-331). For a HOST_CAP refusal or a missing FW_INIT_DONE.
- M1: write MHISTATE M2, then device wake 1 (pm.c:341-359), instead of wake 0/1.

### 0321: copy engines on HAL SRNG, polled

- Register window: offsets >= 0x80000 go through BAR0 + 0x80000 + (off & 0x7ffff) after writing
  `0x40000000 | off[24:19]` to BAR0 0x310c (wcn6855 has no static window map). CE0 SRC R0 is 0x1b80000 (window
  0x37). Proof line: `window register A -> B; CE0 SRC base reads X (wrote X)`; a mismatch stops step 27.
- Ring setup (hal.c src/dst hw init): base LSB, base MSB (addr 39:32 | size in dwords << 8), ID, TP/HP address =
  the ring's slot in the pointer area (4 x ring id: CE src 32+n, CE dst 56+n, CE status 80+n), R2 head/tail 0,
  MISC = SRNG_ENABLE (+ LOOPCNT_DISABLE for source rings). No MSI address, interrupt thresholds 0. CE dst MAX_LEN
  (R0 + 0xb0) = 2048. Descriptors: src {addr lo, addr 39:32 | len << 16, meta = HTC endpoint, 0}; dst {addr lo,
  addr 39:32}; status {len in 31:16, ...}.
- Non-MSI mapping (asked): ath11k has no legacy/INTx path for PCI; it needs at least one MSI vector
  (`pcic.c` one-MSI mode). Our path: the HAL writes the source rings' tail and the destination rings' head into
  host memory whether or not MSI is set (the TP_ADDR/HP_ADDR registers), so polling that area replaces the CE
  interrupt; the CE "copy complete" interrupt is never enabled.
- RX: slot k of a destination ring always owns buffer k; n - 1 buffers posted; a completed status entry is
  copied out (length 1..2048 checked), handed to `negroni_wlan_ce_rx_cb`, and the slot at the head re-posted.
- Cache: the CE area has a Normal non-cacheable alias (as 0264); the cacheable view is flushed once at
  allocation and on free.

### 0322: HTC + WMI init

- HTC: header {eid | flags << 8 | payload length << 16, trailer length | seq << 8}; trailer records checked
  (credit records: eid + credits). Endpoint 0 = pseudo control service (CE0 out / CE2 in). HTT data connected
  without credit flow (no HTT message is sent yet). WMI control: credit flow with 1 credit (ath11k forces the
  total to 1 on shadow-register chips, htc.c:567-571); every WMI command waits for a credit report.
- WMI: command = u32 id + TLVs; events walked TLV by TLV (`negroni_wmi_tlv_next`, every length checked).
  Service bitmap: 4 services per word in SERVICE_READY (ath11k's layout), 128..383 from SERVICE_AVAILABLE.
- Proof lines: `WMI SERVICE_READY: fw build ..., abi ..., phy caps ..., N RF chains, ...`,
  `WMI SERVICE_READY_EXT: N hw modes, ..., pdev id P ..., chain masks ...`, `WMI INIT: 4 vdevs, 16 peers, ...`,
  `WMI READY: fw abi ..., status S, MAC xx:..., N peers, ...; N RF chains, 4 vdevs`, then
  `ADT mac-address-wifi0 02:00:5e:77:ee:10: DIFFERS from|matches the chip's MAC`.
- Unknown WMI events: one line per new id (`WMI event 0x... (N bytes) not handled`, at most 12); debug/diag
  events counted only.

### 0323: one STA vdev and a passive scan

- PDEV_SET_HW_MODE DBS (ath11k does it after READY for single_pdev_only + 2 rxdma), SCAN_CHAN_LIST (2.4 GHz 1-13,
  5 GHz 36-165; DFS flag 5260-5720; every channel passive, so nothing is transmitted), VDEV_CREATE (vdev 0 STA,
  the chip's MAC), START_SCAN (scan id 0xa001, dwell passive 150 ms, max 20 s, PASSIVE | CHAN_STAT_EVENT,
  broadcast BSSID).
- MGMT_RX: header (snr, buf_len <= the frame TLV, status 0), then the frame; beacon / probe response parser
  checks every element. RSSI = snr - 95 dBm (ath11k core.h:605).
- Proof lines (what the owner sees): `BSS N: SSID "name", RSSI -NN dBm, F MHz (DS channel C), BSSID
  aa:bb:cc:xx:xx:xx, RSN|WPA|WEP|open, beacon interval I`; at the end `SCAN done (reason R): N BSS seen, ...`
  and one `SCAN result` line per BSS. The keep-alive keeps logging new BSSes (late beacons).
- [I] Risk: ath11k always sets up the HTT rx rings (rxdma refill, REO) before a scan. If SCAN events arrive but
  no MGMT_RX, the missing rxdma rings are the first suspect (0325+). The log says so.

### 0324: SMMU stage 1 for stream 0x1c01 (`negroniwlan_smmu=3`)

- Audit 2.1: every chip address is above 4 GiB under XNU; Android gives IOVAs 0xa0000000 + 256 MiB. With
  `negroniwlan_smmu=3`, step 6 takes a free apps-SMMU context bank and a stream-match entry (or the one that
  already matches 0x1c01, restored on the failure path), builds 3-level 4 KiB tables (39-bit IOVA, 36-bit PA,
  Normal NC, AP unprivileged), programs CBA2R/CBAR/TCR2/TCR/TTBR0/MAIR0 + TLB sync, SCTLR on, then S2CR + SMR,
  and reads every value back (`SMMU NAME reads X after writing Y` or `the SMMU (or the hypervisor) did not take the context` otherwise; page entries outer shareable, as io-pgtable-arm for non-cacheable memory). Every buffer
  is then mapped at the next IOVA from 0xa0000000 (64 KiB guard between buffers), one line each:
  `SMMU map PA (N bytes) -> IOVA I`.
- Failure path: `SMMU context C: FSR .. FAR .. FSYNR0 ..` before the quiesce, then context off and tables freed.
- Values from the 0233 GPU SMMU code (negroni_adreno.c) on this SoC. **Writes the shared apps SMMU: ask the
  owner before the first boot with it.** Use it when step 8 (BHI SBL) times out or SYSERR follows RESPOND_MEM
  with the default (bypass) path.

### Boot-args (new)

| Boot-arg | Default | Meaning |
|---|---|---|
| `negroniwlan=7..10` | - | 7 WLAN_CFG/MODE, 8 CE + HTC READY, 9 HTC/WMI to READY, 10 vdev + passive scan |
| `negroniwlan_keep=S` | 0 | keep-alive seconds after the last level (0 = until a chip error) |
| `negroniwlan_hostcap=android` | off | Android HOST_CAP: DRV bit + WSA gpio entry |
| `negroniwlan_smmu=3` | 1 | 0324/0325 stage-1 context, opt-in until the bank probe of the SMMU agent proves which banks HLOS may write (see "0325") |

Boot-args for the combined image (the main session composes them; no image is built by this stage):
`negroniwifi=10 negroniwlan=10 negronipanic=30 negronipanicreason=2`. Lower `negroniwlan` to stop earlier
(7 = after WLAN_MODE, 8 = HTC READY, 9 = WMI READY). Optional, each needs a reason from a log first:
`negroniwlan_hostcap=android` (QMI refusal), `negroniwlan_smmu=3` (the stage-1 context; only after the bank probe),
`negroniwlan_keep=600` (stop the poller after 10 minutes). Precondition: the WLAN firmware area on userdata.

Host test: `scripts/wifi/wmi-host-test.sh TREE` (patches/xnu/tests/wlan-wmi-test.c): WLAN_CFG = 493 bytes with
the shadow entries at the right places, WLAN_MODE and HOST_CAP(gpios) exact bytes, HTC READY / header /
trailer, WMI TLV walk, beacon parser, then 700 k random and mutated inputs under ASan/UBSan. The 0266 test
(`qmi-host-test.sh`) still passes on the new tables.

### Final stage design (0325+): connect, data path, iOS

1. **Join (WMI)**: VDEV_START on the BSS channel, PEER_CREATE (the AP), open-system AUTH + ASSOC request
   frames sent by WMI MGMT_TX (or the firmware's own connect if the service bit allows; ath11k uses host
   frames), PEER_ASSOC with the rates/HT caps, VDEV_UP with the AID. Source: ath11k mac.c sta_state, wmi.c
   vdev_start/peer_create/peer_assoc/vdev_up/mgmt_send.
2. **Keys**: ath11k leaves EAPOL to mac80211 + wpa_supplicant. iOS has no wpa_supplicant and XNU no mac80211,
   so the kernel needs a tiny WPA2-PSK supplicant (as Sailfish 0173: PBKDF2-SHA1 PMK from the passphrase given
   by wifid, 4-way handshake PTK = PRF-384, MIC = HMAC-SHA1, GTK unwrap = AES key wrap, then two
   WMI_VDEV_INSTALL_KEY (pairwise CCMP, group)). EAPOL frames go through the data path (step 3). ~1 500 lines.
3. **HTT data path**: HTT version request, SRNG setup messages for the rxdma refill ring and the REO/WBM/TCL
   rings the 0320 shadow list already names, RX descriptor parse (wcn6855 layout), TX by TCL. The largest part
   (~2 000 lines; ath10k-class Sailfish had none of it). Polled at first; MSI needs a GICv3 ITS (not in this XNU).
4. **iOS side - decision: an IOEthernetController `en0` with Apple80211 ioctls, driven by the stock wifid and
   Settings.** Justification: Sailfish shows it works on iOS 16 (Settings lists, joins WPA2, DHCP, Safari) with
   exactly this shape: IONetworkingFamily staged into the kernel (`0175-stage-ionetworking.sh`, configd names
   only IONetworkInterfaces), `SailfishWLAN : IOEthernetController` (0175), Apple80211 requests as
   `SIOCGA80211`/`SIOCSA80211` ioctls on the interface plus kernel events (class 6) for wifid (0179; request
   layouts read out of IO80211.framework 16.5 by spes 0113). A full IO80211Family port is not realistic (closed,
   large). A private daemon with its own UI would work without reverse engineering but loses Settings, the
   status bar and every app's network reachability path; a fake IO80211 family is the same reverse
   engineering as the ioctls with more surface. So: ioctls on en0, Settings via the real wifid. The ADT
   `mac-address-wifi0` must become the chip's MAC (from step 32). ~2 300 lines, reverse engineering of the
   request set (log every request first).
5. Recovery and power (RDDM restart, radio off, suspend): after scan + connect + IP. Total remaining
   [I, audit section 3]: about 7 000 lines after 0320-0324.

## 0325-negroni-wlan-smmu3-default.patch (2026-10-27)

Files: `bsd/dev/negroni_wlan_smmu.c` (rewritten), `negroni_wlan.c`, `negroni_wlan_mhi.{c,h}`, `negroni_wlan_bhi.c`,
`negroni_wlan_qmi.c`. Made in `out/kernel/tree-wlansmmu` (patched-tree.sh, full set; deleted after). No later patch
touches these files. Build-only: not run on the phone. The owner approved the SMMU write path (2026-10-27).

**Status (2026-10-27, main-session review): `negroniwlan_smmu=1` is the default again; `=3` is opt-in.** A boot with
the camera/audio stage-1 helper (0249) took an SEA on a GR1 CBAR write to a "free" bank: Gunyah refuses writes to some
banks. 0325 uses the same free-bank rule, so =3 waits for the bank probe (a separate agent: ml_expect_fault-based probe,
Android/HakiOS bank evidence). 0325 changes after that review: (a) the claim lock `negroni_smmu_claim_lock` (exported by
0249, shared with its helper: SMRs top-down, context banks bottom-up from NUMS2CB since 2026-10-27; 0325 claims bottom-up) is held from the SMR/CB scan to the last SMR write and in
the teardown; the root table is allocated before the lock; the SMR is read again right before its write; (b) the
teardown writes back only registers that setup wrote and read back as written (flags for SCTLR, CBA2R, CBAR, S2CR, SMR;
CBA2R and CBAR now in separate steps); (c) an SMR that already matches 0x1c01 is reused only with mask <= 1 and S2CR
fault/bypass or translate into a context that is off.

The first version of this section said: **`negroniwlan_smmu=3` is the default** whenever the driver runs (`negroniwlan>=2`). `negroniwlan_smmu=1` (old
report-only check, stop on a sure fault) and `=0` (report only) stay selectable. `=2` (bypass entry) stays, but the
hypervisor turns S2CR BYPASS into FAULT (arm-smmu-qcom.c bypass quirk, U-Boot qcom-hyp-smmu.c), so it is dead.

### What 0325 changes, with the source of each value

| Item | 0324 | 0325 | Source |
|---|---|---|---|
| Context bank choice | first CB >= 1 with SCTLR.M 0 and no valid S2CR into it | CB >= 0 with CBAR type S2_TRANS, or S1_TRANS_S2_BYPASS with VMID 0xff, **and** SCTLR.M 0 **and** no valid S2CR translating into it; summary line of all contexts; `negroniwlan_smmu_cb=N` forces N (still needs SCTLR.M 0 and no S2CR) | U-Boot `qcom-hyp-smmu.c` alloc_cb (VMID_UNUSED 0xff); redwood_wifi.c radio_space_find |
| CBAR | S1_TRANS_S2_BYPASS, BPSHCFG 3, MEMATTR 0xf, VMID 0 | same; read back: type must stay 1 | U-Boot, Linux arm-smmu.c |
| CBA2R | VA64 | VA64, read back | same |
| SCTLR | M TRE AFE CFRE ASIDPNE | M TRE AFE **HUPCF** ASIDPNE; **no CFRE** (no abort to the chip), no CFIE, CFCFG 0 (no stall) | live.dts `qcom,iommu-faults = "stall-disable", "HUPCF", "no-CFRE", "non-fatal"` |
| TCR / TCR2 / MAIR0 | T0SZ 25, WBWA walk, inner shareable, EPD1 / PASIZE 36, AS16, SEP / 0xf404ff44 | same; must-bits read back (T0SZ+TG0, PASIZE, MAIR attr 0) | live.dts `qcom,iommu-pagetable = "coherent"`; Linux io-pgtable |
| Page entries | NC (AttrIndx 0), outer shareable, AF, AP unprivileged, nG | same (the CPU uses NC views of every DMA buffer) | io-pgtable-arm.c |
| Stream entry | SMR = 0x1c01 mask 0 | SMR = 0x1c00 **mask 1** (0x1c00 and 0x1c01) unless another valid SMR covers 0x1c00 (then 0x1c01 only); a valid SMR that already matches 0x1c01 is reused only when its mask is at most 1 and its S2CR is fault, bypass, or translate into a context with SCTLR.M 0; otherwise step 6 stops with EBUSY (`... translates through a live context (not ours)`) (main-session review) | live.dts pcie0 `iommu-map` RID 0 -> 0x1c00, RID 0x100 -> 0x1c01; redwood used mask 1 |
| Write order | S2CR, then SMR | same (Linux arm_smmu_write_sme; U-Boot writes SMR first) | arm-smmu.c |
| Read back | SMR, S2CR, SCTLR.M, TTBR0 lo | every register; hard stop on TTBR0, CBAR type, CBA2R VA64, SCTLR.M, S2CR type+CBNDX, SMR; other bit differences printed | redwood "all read back but two bits" |
| Teardown | SMR cleared, SCTLR 0 | SMR/S2CR back to the saved values (order by case), SCTLR 0, TLBI, CBAR/CBA2R back to the saved values; only what was written | - |
| Faults | FSR/FAR/FSYNR0/sGFSR on failure | one decoded line: FSR bit names, FAR 64-bit, FSYNR0 read/write + level + table-walk, FSYNR1, CBFRSYNRA SID, sGFSR names, sGFSYNR0/1(SID)/2; on the failure path, after **each level** (also "no fault"), at every 1 s BHI/BHIe heartbeat and in the 60 s keep-alive line when FSR or sGFSR changed (max 16 lines) | SMMUv2 spec, Linux arm-smmu.h |
| Page tables | 192 4-KiB tables | same; enough for the whole window: 0xa0000000-0xafffffff sits in one level-1 entry = 1 root + 1 level-2 + 128 level-3 tables (130) | - |
| Unmap | none | `negroni_wlan_smmu_unmap` (PTE cleared + TLBI); QMI firmware segments are unmapped before they are freed (the 0-segment retry frees them while the chip runs) | - |

Chain changes (`negroni_wlan.c`, `_mhi.c`, `_bhi.c`, `_qmi.c`):
- **PCIe BDF-to-SID table** [V source, I effect]: pci-msm.c `msm_pcie_config_sid` runs on every link enable: PARF
  0x2c00 bit 0 (BYPASS) cleared, the 256 hash entries at PARF 0x2000 zeroed, then BDF 0x0100 -> SID offset 1 at
  hash crc8(0x01 0x00, poly 0x07, MSB first) = 0x15, value 0x01000100. Our survey pulses the PCIe core reset (step 7),
  so the table is at its reset state when the driver runs. Without it the chip's DMA may carry SID 0x1c00, not 0x1c01
  [I: the reset value of the bypass bit and the SID in bypass are not documented here]. 0325 prints CFG + the entry in
  every policy and programs it with policy 3. This also means the 0263 policy-1 check looked at a SID the chip may not
  use.
- ASPM: L0s/L1 control cleared on the endpoint (PCIe capability from the list) and on the root port (DBI 0x80) after
  the BAR0 claim, with one log line (ath11k pci.c `ath11k_pci_aspm_disable`, "problems switching to AMSS state").
- MHI CTRLBASE/DATABASE..LIMIT = the IOVA window 0xa0000000-0xafffffff when the context is on (cnss2 pci.c:5505-5507);
  0 .. 2^36-1 otherwise (old).
- `negroni_wlan_dma_map` with policy 3 never returns a physical address: no context = `WLAN_DMA_NONE` = the step stops.

Chain review against Linux MHI / ath11k (no change needed) [V code read]: BHI (STATUS 0, IMGADDR high/low, IMGSIZE,
IMGTXDB seq 29:0, status 31:30 = 2/3) = boot.c mhi_fw_load_bhi; BHIe (TXVECADDR 0x2c/0x30, SIZE 0x34, DB 0x3c, STATUS
0x44, vector of {u64 addr, u64 size} over the whole image) = mhi_fw_load_bhie / mhi_firmware_copy; READY -> init_mmio
(CCABAP/ECABAP/CRCBAP, NER 2 NHWER 0, wake db 0, window) -> event-ring doorbells -> M0 -> wake = pm.c order; EE SBL ->
BHIe -> EE AMSS = pm.c:767-781; every ring/context/TRE/vector/m3/segment/CE address goes through negroni_wlan_dma_map
(the pool IOVA is the base of every MHI address; event-ring pointers from the chip are compared in IOVA space); QMI
m3_info and RESPOND_MEM carry IOVAs; WMI INIT sends no host memory chunks (ath11k never sets num_mem_chunks,
wmi.c:4487). Every wait is bounded (negroniwlan_to, or MAX(to, 10 s)) and prints its state on time-out; the failure
path prints the SMMU line before the quiesce.

Not changed, open [I]: interrupts stay polled (no ITS); no SoC global reset before MHI (ath11k sw_reset); the camera
code (0312, `negronicam_smmu=2` only) also takes the first free SMR without a shared lock: do not combine
`negronicam_smmu=2` with a Wi-Fi boot.

### Test boot (the main session builds the image)

Boot-args: `negroniwifi=10 negroniwlan=10 negronipanic=30 negronipanicreason=2` (`negroniwlan_smmu=3` is the default;
write it out if the image should say so). Precondition: the WLAN firmware area on userdata. Lower `negroniwlan` to stop
earlier (4 = mission mode, 6 = FW_INIT_DONE). Fallback args if step 6 refuses: `negroniwlan_smmu_cb=N` (a context from
the summary line), or `negroniwlan_smmu=1` (old path).

Expected proof lines in order (all start `NEGRONI WLAN:`; IOVAs assume the pool is the first mapping):
1. `start: levels 2..10, time-out 10000 ms per wait, SMMU policy 3`
2. `step 2 BAR0 claim`, `BAR0 64-bit 0x200000 bytes at 0x60400000, MHI REGLEN ..`, `ASPM: endpoint LNKCTL .. -> ASPM 0, root port LNKCTL .. -> ASPM 0 ..`
3. `SoC version .. -> firmware amss20.bin|amss.bin`, `DMA pool 6885376 bytes at 0x8........`, `amss*.bin .. sha-256 OK`, `m3.bin .. sha-256 OK`
4. `step 6 DMA path (clocks, apps SMMU)`, `GCC ... vote 0x62000 = ..`,
   `PCIe BDF-to-SID: CFG .. (BYPASS b), entry 0x15 = ..`, `PCIe BDF-to-SID programmed: CFG .., entry 0x15 = 0x1000100 (BDF 0x100 -> SID 0x1c00 + 1)`
5. `SMMU S1 setup: sCR0 .., IDR0 .. IDR1 ..: 113 SMRs, 78 contexts, .. pages of 0x1000; sGFSR ..`
6. `SMMU SMRk free (was .., S2CR ..): will match 0x1c00-0x1c01 (mask 1)` (or `SMRk .. already matches 0x1c01 .. reused`)
7. `SMMU contexts: a S2_TRANS, b S1_TRANS_S2_BYPASS with VMID 0xff, c other (in use), d with SCTLR.M on, e targeted by an S2CR`
8. `SMMU context N free: CBAR .. (type t, VMID v) CBA2R .., FSR ..`
9. optional `SMMU NAME reads X after writing Y (bits .. not kept; not needed)`
10. `SMMU SMRk = 0x80011c00, S2CRk = 0xN, CBN CBAR 0x1f300 CBA2R 0x1 SCTLR 0x1107 TCR 0x803519 TCR2 0x38011 TTBR0 0xN0000........ MAIR0 0xf404ff44 FSR 0 (root ..)`
11. `stream 0x1c01 translates through context N; IOVA window 0xa0000000-0xafffffff (Android's)`
12. `SMMU map 0x8........ (0x691000 bytes) -> IOVA 0xa0000000`
13. `step 7 PBL check`, `BHI off .., execution environment 0, ..`; `step 8 BHI SBL download`, `BHI SBL 524288 bytes at 0xa0010000, session ..`
14. `level 2 done (step 8)`, `SMMU report (no context fault): context N FSR 0 (none) ... sGFSR ..`
15. `MHISTATUS READY ..`, `MHI ctx ch 0xa0000000 ev 0xa0001800 cmd 0xa0001900, chdboff .. erdboff .., window 0xa0000000-0xafffffff`, `MHI state M0, device wake asserted`, `execution environment SBL ..`, `level 3 done`, SMMU line
16. `BHIe image 11 (or 12) segments (.. byte vector) at 0xa0690000, seq ..`, `execution environment AMSS (mission) ..`, `SMMU map .. (0x90000 bytes) -> IOVA 0xa06a0000`, `channel 20 started`, `channel 21 started`, `channel 21: 16 RX buffers of 32768 bytes at 0xa06a0000`, `stage 1 complete ..`, `level 4 done`, SMMU line
17. levels 5-10 as in 0265-0323 (`QRTR HELLO`, `WLFW instance ..`, `segment i type T: .. bytes at 0x8.. (device 0xa.......)`, `firmware version ..`, `FW_INIT_DONE_IND`, `CE area .. (device 0xa.......)`, `HTC READY ..`, `WMI READY ..`, `BSS N: SSID ..`), one SMMU line after each level.

What to read when a step fails:
- `SMMU CBAR|CBA2R|CB TCR|CB TTBR0 ..|CB SCTLR reads X after writing Y (the hypervisor refused it?)`: the hypervisor
  does not give us that context bank. Boot again with `negroniwlan_smmu_cb=M` for another free number from the
  summary line (line 7 counts), or `negroniwlan_smmu=1`.
- `S2CR|SMR reads X ..`: the hypervisor refuses the stream entry for this SID (it may keep 0x1c0x for itself); read
  the `SMMU SMRk ..` lines of step 6.
- `no free SMMU context bank (U-Boot rule ..)`: every context is in use or has another type; the summary says which.
- BHI SBL / BHIe time-out with heartbeat lines and an `SMMU BHI SBL: context N FSR 0x2 (TF translation) FAR 0x...`:
  the chip read an IOVA we did not map; compare FAR with the `SMMU map` lines (pool 0xa0000000-0xa0690fff). FSYNR0
  says read/write, level and table walk (a walk fault = the root/table pages are not visible to the SMMU).
- `sGFSR .. (USF unidentified stream) .. sGFSYNR1 .. (SID 0x....)`: the chip uses a SID our SMR does not match
  (BDF-to-SID line: did it take?).
- Time-out and FSR 0 and no new sGFSR: the SMMU is not the cause; read the BHI status/errcode (chip side) as before.
- `PCIe BDF-to-SID .. DID NOT TAKE`: the mask-1 SMR still matches 0x1c00; go on and watch for USF.

### Next level design: scan results -> WPA2 station -> IP (0326+)

Shortest path to an associated link and an IP [I, from ath11k mac.c/wmi.c/dp*.c and the two reference ports]:
1. **Join, open first**: VDEV_START on the BSS channel (WMI 0x5003 path of ath11k wmi.c vdev_start), PEER_CREATE (AP
   MAC), AUTH (open) + ASSOC REQ built by us and sent with WMI_MGMT_TX_SEND (wmi.c mgmt_send), the AP's frames come in
   MGMT_RX (0323 already parses them), PEER_ASSOC (rates/HT/VHT caps from the beacon), VDEV_UP (AID, BSSID). Proof
   line: `JOIN: associated to "ssid" AID n`. ~700 lines; can be tested against an open AP without any data path.
2. **HTT data path (mandatory before WPA2)**: EAPOL frames are data frames, and ath11k only sends/receives data
   through HTT/DP rings: HTT version request, the SRNG setup for REO destination, rxdma refill, TCL data, WBM release
   (the ring IDs are already in the 0320 shadow list), RX descriptor parse (WCN6855 layout), TX by TCL. Every ring
   address through `negroni_wlan_dma_map` (IOVA). ~2000 lines (the largest block).
3. **WPA2-PSK 4-way handshake in the kernel**: port `external/hackios-xnu-kernel/wifi/lx/src/lx_wpa.{c,h}` (MIT,
   523 + 49 lines, own SHA-1/HMAC/PBKDF2/PRF/AES unwrap, host-tested against the standard vectors). It needs only
   PMK(passphrase, SSID), the two MACs, the RSN IE of our ASSOC REQ and the EAPOL frames; it returns the TK and the
   GTK. Then WMI_VDEV_INSTALL_KEY pairwise (CCMP) and group. This is shorter than a userland supplicant: iOS has no
   wpa_supplicant, and a userland one would need the en0/BPF path first. The first test takes SSID + passphrase from
   boot-args (`negroniwlan_ssid=`, `negroniwlan_psk=`; never logged).
4. **IP**: an `en0` IOEthernetController that passes 802.3 frames to/from the DP path (802.11 <-> 802.3 by the
   firmware's native-Wi-Fi/ethernet decap mode); configd/ipconfig then run DHCP. Before Settings works, a static test
   is `ifconfig en0` + `ipconfig set en0 DHCP` over SSH.
5. **Apple80211 glue (later)**: wifid/Settings need `SIOCGA80211`/`SIOCSA80211` on en0 + kernel events class 6 (scan,
   associate, RSSI, state), the ADT `mac-address-wifi0` = the WMI READY MAC; reference external/ios-sailfish
   0174-0179 and external/ios-spes 0113 (design only). docs/references-2026-10-27.md does not exist yet; read it
   when it appears before this step.

### 0325 and the 2026-10-27 SMMU panic (SMMU kernel agent; for the Wi-Fi owner)

The first boot with 0249 (audio through the shared stage-1 helper) panicked with an SEA on the CBAR restore of
context 74 (README-camera.md "2026-10-27: panic, every stage-1 writer default OFF"). 0325 has the same pattern
[V source]: `smmu_pick_cb` scans from context 0 (also the stage-2-only banks below IDR1.NUMS2CB) and teardown writes
`SW(GR1(SMMU_CBAR(g_cb)), g_old_cbar)` and the old CBA2R back; with a picked bank of CBAR type S2_TRANS that write
is the one Gunyah refused [I]. Linux (arm_smmu_destroy_domain_context) and HakiOS never write CBAR back.
Asked of 0325 (relayed by the main session; the Wi-Fi agent edits 0325):
- default `negroniwlan_smmu` 1 (report-only, stop before DMA) instead of 3 until `negronismmu_probe=1` was read;
- teardown: SCTLR 0 + TLB sync only, no CBAR/CBA2R write;
- bank choice: from `MAX(NUMS2CB, 1)`, skip `negroni_smmu_cb_verdict[c]` READ_ABORT/CLAIM_REFUSED/OURS
  (`negroni_smmu_s1.h`), claim writes (CBA2R, CBAR) through `negroni_mmio_try_wr32` (0297) and skip the bank on a
  refusal, take `negroni_smmu_claim_lock`, TLB sync time-out 500 ms (Linux).

## 0326-0329: API seam, join, HTT data path, WPA2-PSK (2026-10-27)

Made in `out/kernel/tree-wlan11` (patched-tree.sh, one commit per patch, review fixes folded in; deleted after).
Reference: Linux ath11k for WCN6855 hw2.x (mac.c, wmi.c, dp*.c, hal*.c, hw.c); WMI ids/tags computed from the
ath11k enums. Build-only: nothing of it has run on the phone. Order of the files in `bsd/conf/files`: after
`negroni_wlan_smmu.c`: `_sta.c`, `_join.c`, `_dp.c`, `_wpa.c`, `_wpa_crypto.c`.

### 0326: the seam for the iOS side (`bsd/dev/negroni_wlan_api.h`)

Plain C (IOKit includes it in `extern "C"`). `NWLAN_API_VERSION 1`; `negroni_wlan_api_caps()` returns
`NWLAN_CAP_SCAN` (0326), `_JOIN_OPEN` (0327), `_DATA` (0328, when the data path came up), `_WPA2_PSK` (0329, needs
DATA). Functions: `negroni_wlan_api_ready`, `negroni_wlan_register` (one client: `rx(ctx, 802.3 frame, len)`,
`event(ctx, NWLAN_EV_STATE|SCAN_DONE|LINK_UP|LINK_DOWN|RSSI)`), `negroni_wlan_link` (state, MAC from WMI READY, BSSID,
SSID, RSSI, freq, AID, security, last_error, 802.11 reason, counters), `negroni_wlan_scan` + `negroni_wlan_scan_results`
(newest first, with raw RSN/WPA/WMM/HT/VHT/rates elements), `negroni_wlan_associate(ssid, len, psk|NULL, psk_len)`,
`negroni_wlan_disassociate`, `negroni_wlan_tx` (802.3; ENOTCONN/ENOBUFS). Every call returns at once; the driver
thread does the work in the keep-alive pass and answers with events. Callbacks run on the driver thread and must not
block. Guarantees (review fixes): every associate ends with LINK_UP or LINK_DOWN (also a join that never reached
JOINING: no BSS -> ENOENT, wrong security -> ENOTSUP); every accepted scan ends with SCAN_DONE (normal end,
START_FAILED, 30 s time-out, or a join that takes over a not-yet-started scan). The API is usable after level 10
(state IDLE). No SSID and no key material in the log (SSID length only; also the 0323 `BSS N` lines now).

### 0327: join an open network

Sequence (ath11k, WCN6855 `vdev_start_delay`): BSS from the list (a scan first if none in the last 60 s), PEER_CREATE,
(0328) HTT peer map + DP peer setup, VDEV_START (20 MHz, channel mode HE20 like `ath11k_phymodes`), AUTH open (3 tries
x 500 ms) and ASSOC REQ by WMI_MGMT_TX_SEND (frame in a DMA slot), PEER_ASSOC (legacy + HT rates/caps from the AP's
elements, WMM -> QoS, `ath11k_peer_assoc_prepare` for 20 MHz), VDEV_UP, DTIM policy stick, powersave off, PEER
AUTHORIZE -> CONNECTED. Down: request, deauth/disassoc from the AP, PEER_STA_KICKOUT, ROAM beacon miss, 10 s without
a beacon -> DEAUTH (our request only), VDEV_DOWN, VDEV_STOP, PEER_DELETE, IDLE + LINK_DOWN.

### 0328: HTT data path (Ethernet frames)

`negroni_wlan_dp.c`, polled (a poller in the service pass, never sends WMI): common rings + 4096 link descriptors +
REO hash routing/aging + DSCP maps after the CE rings (before HTC READY, as `ath11k_dp_alloc`); REO2SW1..4 before WMI
INIT; HTT VERSION (must be 3.x) + LMAC rings (refill = host->fw rx buffers, 2 mac buf, 2 rxdma error, 2 monitor
status) + 7 HTT SRING_SETUP + monitor status filter off after WMI READY and the hw mode; per peer: HTT PEER_MAP,
PEER_SET_DEFAULT_ROUTING, 17 REO queues (WMI_PEER_REORDER_QUEUE_SETUP), vdev TX encap and RX decap Ethernet
(`frame_mode=2`). TX: one TCL descriptor per 802.3 frame (search default, ADDRY, TID 0, encrypt by the peer's key);
RX: REO2SW MSDUs (Ethernet decap; a native-Wi-Fi decap is converted; multi-buffer MSDUs are dropped), buffers
re-posted; REO exception / rxdma error rings recycle their buffers and give the link descriptors back. CE4 (HTT
host->target) added to the CE code. `negroniwlan_dp=0` skips all of it (0323 behaviour).
[I] Risks: the firmware may want the DP rings before WMI INIT exactly as here (done) and the monitor status ring
filled (done, filter off); REO PN check is not enabled (no replay check on RX); no A-MPDU RX reorder beyond window 2.

### 0329: WPA2-PSK

`negroni_wlan_wpa_crypto.{c,h}` = HakiOS `wifi/lx/src/lx_wpa.{c,h}` (MIT, notice kept, commit a52a4c9d; only the file
names, the include and `|| defined(KERNEL)` changed). Host test of the port with HakiOS `tools/wpa-test` (reference.py
access point, ASan/UBSan): **195 checks, 0 failed** [V]. `negroni_wlan_wpa.c`: passphrase 8..63 printable or 64 hex
(PMK), nonce from `read_random`, our RSN element (group CCMP, pairwise CCMP, AKM PSK, capabilities 0 = no MFP),
EAPOL queued by the poller and handled at the top level, message 4 sent and drained before WMI_VDEV_INSTALL_KEY
pairwise (idx 0) + group (its idx, RSC), INSTALL_KEY_COMPLETE checked, then PEER AUTHORIZE -> CONNECTED + LINK_UP;
group rekey answered; 10 s / bad MIC -> down with reason 15. Not supported: TKIP group, WPA1, SAE/WPA3, MFP-required
networks, 802.1X.

### Test boot (after the bank probe allows `negroniwlan_smmu=3`, or with the old DMA path)

`negroniwifi=10 negroniwlan=10 negronipanic=30 negronipanicreason=2` (+ `negroniwlan_smmu=3` when allowed). The join
needs a client (the iOS side) calling `negroni_wlan_associate`; this stage adds no boot-arg SSID/passphrase.

New proof lines (all `NEGRONI WLAN:`), in order after the 0321 CE lines:
1. `DP common rings up: 4095 link descriptors, TCL data 64, tx completion 256, REO exception 128, ring area .. bytes at device 0x..; TCL data base reads X (wrote X)`
2. after SERVICE_READY: `DP REO2SW1..4 up (256 entries each)`
3. after the hw mode: `HTT target version 3.N`, `DP pdev rings up: 511 rx buffers on the refill ring, 126 on the monitor status rings, 7 HTT SRING_SETUP sent, monitor status filter off`
4. `API state 1 -> 2` (STARTING -> IDLE) after level 10
5. on an associate: `JOIN 02:..:..:xx:xx:xx, F MHz, RSSI .., security ..`, `DP peer id N mapped, ...`, `JOIN vdev 0 started on F MHz`, `JOIN AUTH accepted (...)`, `JOIN ASSOC accepted (status 0, AID n, ...)`, `JOIN PEER_ASSOC: ...`, `JOIN associated (SSID of N bytes) AID n`
6. WPA2: `WPA2: PMK ready in .. ms`, `WPA2: message 1 -> message 2`, `WPA2: message 3 (MIC good) -> message 4; installing the keys`, `WPA2: pairwise + group key K installed (CCMP)`, `API state 5 -> 6` (CONNECTED)
7. keep-alive every 60 s: `DP tx N (fail ..), rx N (drops .., errors .., bad ..), ...`

What to read if it fails: `TCL data ring base does not read back` = the UMAC registers are not reached through the
window; no `HTT target version` = HTT on CE4/CE1 broken; `HTT PEER_MAP` time-out = peer not created or HTT RX lost;
`VDEV_START status N` = channel/mode refused; `JOIN AUTH FAILED (status 0xffff, k sent, j completed, f failed)`:
j = 0 means the mgmt TX DMA never completed (SMMU/IOVA: read the SMMU fault line); `WPA2 ... signature` = wrong
passphrase; `INSTALL_KEY ... refused` = key format; RX counters stay 0 while TX completes = REO queues / routing.

### What the Apple80211/en0 side needs from here (for the iOS-side agent)

en0 MAC = `nwlan_link.mac`; scan results with raw elements for SCAN_RESULT; associate/disassociate/link events for
ASSOCIATE/ASSOCIATE_RESULT/DISASSOCIATE and link up/down; RSSI events; 802.3 TX/RX. Not provided yet: active scan,
hidden-SSID join by probe, roaming, power save, 40/80 MHz, statistics beyond the counters.

## 0325 rework after the 0249 panic decode (2026-10-27, SMMU agent findings)

The SMMU agent decoded the 0249 panic: FAR = GR1 CBAR(74); the helper had picked a stage-2 bank and Gunyah refused the
CBAR write (SEA). 0249 now follows Linux sm8450 arm-smmu.c, and 0297 adds `negroni_mmio_try_rd32/wr32` (an SEA is
caught through the expected-fault hook and returned as an error). 0325 now does the same:
- banks from `MAX(IDR1.NUMS2CB, 1)` upward (stage-1 banks start after the stage-2 banks, Linux);
- a bank whose `negroni_smmu_cb_verdict[c]` (0249 probe `negronismmu_probe=1`, or the helper) is READ_ABORT,
  CLAIM_REFUSED or OURS is skipped; every read of a candidate (CBAR, CBA2R, SCTLR) is a try-read (an abort marks it
  READ_ABORT);
- the claim is the test: SCTLR 0, CBA2R VA64, CBAR 0x1f300 through `negroni_mmio_try_wr32`, each read back; a refused or
  not-kept write marks the bank CLAIM_REFUSED and the scan goes to the next bank (at most 8 claims); a good claim marks
  it OURS;
- teardown: SCTLR 0 + TLB sync only; CBAR and CBA2R are never written back (the bank stays OURS); S2CR/SMR are restored
  only when they were proven writable;
- TLB sync time-out 500 ms (setup and map/unmap); `negroni_smmu_claim_lock` held from the scan to the last SMR write;
- the default stays `negroniwlan_smmu=1`; `=3` after the probe shows usable banks.

New lines: `SMMU contexts from N (NUMS2CB M): ..., K skipped (probe/helper verdict or read abort), R claims refused`,
`SMMU context C: claim refused or not kept (CBAR was X, reads Y); left as it is, next bank`,
`SMMU context C claimed: CBAR was X (type t, VMID v) CBA2R Y, now CBAR 0x1f300 CBA2R 0x1`,
`SMMU context C off (SCTLR 0 1; S2CR s SMR m restored; CBAR/CBA2R left claimed)`.

## Review fixes 0325/0328/0329 and 0339 SBL boot dump (2026-10-27, after phone test t6)

Phone t6 (kernel local-20261026-214005, `negroniwlan=10 negroniwlan_smmu=3`) [V, logs/usblog-t6.txt]: the stage-1 claim
works under Gunyah (context 6, SMR6 0x80011c00, S2CR6 0x6, pool at IOVA 0xa0000000), `BHI SBL 524288 bytes at
0xa0010000` finished at once, then MHISTATUS 0 and EE 0 for 10 s (step 9), SMMU context FSR 0 and sGFSR 0 (no fault).
MHI VER reads 0xdeadbeef in PBL (REGLEN 0x100, BHIOFF 0x100, BHIEOFF 0x224).

Review fixes (Opus review, applied):
- 0325: claim order CBA2R, CBAR, then SCTLR 0 only after a good claim and only when SCTLR != 0 (as 0249); also skip
  banks with verdict REWRITE_REFUSED / REWRITE_CHANGED; a bank with TLBSTATUS busy is skipped; try-accessor -2 (no
  XNUPOST) stops the claim instead of marking READ_ABORT; the SMR reuse rule is the helper's (exact SMR value of ours +
  S2CR fault/bypass); every TLB sync result is checked (map refuses the IOVA on a time-out).
- 0328: D1 link-descriptor addresses must be 128-byte aligned inside our bank; D2 a cookie for a buffer the hardware
  does not own is counted and dropped, a full refill ring keeps the buffer on a repost list; D3 hardware pointers must be
  entry-aligned; D4 TCL metadata pdev id 0 (single pdev); D5 REO PN replay check (REO UPDATE_RX_QUEUE on the 17 TID
  queues) after the pairwise key; D6 after the keys only decrypted frames pass (EAPOL from the BSSID excepted); D7 the
  data path is a soft part (a `DP OFF after ...` line, no NWLAN_CAP_DATA, scan goes on; DMA areas stay allocated);
  per-ring multi-buffer skip state, HTT PEER_UNMAP of the AP takes the link down, TX/RX ownership state reset on
  (re)init, the TX queue cleared at link up, a link descriptor that does not fit SW2WBM waits on a list.
- 0329: W1 a retransmitted message 3 after the keys gets message 4 only (no PTK re-install, no second done), an identical
  GTK is never installed twice; W2 message 1 derives a temporary PTK, committed only by a good message 3 (wpa_supplicant
  TPTK), and message 1 outside our handshake is ignored (no PTK rekey); W3 the GTK must be 16 bytes with index 1..3; W4 a
  failed group-rekey install takes the link down with a line; plus: message 3 needs the INSTALL bit and the AP's beacon
  RSN element, INSTALL_KEY_COMPLETE must match vdev/index/flags/AP MAC, the bad-MIC decision by pointer
  (`LX_WPA_WHY_MIC`), secrets wiped with a volatile loop in the port. [V] host test of the changed port: HakiOS
  tools/wpa-test adapted (TPTK checks + "message 1 after message 3 keeps the PTK"): 231 checks, 0 failed (ASan/UBSan).

0339 (`patches/xnu/0339-negroni-wlan-sbl-boot-dump.patch`, read-only diagnostics, cnss2 `cnss_boot_debug_timeout_hdlr`):
`BOOT <when>: MHI ...`, `BOOT <when>: BHI IMGADDR .. IMGSIZE .. TXDB .. INTVEC .. EXECENV .. STATUS .. ERRCODE .. ERRDBG ..`,
`BOOT <when>: TCSR_PBL_LOGGING .. SBL log at .. size .. PBL_WLAN_BOOT_CFG .. PBL_BOOTSTRAP_STATUS .. WLAON_WL_PWR_STATUS ..
SCRATCH ..`, `BOOT <when>: PBL log ..` (10 words), `BOOT <when>: SBL log ..` (12 words) or `no SBL log`; when = `before
BHI`, `BHI SBL` (right after DONE), `waiting for READY` (every 3 s), `READY time-out`. Also `SBL image in RAM: 7f 45 4c 46
.. (ELF)`, `BHI before the doorbell: IMGADDR 0:a0010000 (wrote 0:a0010000) IMGSIZE 0x80000 ...`, `BHI SBL done after N ms,
status 0x8.......`, `waiting for READY: execution environment E after N ms`. READY now waits MAX(negroniwlan_to, 30 s).
How to read it [I]: STATUS 0x8xxxxxxx + ERRCODE 0 + PBL log ending in an auth/hash error code = the PBL rejected the SBL
(image content or the chip saw other bytes: check the ELF line and SMMU); EE moving to 1 (SBL) without READY + an SBL log =
the SBL runs and stops on something (its log says what: clocks, rails, DDR); TCSR_PBL_LOGGING unchanged from `before BHI`
= the PBL never jumped. Next steps follow from these lines (no guess here).

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
- 0329 `negroni_wlan_wpa_crypto.{c,h}` is copied code: HakiOS `wifi/lx/src/lx_wpa.{c,h}` under the MIT License
  (Copyright (c) 2025-2026 the HakiOS authors); the full notice is at the top of both files. Everything else in
  0325-0329 is our own code from the ath11k / U-Boot / pci-msm values and sequences.

## 0340-0341: iOS side (Settings, wifid, en0, Apple80211) (2026-10-27)

Files: `bsd/dev/negroni_wlan_ios.{c,h}`, `iokit/Kernel/arm/NegroniWLAN.cpp` (0340), `bsd/dev/negroni_apple80211.c`
(0341); hook: one call in `negroni_wifi_init()`; conf lines at the end of `bsd/conf/files` and `iokit/conf/files.arm64`.
0340 alone does not link: apply both. Build-only: not run on the phone.

### Why Settings greys out Wi-Fi (only Control Center "turns it on")

- [V root `System/Library/xpc/launchd.plist` + `LaunchDaemons/com.apple.wifid.plist`] the wifid job has
  `_LimitLoadToDeviceTree = ("wlan", "marconi-wifi")`.
- [V `sbin/launchd` 20H392 disasm 0x10003d1f0] launchd checks the key with `host_get_special_port(IO main port)` and
  MIG id 2887 = `io_device_tree_entry_exists_with_name` (device.defs), which is
  `IODTFindMatchingEntries(root, kIODTRecursive, name)` (IOUserClient.cpp): an entry of that name anywhere in the
  IODeviceTree plane.
- [V ADT] `out/ios16/negroni.adt` has no `wlan` and no `marconi-wifi` node. So launchd never loads wifid.
- [V phone logs `logs/phone-log-20261027-004129.txt`] `mDNSResponder (MobileWiFi) bootstrap_look_up of WiFiManager
  server failed` (122x), `rapportd SysMon: ### WiFiManagerClientCopyDevices failed: NULL` (324x); no wifid process line.
- [I] Settings shows the Wi-Fi switch disabled when WiFiManager has no device; Control Center only flips its own
  state (no wifid answers), so it seems to "turn on" but nothing happens.
- HakiOS met the same gate: `userland/mkjobs.py:271-273` deletes `_LimitLoadToDeviceTree` from the jobs it writes.
  We make the entry in the kernel instead (no root change).

### What iOS matches [V strings of the 20H392 cache / root]

- IO80211.framework: `IO80211Controller` ("No Matches for IO80211Controller, trying dk matching"), `IOPropertyMatch`
  `IO80211InterfaceRole` = `Infrastructure`, `IOInterfaceName`; `IOServiceOpen failed` -> `Falling back to IOCTL path`;
  interfaces are skipped unless `SIOCGIFMEDIA` works.
- wifid: `IO80211InterfaceRole`, `IOInterfaceName(Prefix)`, `IOPropertyMatch`, `Apple80211Open failed`, `service for
  Class "wlan" NOT found` / `com.apple.wlan.init_failure` (log only [I]); registers `com.apple.wifi.manager`.
- XNU [V bsd/net/if.c:3548-3564]: an unknown interface ioctl goes to `pru_control`, then on EOPNOTSUPP to
  `ifnet_ioctl` -> the driver's `if_ioctl`. So SIOCGA80211/SIOCSA80211 reach en0 without any user client.
- MobileGestalt: the Wi-Fi row exists already (D22 identity, `mac-address-wifi0` in `/chosen`); no change.

### What 0340/0341 do (port of HakiOS `hakios.wlan.cpp`, `hakios.net.c`, `hakios.sta.c`, `hakios.apple80211.c`, APSL 2.0)

1. Boot, from `negroni_wifi_init()` (UFS init, before launchd): an IODeviceTree entry `wlan` under `/arm-io`
   (name/compatible `wlan-pcie,negroni`/device_type), only if no entry has that name. launchd then starts wifid.
2. Thread `negroni-wlan-ios`: waits for `lo0`, then (negroniwlan_ios=1) for `negroni_wlan_api_ready()` (state IDLE,
   up to `negroniwlan_ios_wait` s, default 600; it gives up on FAILED), checks `NWLAN_API_VERSION` 1, takes the MAC
   from `negroni_wlan_link()` (WMI READY; fallback ADT `mac-address-wifi0`), attaches **en0** (IFNET_INIT_LEGACY |
   NX_NOAUTO, Ethernet, subfamily Wi-Fi, IFT_ETHER, bpf), registers the seam callbacks, publishes
   `NegroniWLANController` (class `IO80211Controller`, `IOMACAddress`, `IOBuiltin`) and below it `NegroniWLAN` (class
   `IONetworkInterface`: `IOInterfaceName`/`BSD Name` en0, prefix, type 6, unit 0, `IOBuiltin`, `IOPrimaryInterface`,
   `IO80211InterfaceRole` Infrastructure, `newUserClient` -> unsupported).
3. en0 ioctls: SIOCGIFMEDIA = IEEE80211|AUTO, ACTIVE while the link is up; MTU, flags; everything else -> Apple80211.
4. Apple80211 (0341): gets 1 SSID, 2 AUTH_TYPE, 4 CHANNEL, 9 BSSID, 11 SCAN_RESULT (one BSS per call, EIO at the end;
   elements = SSID + the seam's RSN/WPA/HT/VHT/rates), 12 CARD_CAPABILITIES, 13 STATE, 15 OP_MODE, 16 RSSI, 19 POWER,
   21 ASSOCIATE_RESULT, 27/254 channels, 207 CHANNELS_INFO, 43/44 names, 103 CURRENT_NETWORK; sets 10 SCAN, 19 POWER,
   20 ASSOCIATE (passphrase cipher 10, or PMK cipher 6 -> 64 hex digits), 22 DISASSOCIATE. Layouts from HakiOS (16.5
   20F66, static asserts kept) [I: same in 16.7].
5. Events: class 6 (KEV_IEEE80211_CLASS) subclass 1, data = "en0" in 16 bytes: 1 POWER_CHANGED, 2/3 SSID/BSSID
   changed, 4 LINK_CHANGED (+32 bytes), 9 ASSOC_DONE (result 1 ok, 21 wrong key, 9 time-out, 2 other), 10 SCAN_DONE.
   en0: KEV_DL_LINK_ON/OFF (configd starts DHCP on ON).
6. Soft radio switch (the seam has no power call): POWER off = disassociate, link down, scans/joins -> ENETDOWN; on =
   allowed again. Control Center and Settings both send set 19, so both now go through the same path.
7. Refusals become events: a scan the driver refuses (EBUSY while joining) still ends in SCAN_DONE with the last list;
   a join the driver refuses (ENOTSUP before 0327-0329, EBUSY, EINVAL) ends in ASSOC_DONE result 2, so Settings says
   "Unable to join" and does not hang. Link down with 802.11 code 15/23 (or 2 while joining) = wrong key (21).
8. Review fixes (Opus review 2026-10-27, F1 F3-F6):
   - F1/F3: each join has a sequence number under the lock (set on the ioctl thread, ended on the worker). One
     `reconcile()` per 100 ms tick decides from `negroni_wlan_link().state`, not from the order of the event bits.
     Success = CONNECTED to the asked SSID; failure = refusal, leave, radio off, driver FAILED/OFF, idle after a
     LINK_DOWN with an error, or **40 s time-out** (ETIMEDOUT -> result 9, and the driver is told to disassociate).
     A network switch (LINK_DOWN old + LINK_UP new in one mask) ends with en0 up on the new BSS (down + up, so configd
     runs DHCP again) and the new join reported once.
   - en0 is up exactly while the radio is on and the driver is CONNECTED; NWLAN_EV_STATE is handled, so CONNECTED ->
     FAILED/OFF takes en0 down without a LINK_DOWN.
   - F4: no SSID in the log (length only).
   - F5: root only (`kauth_cred_issuser`) for every set and for gets 1 SSID, 9 BSSID, 11 SCAN_RESULT,
     103 CURRENT_NETWORK; EPERM otherwise. [V] wifid runs as root (no `UserName` in its job, launchd cache 20H392).
   - F6: RX uses one mbuf with a 2 KiB cluster (mbuf_gethdr + mbuf_mclget + memcpy + setlen), as ue0 does
     (negroni_usb.c: `mbuf_allocpacket` + header strip panicked "Failed mbuf validity check: len -14").

### The seam used (0326 `negroni_wlan_api.h`, version 1)

`negroni_wlan_api_version/caps/ready`, `negroni_wlan_register` (rx: 802.3 frame; event: SCAN_DONE, LINK_UP,
LINK_DOWN; callbacks only set bits + wake our thread, RX goes straight to `ifnet_input`), `negroni_wlan_link`,
`negroni_wlan_scan` + `negroni_wlan_scan_results`, `negroni_wlan_associate(ssid, psk|NULL)`,
`negroni_wlan_disassociate`, `negroni_wlan_tx`. Missing in the seam (wanted later): power on/off, a regulatory
channel list (we send a world-safe list: 2.4 GHz 1-13, 5 GHz 36-165, 52-144 DFS/passive), noise, TX rate.

### Boot-args

| Arg | Default | Meaning |
|---|---|---|
| `negroniwlan_ios` | 1 | 0 off; 1 on when `negroniwlan` >= 10 (en0 when the driver is IDLE); 2 fake radio: no chip, en0 at once, networks `NEGRONI-FAKE-WPA2` (passphrase `negronifake`), `NEGRONI-FAKE-OPEN`, `NEGRONI-FAKE-5G`; joins without data |
| `negroniwlan_ios_log` | 400 | Apple80211 request lines |
| `negroniwlan_ios_wait` | 600 | seconds to wait for the driver API |

Test 1 (UI only, no chip risk): add `negroniwlan_ios=2` (keep or drop `negroniwifi`/`negroniwlan`).
Test 2 (real): `scripts/ios16/variants/everything.args` as it is (`negroniwifi=10 negroniwlan=10`; `negroniwlan_ios=1`
is the default).

### Expected kernel lines (all `NEGRONI WLAN iOS:`)

1. `driver backend; IODeviceTree "wlan" made (launchd starts wifid)` (fake: `fake backend; ...`)
2. real: `waiting up to 600 s for the driver API (state IDLE)`; on a driver failure: `no en0: the driver API is not
   ready (state 7, error N); wifid runs without an interface`
3. `en0 attached (driver backend, caps 0x1, MAC xx:xx:xx:..), link down; Apple80211 ioctls on`,
   `IO80211Controller + IONetworkInterface (en0, IO80211InterfaceRole Infrastructure) registered`,
   `Apple80211 event: power, 1`
4. `user client type N asked of en0's service: none (ioctl path)` (proof that wifid/IO80211.framework found the service)
5. `wifid gets 19 (POWER) ...: answered`, `wifid gets 12 (CARD_CAPABILITIES) ...`, `wifid sets 10 (SCAN_REQ) ... (a
   scan: ...): answered`, `scan done, N networks for wifid`, `Apple80211 event: scan done, 0`, `wifid gets 11
   (SCAN_RESULT) ...` N times then `error EIO (end of list)`
6. a join: `wifid sets 20 (ASSOCIATE) ... (a join: a name of N bytes, any access point, ..., a key of M bytes of kind 10)`;
   with 0326 only: `join K refused by the driver (error 45, caps 0x1)`, `Apple80211 event: join done, 45`; with the real
   join: `connected: a network name of N bytes, F MHz, RSSI R`, `en0 link UP (KEV_DL_LINK_ON: configd starts DHCP)`,
   `Apple80211 event: join done, 0`; a join with no answer: after 40 s `join K failed: error 60, ...` (ETIMEDOUT)
7. 180 s after en0: `Apple80211 summary: K request kinds` + one line per type (which requests wifid needs and which
   we refuse: the next work list).

What the owner should see: Settings > Wi-Fi switch no longer greyed; on: "Searching", then the networks the driver
heard (fake: the 3 NEGRONI-FAKE names) with lock icons for WPA2; off/on from Settings and Control Center both work.
Joining a real network: "Unable to join" until the driver's join/data/WPA2 (0327-0329) set the caps bits; then the
tick, DHCP on en0, and the status-bar Wi-Fi icon. Fake joins tick the network but carry no data (no IP).

### Open [I]

- The Apple80211 layouts are HakiOS's 16.5 reading; 16.7 may differ in a type wifid needs (the per-type summary shows
  refusals and errors).
- wifid may want more types than HakiOS answers (e.g. 8 RATE, 17 NOISE, 51 COUNTRY_CODE, 54 RADIO_INFO): read the
  summary, add them.
- en0 MAC (chip) and `/chosen mac-address-wifi0` (02:00:5e:77:ee:10) differ: MobileGestalt shows the ADT one.
- The class names `IONetworkInterface` and `IO80211Controller` are the real families' names on purpose (iOS matches
  them). They collide if IONetworkingFamily or IO80211Family is ever staged into this kernel (Sailfish 0175 style):
  then drop these two classes and subclass the real ones.
- Context: 0340/0341 append to the end of `bsd/conf/files`; the `negroni_wifi.c` hunk sits at the top of
  `negroni_wifi_init()`.

## 0342-0343: SBL never reaches MHI READY: ath11k power-up reset + PCIe/WLAON boot dump (2026-10-27)

### What the phone showed [V]

- t6 (logs/usblog-t6.txt) and the 0339 boot (main session, `negroniwifi=10 negroniwlan=10 negroniwlan_smmu=3`): the
  SMMU stage-1 claim works (context 6), `BHI SBL 524288 bytes at 0xa0010000` ends with status DONE, no context or global
  SMMU fault, then EE 0 and MHISTATUS 0 for the whole READY wait (10 s in t6, 30 s with 0339).
- 0339 line: `BOOT waiting for READY: no SBL log (start 0 size 0x30 outside the SRAM)`: PCIE_BHI_ERRDBG2 (the SBL log
  pointer, cnss2 reg.h 0x01e0e238) is 0. The full 0339 dump of that boot is not in this repo (only this line was
  handed over).

### What we send, compared with Linux [V source]

| Check | Ours | Linux / cnss2 | Same? |
|---|---|---|---|
| Image | first 512 KiB of `amss20.bin` over BHI, then BHIe of the whole file | cnss2 pci.c:5584-5586 `sbl_size = seg_len = SZ_512K`, `fbc_download = true`; boot.c:493 `size = sbl_size` | yes |
| File name | SoC version 0x400c0210, major & 0xf = 2 -> `amss20.bin` | cnss2 `cnss_pci_update_fw_name`: QCA6490 major 2 -> FW_V2_FILE_NAME `amss20.bin` | yes |
| BHI registers | STATUS 0, IMGADDR high/low, IMGSIZE, TXDB = random & 0x3fffffff; INTVEC 0 | boot.c:276-282 + pm.c:1123 | yes |
| DMA address | IOVA 0xa0010000 (32-bit, inside Android's 0xa0000000 window) | ath11k DMA mask 32 bit; cnss2 iova_start from the DT | yes |
| SBL log read | ERRDBG2/3 through the window, valid range 0x01400000-0x01800000 | cnss2 pci.c:1400-1420 | yes |
| MHICTRL RESET / SOC reset before BHI | none | ath11k pci.c:380 `ath11k_pci_sw_reset(ab, true)` before every power-up; cnss2: none, but it power-cycles all rails | **no** |
| MSI | not enabled (no ITS) | ath11k/cnss2 enable MSI before MHI power-up | **no** (guess: not needed for READY) |

Conclusion [I]: the transfer is right and the PBL accepts it (DONE). The SBL then never starts its MHI side (no
READY, no EE change, no log pointer). The one step Linux does and we do not is ath11k's reset sequence. ath11k gives
two reasons that match a "BHI DONE, then silence" chip:
- `ath11k_pci_clear_all_intrs`: "When target receive Hotreset, but will set the interrupt. So when download SBL again,
  SBL will open Interrupt and receive it, and crash immediately." Our survey trains the link up to 3 times.
- `ath11k_pci_clear_dbg_registers`: "write 0 to WLAON_WARM_SW_ENTRY to prevent Q6 from continuing warm path and
  entering dead loop"; WLAON_SOC_RESET_CAUSE is read-clear "to prevent Q6 from entering wrong code path". The WLAON
  block sits on the aon rail (pmr735a_s2), which we vote on and never cycle; it can keep an earlier boot's state.
cnss2 can skip all of this because Android turns every WLAN rail off between runs.

### 0342-negroni-wlan-ath11k-sw-reset.patch (boot-arg `negroniwlan_swreset`, default 0)

At step 7, before the PBL check: `wlan_sw_reset()`, the ath11k order (ath11k pci.c:380-396):
- `=1`: 100 ms; PARF_LTSSM (0x01e081b0) = 0x111 (up to 5 writes) and GCC_PCIE_HOT_RST (0x01e402bc) |= 0x10, 5 ms;
  PCIE_INT_ALL_CLEAR (0x01e08228) = 0xffffffff; WLAON_QFPROM_PWR_CTRL (0x01f8031c) &= ~0x4; BHIe TXVECDB/TXVECSTATUS/
  RXVECDB/RXVECSTATUS = 0 (relative to MHI_BHIEOFF: ath11k's fixed 0x360.. assume QCA6390's BHIe 0x324, this chip
  reports 0x224); Q6 cookie read; WLAON_WARM_SW_ENTRY (0x01f80504) = 0 with 10 ms before and after;
  WLAON_SOC_RESET_CAUSE (0x01f8060c) read (clears it).
- `=2`: `=1` + PCIE_SOC_GLOBAL_RESET (BAR0 0x3008) bit 0 for 10 ms, then off, 10 ms; the window cache is forgotten
  (the reset clears the window register: `negroni_wlan_window_forget`); the endpoint BAR0 and command register are
  checked and restored if the reset cleared them; MHICTRL = RESET (ath11k_mhi_set_mhictrl_reset), the time until the
  PBL clears it is logged (max 1 s).
- With `>=1`, a PBL with SYSERR is reset as pm.c:1141-1164 does (MHICTRL RESET, wait, BHI_INTVEC 0) instead of a stop.
- fix_l1ss: not done (ath11k core.c: false for WCN6855 hw2.0/hw2.1).

Lines (`NEGRONI WLAN: `): `start: ... SW reset N`; `SW RESET off (negroniwlan_swreset=0) ...` or `SW RESET level N
(...)`, `SW RESET: PARF_LTSSM A -> B (N writes), GCC_PCIE_HOT_RST A -> B`, `SW RESET: PCIE_INT_ALL_STATUS A -> B after
INT_ALL_CLEAR (PARF_INT_STATUS .., mask ..)`, `SW RESET: QFPROM_PWR_CTRL .. -> .., BHIe 0x224 vectors cleared, Q6
cookie .., WARM_SW_ENTRY A -> 0, SOC_RESET_CAUSE ..`; with `=2`: `SW RESET: GLOBAL_RESET A -> B, BAR0 .. command ..
[(restored)], MHISTATUS was .., MHICTRL RESET written: MHICTRL .. after N ms, MHISTATUS .., SOC_WAKE ..`; failure:
`PCIE_SOC_GLOBAL_RESET reads 0xffffffff after the reset (link down); stop`.

### 0343-negroni-wlan-boot-dump-pcie.patch (boot-arg `negroniwlan_bootdbg`, default 1, read only)

Each 0339 BOOT dump gets 4 more lines: `BOOT <when>: PCIe INT_ALL_STATUS .. PARF_INT_STATUS .. INT_ALL_MASK ..
PARF_LTSSM .. PM_STTS .. HOT_RST .. GLOBAL_RESET .. SOC_WAKE ..`, `BOOT <when>: WLAON SOC_POWER_CTRL .. Q6_COOKIE ..
WARM_SW_ENTRY .. RESET_DBG_SW_ENTRY .. DEBUG .. WLPM_SIGNAL .. PBL_STACK_CANARY .. POWERCTRL_PMU .. PCIE_PWR_CTRL ..
QFPROM_PWR_CTRL ..`, `BOOT <when>: host PCIe endpoint CMD/STS .. DEVCTL/STA .. MSI ..; root port CMD/STS .. SEC_STS ..
DEVCTL/STA ..`, `BOOT <when>: verdict: ...` (pending chip PCIe interrupts / WARM_SW_ENTRY set / the chip received an
abort on a DMA read / root-port error bits / no PCIe/WLAON error bit). WLAON_SOC_RESET_CAUSE is not read here
(read-clear).

### Test (main session builds the image; no phone work by this agent)

Boot-args, one boot each, in this order:
1. `negroniwifi=10 negroniwlan=10 negroniwlan_smmu=3` (0343 only: the dump shows whether interrupts are pending or a
   warm entry is set before BHI; nothing is written).
2. `... negroniwlan_swreset=1` (the clears, no SoC reset).
3. `... negroniwlan_swreset=2` (the full ath11k sequence) if 2 still shows no READY.

How to read it [I]:
- `before BHI` verdict names pending interrupts or WARM_SW_ENTRY, and swreset=1/2 gives `MHISTATUS READY ... after N
  ms, execution environment 1` -> the cause is found; make swreset the default.
- `host PCIe endpoint CMD/STS` with bit 28/29 (0x10000000 / 0x20000000) after BHI -> the chip's DMA read got an abort:
  the DONE was not a good transfer (IOVA/SMMU/BDF-to-SID), not an SBL problem.
- EE 1 seen, then no READY, an SBL log appears -> the SBL runs and stops on something its log names.
- All clear, swreset=2 still EE 0 and `WLAON DEBUG`/`PBL_STACK_CANARY` unchanged between `BHI SBL` and `waiting for
  READY` -> the SBL never ran: next suspects (guesses) are the XO_CLK latch at WLAN_EN (cnss2 QCA6490 only), the
  antenna-switch/rfa rail modes, and MSI (enable it with the DWC iMSI doorbell).

### 0342/0343 Opus review (2026-10-27): ACCEPT for level 1 and 0343; level 2 opt-in with known risks
- Level 2: the GLOBAL_RESET readback is a plain read; if the SM8450 root port answers a dead link with a bus error
  (not all-ones), it panics. Fix later: read it with `negroni_mmio_try_rd32`. After "link down" the failure path
  (`wlan_quiesce`) writes endpoint config space on a dead link (not checked). BAR0 check/restore use the low dword only.
- 0343 verdict wording: INT_ALL_STATUS 0x2000/0x2400 are probably bit 13 LINK_UP and bit 10 MMIO_WRITE (pcie-qcom-ep
  layout, a guess for WCN6855), normal events; ath11k names only bit 1 (SMLH_REQ_RST_LINK_DOWN). Level 1 clears them anyway.

## 0344: MSI into a RAM mailbox (boot-arg `negroniwlan_msi`, default 0) (2026-10-27)

### Why [V phone, I cause]

- [V] With 0342 level 1 and level 2: BHI SBL DONE (status 0xbe92258b = DONE + session id), then EE 0, MHISTATUS 0,
  READY time-out after 30 s, no SMMU fault. Level 2 works as a reset (MHISTATUS 0xff04 SYS_ERR right after it, MHICTRL
  RESET clears it), but the SBL still does not come up. TCSR_PBL_LOGGING changes once (0xef150600 -> 0xef0e0200),
  then nothing. The SBL never writes its log pointer (PCIE_BHI_ERRDBG2 stays 0).
- [V] The endpoint MSI capability at 0x50 reads 0x10a7005: MSI off, 32 vectors (MMC 5), per-vector mask, 32-bit
  address only.
- [V source] ath11k (`ath11k_pci_alloc_msi`) and cnss2 (`cnss_pci_enable_msi`) always enable MSI before the MHI
  power-up. On Android the PCIe0 MSIs go to the GIC ITS. This port has no ITS setup, so the MSI stayed off.
- [I] Guess: the SBL (or the PBL hand-off) may wait for, or depend on, a working MSI configuration. 0344 tests this
  without an interrupt controller: the MSI target is RAM.

### What it does

At step 7, after the PBL check and before the `before BHI` dump (`wlan_msi_setup`):
- Bit 1 (`negroniwlan_msi=2` or `=3`): PCIE_SOC_WAKE (BAR0 0x3004) = 1, 5 ms, the readback is logged. Bisect only. The
  value stays 1.
- Bit 0 (`=1` or `=3`): a bounded walk of the endpoint list finds the MSI capability (ID 5). The address is the IOVA
  of the pool word at `OFF_MSI` 0x8000. That page is free: the IPCR in ring ends at 0x6400 (0x6000 + 64 x 16 B) and the
  firmware starts at 0x10000 (a `_Static_assert` checks it). The pool is one SMMU mapping (`negroni_wlan_dma_map` of
  the whole pool at step 6), so the word is mapped read/write in our context. Data base 0xa500 (32-aligned: the chip
  puts the vector number in bits 4:0). All 32 vectors unmasked, MME = MMC, then MSI enable. The mailbox holds
  0xffffffff before the enable.
- Checks before the enable (each one gives one line and leaves MSI off, no stop): pool device address present;
  `negroniwlan_smmu=3` with an active context (the pool's physical address is above 4 GiB, so the identity path
  cannot work); the whole pool and the mailbox inside the SMMU window 0xa0000000-0xafffffff; a 32-bit address when the
  capability has no 64-bit address; MSI not already enabled.
- Root port iMSI-RX (review 2026-10-27): one line prints DBI 0x820/0x824/0x828 (DWC PCIE_MSI_ADDR_LO/HI, vector
  enable) as the UEFI left them. The DWC port ends an inbound write to that address in the port (it never reaches the
  SMMU). Our survey does not program it (Linux `dw_pcie_msi_init` does). If it points into the mailbox page, MSI stays
  off. Expected: reset value 0, no match.
- With MSI on, `negroni_wlan_mhi_init` gives the event ring contexts msivec 1 and 2 (ath11k MHI irq layout: vector 0
  = BHI/state, 1-2 = event rings). BHI_INTVEC stays 0 (already written before the BHI doorbell, as Linux).
- Polls: in the BHI wait loop (`BHI SBL`), at every BOOT dump (`before BHI`, `BHI SBL`, `waiting for READY`, `READY
  time-out`, `SYSERR while waiting for READY`), every pass of the READY loop (`READY wait`, 1 s) and every
  `negroni_wlan_service` pass (`service`). A change prints one line and the sentinel goes back. At most 64 lines,
  then the MSIs are only counted. Two MSIs between two polls show as one (the last one).
- Stop: `wlan_quiesce` (every failure path after the BAR0 claim) calls `wlan_msi_off` first: one last poll, all
  vectors masked, enable and MME cleared, address and data 0, then the MHI reset, bus master off, the frees and the
  SMMU teardown. With a dead link (config reads 0xffffffff) nothing is written. When a level succeeds and the chip
  keeps running, MSI stays on: the pool and the SMMU context stay too.
- Stray writes: with MSI enable 0 the function must not send MSI (PCI 3.0 6.8.1.3). Masked vectors only set pending
  bits. MSI enable is set only after the address, the data and the mask are in place.

### Lines (`NEGRONI WLAN: `)

- `start: ... SW reset N, MSI M`
- bit 1: `SOC_WAKE 0x.. -> wrote 1 -> 0x.. after 5 ms (negroniwlan_msi bit 1)`
- bit 0: `MSI on: capability 0x50 control 0x10a -> 0x15b (32 of 32 vectors, 32-bit address, per-vector mask yes),
  address 0xa0008000 (pool + 0x8000, SMMU window 0xa0000000-0xafffffff), data 0xa500, mask 0, mailbox 0xffffffff`
  (expected values if the pool is the first SMMU mapping at 0xa0000000; the real address is the pool IOVA + 0x8000).
  `MSI DID NOT TAKE: ...` = the readback differs; MSI goes off again.
- refusal: `MSI: capability .. control .., mailbox ..: <reason>; MSI stays off`
- each MSI: `MSI #n data 0xa5vv (vector vv) at <when> after N ms` (`not our data base` = some other value landed in
  the word)
- stop: `MSI off (stop): control 0x10a, address 0, N MSIs seen`

### Test (main session; one boot each)

1. `negroniwifi=10 negroniwlan=10 negroniwlan_smmu=3 negroniwlan_msi=1`
2. `negroniwifi=10 negroniwlan=10 negroniwlan_smmu=3 negroniwlan_msi=3` (+ SOC_WAKE)

How to read it [I]:
- `MSI #1 data 0xa500 (vector 0) at BHI SBL ...`: the chip sends the BHI-done MSI (Linux gets it on BHI_INTVEC 0). The
  MSI path (endpoint -> root port -> SMMU context -> RAM) works.
- `MHISTATUS READY ... after N ms` with MSI on, never without: the SBL needs MSI enabled. Next: make `negroniwlan_msi=1`
  the default and keep polling (no ITS needed).
- MSI lines but still no READY and EE 0: MSI is not the blocker. Next suspects (guesses, README 0342-0343): the XO
  clock latch at WLAN_EN, the rail modes (antenna switch, rfa).
- No MSI line at all, SMMU fault line with an address near the mailbox: the MSI write reaches the SMMU but the
  mapping is wrong. No MSI line and no fault: the chip sent nothing (or the root port takes the write).
- `MSI DID NOT TAKE` or a refusal line: read the reason; nothing else changed in the boot.
- `=3` differs from `=1` only by SOC_WAKE: a READY only with `=3` points at the SoC wake vote.

### Not checked

- [I] The DWC root port has an iMSI-RX block that catches upstream writes to its own MSI address. The survey does not
  program it (no `PCIE_MSI_ADDR` write in negroni_wifi.c), so a write to 0xa0008000 should go upstream. Not read back.

## 0345: scan + WPA2-PSK join path for wifid 20H392 (2026-10-27)

File: `bsd/dev/negroni_apple80211.c`, `negroni_wlan_ios.{c,h}` (iOS side only; the driver is not changed). Made in
`out/kernel/tree-a80211` (patched-tree.sh, all patches). Build-only: not run on the phone.

### Sources [V]

- Phone logs `logs/usblog-20261026-233816.txt`: t21 (04:42:54, real chip, `negroniwlan_msi=1`) and boot 16 (02:49:23,
  fake radio `negroniwlan_ios=2`).
- The 20H392 binaries (Apple files, git-ignored, in `out/research/wifid/`): `/usr/sbin/wifid` (from the root with
  `scripts/audio/hfs-extract.py`) and IO80211.framework (from `out/dsc/cache` with `ipsw dyld extract`). Type names:
  IO80211 `kIoctlNameTable` (418 entries, `convertApple80211IOCTLToString`); event names: `eventArray`
  (`convertApple80211EventToString`). Lists: `out/research/wifid/ioctl_names.txt`, `event_names.txt`.
- Design references (not copied): ios-sailfish 0179 (iOS 16.7.16, Settings join works there, no license file),
  HakiOS `hakios.apple80211.c` (APSL 2.0, already the base of 0341).

### How wifid uses Apple80211 (20H392)

| Step | What wifid / IO80211 does | Our answer |
|---|---|---|
| Find the interface | getifaddrs + SIOCGIFMEDIA (802.11), IOService `IO80211InterfaceRole`, IOServiceOpen type 0 fails -> ioctl path | 0340 |
| Open | CopyValue 12 CARD_CAPABILITIES, get 96 VIRTUAL_IF_ROLE, 97 VIRTUAL_IF_PARENT, 1 SSID | 12 answered; 96/97 refused (sailfish too); 1 ENXIO before a join |
| Device init | 19 POWER, 106 RSSI_BOUNDS (6 tries, 500 ms apart, only on error -3905/61/16), 254, 207, 27, 51 COUNTRY_CODE, 115 POWER_DEBUG_INFO | all answered except 51, 115 (refused) |
| Events | `Apple80211StartMonitoringEvent` for 63 codes: 1-14, 30-32, 35-39, 55 DRIVER_AVAILABLE, 57, 60, 61, 63, 75, 76, 79, 80, 83, 89, 90, 92, 93, 137-145, 148-151, 156-201 (some); not 20 RSN_HANDSHAKE_DONE | we post 1, 2, 3, 4, 9, 10 |
| Status poll | Apple80211GetInfoCopy: 18 INT_MIT, 5 POWERSAVE, 13 STATE, 14 PHY_MODE, 15 OP_MODE, 8 RATE, 57 MCS, 16 RSSI, 17 NOISE, 4 CHANNEL, 2 AUTH_TYPE, 6 PROTMODE, 1 SSID, 9 BSSID; 103 CURRENT_NETWORK (polled: 192 times in 5 min in t21) | 0345 adds 5, 6, 8, 14, 17, 18; 57 refused |
| Settings sets | 383 SET_PROPERTY (4104 bytes, every 5-20 s), 25 HOST_AP_MODE (value 2), 365 DISPLAY_STATE, 419 LTE_RESTRICTED_CHANNELS | 365 accepted (0345); 383, 25, 419 refused (harmless in sailfish and ios-flame) |
| Scan | `Apple80211ScanAsync`: RawSet 10 SCAN_REQ, 5456 bytes; on event 10 SCAN_DONE: get 11 SCAN_RESULT (1164 bytes) until an error. `Apple80211ScanDynamic` uses 86 SCAN_REQ_MULTIPLE. wifid also sets 382 ABORT_SCAN, 267 SUPPRESS_SCANS, 47 BACKGROUND_SCAN | 10 answered (fake boot 16: 3 results + EIO); 86 and 382 added (0345) |
| Join | `__performAssociation`: RawSet 20 ASSOCIATE (ssid len @12, ssid @16, bssid @48, key len @60, cipher @64, key @72). Sync: `__waitForJoinResult` gets 21 ASSOCIATE_RESULT every 20 ms, 400 times (**8 s**), 0 = still running. Async: on event 9 ASSOC_DONE it gets 21 once; 0xffff = try again (up to 39 times). `__errorForAssociateResult`: 1 = success, others = errors -3906..; 0 = generic error | 0341: 21 is 0 while the join runs, then 1 / 21 / 9 / 2; ASSOC_DONE only after the result is set |
| Link | events 2, 3, 4 (LINK_CHANGED, 32 bytes) + KEV_DL_LINK_ON on en0 (configd DHCP) | 0341 |

Kernel event format [V IO80211 `__eventRead`]: `kern_event_msg` header, interface name 16 bytes at +0x18 (compared with
strncmp), data at +0x28 (length = total - 0x28). Our `post()` matches. Event 55 DRIVER_AVAILABLE has a 0xb8-byte payload
(version, flags, available, event id, reason, subreason, minor reason, strings at 0x1c/0x70/0x94); we do not post it
(fake boot 16 scanned without it).

### What 0345 changes

- New gets: 106 RSSI_BOUNDS `{1, -90, -40, -80}` (layout [V]: 16 bytes, version 1, RSSI_MIN +4, RSSI_MAX +8,
  RSSI_THRESHOLD +12; the values are a guess, min < threshold < max); 5 POWERSAVE and 18 INT_MIT value 0; 6 PROTMODE
  `{1, 0, 0}`; 14 PHY_MODE `{1, a|b|g, active}` (active 11g on 2.4 GHz, 11a on 5 GHz, 0 when not joined); 17 NOISE
  (RSSI layout, -95 dBm, ENXIO when not joined); 8 RATE value = the highest legacy rate in the joined BSS's rates
  elements (not measured; 54 if none; ENXIO when not joined).
- New sets: 86 SCAN_REQ_MULTIPLE = the same passive all-channel scan as 10 (layout not read); 5 POWERSAVE, 365
  DISPLAY_STATE, 382 ABORT_SCAN accepted (nothing to do: the passive scan ends by itself with SCAN_DONE).
- Join fix (negroni_wlan_ios.c): `nwios_disassociate` kicked `P_LINK_DOWN`; reconcile() reads that bit as "the driver
  ended an association" for the pending join. wifid sends DISASSOCIATE before ASSOCIATE; the driver keeps `last_error`
  from an older failed join (it changes only on the next failure). So the second try after a wrong password could
  fail at once with the old EAUTH (result 21) while the driver was still IDLE. Now a leave kicks the new bit `P_LEAVE`;
  only the driver's callback sets `P_LINK_DOWN`.
- Log: at most 6 request lines per kind (type + get/set); a changed result of a kind (the error, or the value of a get: 21 ASSOCIATE_RESULT 0 -> 1, 13 STATE) is always said; `negroniwlan_ios_log=0` turns all request lines off. Scans (10, 86),
  joins (20), leaves (22) and power sets (19) are always said, up to 200 lines (in t21 the CURRENT_NETWORK polls used all
  400 lines in 5 min). The summary comes 180 s after en0, then every 600 s while requests come (line now ends `..., N
  requests`). Names for 96, 97, 115, 267, 365, 382, 383, 419 from the 20H392 table.
- Not changed: the driver (negroni_wlan_*.c), boot-args, defaults. All new answers are on by default (no new gate):
  they only answer requests that were refused before.

### Why t21 showed no scan [V log, I cause]

- [V] t21: en0 attached 04:42:59; burst 04:42:59 (open), burst 04:47:58 (status poll, CURRENT_NETWORK, 383, 25, 365,
  419); no `sets 10`, no driver `API state 2 -> 3`, no `scan done` until the log limit at 04:52:35. wifid never set
  POWER off. `wifip2pd` restarts every 10 s (no AWDL/P2P interface; not needed for infra Wi-Fi [I]).
- [V] Fake boot 16: the same requests, then `sets 10 (SCAN_REQ) ... type 1, 13 channels` 9 s after the burst, SCAN_DONE,
  3 x SCAN_RESULT + EIO. So the scan path works end to end when wifid asks.
- [I] wifid scans when a client asks (Settings > Wi-Fi page open, auto-join with known networks, location). In t21 no
  page was open and no network is known, so wifid had no reason to scan. Guess, not proven.

### Test (main session builds the image; boot-args as `scripts/ios16/variants/everything.args`)

What the owner does:
1. Unlock. Open **Settings > Wi-Fi**. If the switch is off, turn it on. Stay on this page for 30 s.
2. The network list should fill ("NETWORKS" / "OTHER NETWORKS"), WPA2 networks with a lock.
3. Tap the home network (WPA2-PSK), type the password, tap **Join**. Wait up to 40 s.
4. Then once a wrong password on purpose (expect "Incorrect password"), then the right one (checks the 0345 join fix).

Expected lines (`NEGRONI WLAN iOS:` unless said):
- `wifid gets 106 (RSSI_BOUNDS), value 0, 16 bytes: answered`
- `wifid sets 10 (SCAN_REQ), value 0, 5456 bytes (a scan: type T, N channels, ...): answered` (or `sets 86
  (SCAN_REQ_MULTIPLE) ... (a scan of several names, L bytes)`), then the driver: `NEGRONI WLAN: API state 2 -> 3`,
  `NEGRONI WLAN: API scan K done: M BSS in the list`, then `scan done, M networks for wifid`, `Apple80211 event: scan
  done, 0`, `wifid gets 11 (SCAN_RESULT) ... answered` and `... error EIO (end of list)`.
- Join: `wifid sets 22 (DISASSOCIATE) ...` (maybe), `wifid sets 20 (ASSOCIATE) ... (a join: a name of N bytes, ..., a key
  of 32 bytes of kind 6)` (or 8-63 bytes of kind 10), driver `API state 2 -> 4 ... -> 5 ... -> 6`, `connected: a network
  name of N bytes, F MHz, RSSI R`, `en0 link UP (KEV_DL_LINK_ON: configd starts DHCP)`, `Apple80211 event: link, 1`,
  `Apple80211 event: join done, 0`, then `wifid gets 21 (ASSOCIATE_RESULT)` (value 1), gets 8/14/16/17 answered.
- Wrong password: `join K failed: error 80, 802.11 code 15, ...` (EAUTH), `Apple80211 event: join done, 80`; the next
  join must not end at once.
- Every 600 s: `Apple80211 summary: K request kinds, N requests` + one line per kind.

How to read it [I]:
- No `sets 10`/`sets 86` while the Settings page is open: wifid does not want to scan. Then read the refusals in the
  summary (57 MCS, 96/97, 51 COUNTRY_CODE, 115) and the wifid syslog (the `Device RSSI bounds (...)` line shows 106
  worked); next candidates: 96 VIRTUAL_IF_ROLE, 51 COUNTRY_CODE, event 55 DRIVER_AVAILABLE.
- Scan lines but an empty list in Settings: SCAN_RESULT layout or channel flags. Compare with boot 16 (fake: 3 results).
- `sets 20` and success in the kernel, but Settings says "Unable to join": the sync wait is only 8 s
  (`__waitForJoinResult`); a join that needs a new scan first (BSS older than 60 s) can take longer. Then: start the
  join without a scan when wifid's scan is fresh, or answer 21 with 0xffff semantics for the async path.

### Open

- RSSI_BOUNDS values, the RATE value and the noise floor are guesses (no measured value in the driver seam).
- COUNTRY_CODE (51): the chip reports the regulatory country (`WMI regulatory event: ... country "US?"`), but the seam
  has no getter; refused as before.
- No DRIVER_AVAILABLE (55) and no RSN_HANDSHAKE_DONE (20, wifid does not monitor it) events.

## 0346 analysis: why wifid does not scan (2026-10-27, Wi-Fi iOS agent 2; no patch, 0346 stays free)

Sources: `logs/usblog-20261026-233816.txt` (boots 02:42-05:05), `logs/usblog-20261027-060101.txt` +
`logs/usblog-20261027-121304.txt` + `logs/bootlog-13.txt` (t23), wifid's own syslog in
`logs/phone-log-20261027-025222.txt` / `-025305.txt` (boot 16, phone time = Mac time + 11:30), `/usr/sbin/wifid`
20H392 disassembly (`ipsw macho disass`), MobileKeyBag + CoreWiFi from `out/dsc` (`ipsw dyld disass`).

### The Bluetooth lead is wrong [V]

Marker for "wifid finished its init": the kernel lines `wifid gets 19 (POWER)` / `106` / `254` / `207` and
`exec wifianalyticsd` (wifid starts it at the end of its init, in every good boot).

| Boot | wifid exec | open (12, 96, 97) | init (19/106/254, wifianalyticsd) | bluetoothd |
|---|---|---|---|---|
| 02:42 fake | 02:42:18 | 02:42:21 | 02:42:21 | 1 exit (02:42:21) |
| 16 #1 fake | 02:49:24 | 02:49:27 | never (killed 02:53:36, 4 min) | exit 02:49:27, then every 10 s |
| 16 #2 fake | 02:53:36 | 02:53:36 | 02:54:26 (50 s) | exits 02:53:44, :54, 02:54:04, :15, :25 |
| 03:01 real | 03:01:43 | 03:01:46 | 03:01:47 | bluetoothd[86] alive until 03:02:01 |
| 03:12 fake | 03:12:01 | 03:12:03 | never (log ends 03:13:09) | exits every 16 s |
| 03:16 fake | 03:16:52 | 03:16:54 | 03:16:55 | exits |
| t21 real | 04:42:56 | 04:42:59 | 04:42:59 | 0 exits |
| t23 real | 12:11:51 | 12:11:54 | never (log to 12:14:51, 3 min; Settings open 12:13:14) | 0 exits, BT works |
| no-en0 boots 04:06-04:38 | | none | wifianalyticsd 3-4 s after exec | any |

- [V] t21 and 03:01 reached the init with bluetoothd alive or never exiting; 16 #1 saw an exit and stayed stuck;
  16 #2 saw four exits during its stall. The exit-then-init lines in 02:42 and 02:54 are coincidence: in boot 16
  bluetoothd exited every ~10 s (HCI init failed, reason 108).
- [V] wifid does not use bluetoothd before its init: `BTSessionAttachWithQueue("com.apple.wifi.manager")` and the
  coex manager registration come later in `WiFiManagerScheduleWithQueue` (wifid 0x10006bf54, 0x10006c050). The coex
  path (WirelessCoexManager XPC, `wifi_device_set_coex_parameters`, BT_COEX events) has no gate on power or scan.

### What really blocks: a stall in `WiFiManagerScheduleWithQueue` [V log, U cause]

wifid's own log, boot 16 #2 (pid 387):
- 14:23:36.412 `WiFiManagerScheduleWithQueue: entering`, then nothing from that function until 14:24:26.179.
- [V] In the stall: no `com.apple.wifi.manager` MIG server (Preferences and bluetoothd log `bootstrap_look_up of
  WiFiManager server failed`), the CoreWiFi XPC requests of SpringBoard / mediaserverd / Preferences wait and are all
  answered at 14:24:26.18. So Settings has no Wi-Fi interface ("failed to acquire WiFiDeviceClientRef").
- [V] After it, in 0.5 s: `First unlock since launch`, `Turning WiFiManager ON`, `unlockedSinceBoot TRUE`,
  `WiFiDeviceManagerCreate`, `Device power state = ON`, auto-join `trigger=power_on`, Preferences `interface became
  available` (14:24:35) and the only SCAN_REQ ever seen (kernel 02:54:35 = 14:24:35). The kernel side and the AKS answer
  (lock state 0x6, bit 2 = unlocked since boot) are good; nothing else was missing.
- [V] Code order (wifid 0x10006b8c0): log "entering" -> `[[WiFiXPCManager sharedXPCManager] activate]` ->
  `[CWFKeyValueStore(type 4, known networks) activate]` (dispatch_sync into its queue) -> sub_1000bf43c
  (`bootstrap_check_in` of the WiFiManager MIG port, `WiFiManager/base` dispatch_mach) -> `isSetupCompleted` /
  buddy log -> `MKBUserUnlockedSinceBoot` -> ... -> BTSession -> coex -> `com.apple.wifi.manager.available`. The
  first lines after the stall are `nw_path_evaluator_start` and `Apple80211EventMonitoringInit2` (XPC manager
  start), so the wait is in or before `WiFiXPCManager activate` / `CWFKeyValueStore activate`.
- [I] It is a synchronous wait for another process: no CPU, no timeout (16 #1 waited > 4 min, t23 > 3 min), random
  per boot (about half of the boots with en0). Candidates (not proven): `+[WiFiXPCManager sharedXPCManager]`
  dispatch_once (CWFXPCManager init makes an `RBSProcessMonitor`, runningboardd), the CWFKeyValueStore queue
  (CFPreferences with protection class C -> cfprefsd), accountsd (`The connection to ACDAccountStore was invalidated`
  in wifid at 14:24:21, 5 s before the end). The Bluetooth timing does not explain it.
- [I] t21 (init OK, no scan): no known network and no Settings page open, so wifid had no reason to scan
  (auto-join `power_on` with an empty known list scans nothing).

### What the next phone test must capture

- While the stall lasts (kernel log shows `wifid gets 97` and no `wifid gets 19` / `exec wifianalyticsd` for > 10 s):
  `scripts/wifi/wifid-stall.sh` (spindump of wifid + all processes, `/usr/sbin/spindump` is on the 20H392 root;
  output `logs/wifid-spindump-<date>.txt`) [U: spindump on this kernel not tried]. The main thread stack names the
  call; the peer daemon is in the same report.
- Also `scripts/net/phone-log.sh wifid Preferences runningboardd cfprefsd accountsd` from boot (the stall starts
  2-3 s after wifid starts).
- Work-around to test (no build): kill wifid over SSH (`scripts/net/ssh-phone.sh 'kill $(pgrep wifid)'`; the root
  has no launchctl, launchd restarts wifid because of `KeepAlive`). Boot 16 did this at 02:53:36: the second wifid got
  through after 50 s; [U] if a new start always gets through.

### Kernel or root tweak needed?

- Kernel: nothing proven missing. AKS 0x6 makes `MKBUserUnlockedSinceBoot` true; en0, Apple80211 and the scan path work
  (boot 16 #2). No 0346 patch.
- Root tweak: none until the spindump names the blocking call. If it is RunningBoard or cfprefsd, a root tweak cannot
  remove a framework call; a wifid restart job or a fix in that daemon is the next step.
