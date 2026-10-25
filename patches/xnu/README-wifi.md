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
