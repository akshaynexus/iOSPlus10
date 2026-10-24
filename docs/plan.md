# Plan and status

Status date: 2026-10-24.

## Done

- Phone bought: OnePlus 10 Pro NE2211, PAC confirmed by adb.
- Bootloader unlocked (orange state). Auto updates off; stay on 16.0.3.530.
- Stock backup: official full OTA (MD5 checked) and extracted images in `~/op10-backup/`.
- Research: stack map, PAC analysis of xnu-12377, GPU path (`docs/research-report.md`).
- UEFI firmware check: NE2211 `uefi.img` matches the build the negroni Mu patches target.

## Phase 1: iOS 16 (existing negroni port)

1. Shim probe with `fastboot boot` (no write): measure the 12 GB memory map, MIDR, PSCI, GIC.
2. Mu UEFI: extract DXEs from the OTA `uefi.img`, run `portpatch2.py` / `mkbinaries.py`, fix
   MemoryMapLib for 12 GB, build `negroniPkg` DEBUG.
3. Kernel from slop CI run 40007883255; ADT with the new `--dram`; payload; `boot_a` image.
4. iOS 16.7.16 (iPhone10,3, 20H392) HFS+ root.
5. Writes, each approved first: `vendor_boot_a`, `vbmeta_a`, erase `dtbo_a`, `boot_a`, `userdata`.

## Phase 2: iOS 26 kernel and userland

1. xnu-12377.121.6 arm64e from a VMAPPLE-based NEGRONI config.
2. Native PAC keys instead of the VMAPPLE hvc calls (one global key set first).
3. Clear SME/SME2, PAN3, paravirt CTRR in the config.
4. A13 iPhone IPSW (iPhone12,1 / iPhone12,5) as userland.
5. Port the 128 negroni patches, or prelink Apple's arm64e A13 kexts.
6. Find out whether iOS 26 QuartzCore renders without Metal.

## Phase 3: GPU (Adreno 730)

1. Fix the RedwoodGPU user client panic in slop's A730 path.
2. Port UniXNU NativeAdreno board code (GMU, RSC, votes, cmd-db, SMMU) to SM8450.
3. Port NativeMetal (metal2vulkan via Turnip FD730) to the iOS 26 Metal interface.
