# Flash and restore (NE2211)

Same commands on macOS and Linux (needs `adb` / `fastboot` 37+ and a cable that works in fastboot
mode; on Linux the udev rules from [setup-linux.md](setup-linux.md)). Build first:
[build-ios16.md](build-ios16.md).

## One command

```sh
make flash CONFIRM=yes        # whole chain, in tmux; follow with: make status / tmux attach -t flash
```

`scripts/flash/all.sh` does, in this order:

1. **fastbootd** (`adb reboot fastboot`): `userdata` <- `~/op10-apple/ios16-root.simg`.
   **Erases Android's user data.** `fastboot` sends the 11.6 GB image in 45 pieces, because the
   phone accepts at most 256 MiB per transfer (`max-download-size`); this is still one command.
2. **bootloader** (`fastboot reboot bootloader`): `vendor_boot_a` <- `out/ios16/vendor_boot_a.img`
   (mainline DTB), `vbmeta_a` <- stock vbmeta with verity/verification off, erase `dtbo_a`,
   `boot_a` <- `out/ios16/boot_a.img` (shim + Mu UEFI + iOS payload).
3. `fastboot set_active a`, reboot.

Why userdata first, from fastbootd:
- fastbootd runs from the recovery, which needs the stock `vendor_boot` and `dtbo`;
- the OnePlus bootloader's sparse flash lost writes beyond ~8 GiB on the NE2213 (port notes), and
  the root has 11 GiB of data; fastbootd writes with AOSP libsparse.

After a new boot image only (the iOS root stays):

```sh
make flash-boot CONFIRM=yes
```

Single steps (dry run without `--yes`): `scripts/flash/ios16.sh check|userdata|vendor_boot|vbmeta|dtbo|boot|active`.

## Debugging: live kernel log over USB

The kernel can stream its console over USB Ethernet (slop patches 0072-0077/0119, `negroniusb=2`):
the phone becomes a CDC-ECM device and sends UDP to `192.168.7.1:5140`. macOS and Linux have a
built-in CDC-ECM driver.

```sh
make boot-debug                         # out/ios16-debug: negroniusb=2, kernel log on the panel too
make usblog                             # listener (sudo once: tmux attach -t usblog) -> logs/usblog-*.txt
make flash-boot-debug CONFIRM=yes       # phone in fastboot (Volume Up + Volume Down + Power)
```

`scripts/debug/usblog.sh` waits for the interface (host MAC `02:00:5e:77:ee:01`), sets
`192.168.7.1/24` and writes every line with a host timestamp.

## Back to Android

```sh
make flash-restore CONFIRM=yes                      # stock boot, vendor_boot, dtbo, vbmeta + format userdata
CONFIRM=yes scripts/flash/restore.sh --magisk       # same with the Magisk boot image (root)
```

Slot B is never written, so the bootloader can also fall back to it.
Details and the full partition backup: [backup-and-restore.md](backup-and-restore.md).

## First boot

Expect: OnePlus logo -> Mu-Silicium (UniXNU menu, 3 s timeout) -> DarwinBoot -> iOS kernel ->
Apple logo. The first boot of a fresh root stays a long time on the Apple logo (data migration);
keep the phone on the charger. Volume Up in Mu opens the front page, Volume Down the boot menu.

Known risks: the OxygenOS 16 ABL may refuse the header-v4 shim image; Mu may shut down by itself
(the r0q PmicDxe power-button patch has no counterpart on this firmware).
