# Stock backup and restore (OnePlus 10 Pro NE2211)

## Device state (2026-10-24)

- Model NE2211 (India), OP516FL1, SM8450 (taro), 12 GB RAM, 256 GB UFS
- OxygenOS `NE2211_16.0.3.530(EX01)`, ota_version `NE2211_11.J.94_4940_202606122011`, patch 2026-06-01
- Bootloader unlocked (`ro.boot.flash.locked=0`, verified boot state `orange`), active slot `a`
- Anti-rollback (ARB) index 0 for all NE2211 builds (source: Bartixxx32/Oneplus-antirollchecker)
- UEFI firmware build `BOOT.MXF.2.0-00925.2-WAIPIO-1.81484.5`
- CPU: 1x Cortex-X2 (0xd48), 3x A710 (0xd47), 4x A510 (0xd46); `paca pacg bti` present

## Backup (on the Mac, not in git)

The backup lives in `~/op10-backup/`:

| File | Content |
|---|---|
| `NE2211_16.0.3.530_EX01_full.zip` | Official full OTA, 7.2 GB, MD5 `88e0e6108203a30e4c5ad43319e67e37` (verified) |
| `images/` | Small images extracted with `payload-dumper-go`, plus `SHA256SUMS` |
| `getvar-all.txt` | fastbootd variables and partition sizes |
| `RESTORE.md` | Short restore notes |

To make the backup again: `scripts/fetch-stock-ota.sh`, then
`payload-dumper-go -o images -p boot,vendor_boot,dtbo,vbmeta,vbmeta_system,vbmeta_vendor,uefi,abl,xbl,xbl_config <zip>`.

Not in the backup: user data, and the unique partitions (modemst1/2, fsg, fsc,
persist, oplusreserve*). Never flash or erase those.

## Restore slot A to stock

Phone in bootloader fastboot mode (Volume up + Volume down + Power, or `adb reboot bootloader`):

```sh
cd ~/op10-backup/images
fastboot flash boot_a boot.img
fastboot flash vendor_boot_a vendor_boot.img
fastboot flash dtbo_a dtbo.img
fastboot flash vbmeta_a vbmeta.img
fastboot -w            # only if userdata holds an iOS root; erases userdata
fastboot reboot
```

## Rules

- Do not lock the bootloader again after a partition change.
- Do not install OxygenOS updates during the port work; keep auto download off.
- Keep slot B unchanged as a second way back to Android.
- Do not change the GPT.
- Use a cable that works in fastboot mode. One USB-C cable worked for adb but not for fastboot.
