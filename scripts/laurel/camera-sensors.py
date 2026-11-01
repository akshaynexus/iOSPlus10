#!/usr/bin/env python3
"""Mi A3 camera: read the mm-camera2 sensor libraries (libmmcamera_laurus_<sensor>.so, 32-bit ARM).

  scripts/laurel/camera-sensors.py out/laurel/camera/lib/libmmcamera_laurus_*.so

Each library is data only: one sensor_lib_t in .data (sensor_open_lib returns its address). Layout read from the
files and checked against the 4.14 uapi enums (external/laurel-kernel-los include/uapi/media/msm_camsensor_sdk.h):
  +0x00  char sensor_name[32]
  +0x20  u32 slave_addr (8-bit form), u32 i2c_freq_mode (0 100k, 1 400k, 2 custom, 3 1M),
         u32 addr_type (1 byte, 2 word), u32 data_type
  +0x30  u16 sensor_id_reg_addr, u16 sensor_id
  +0x5e08 power-up:   12 x {u32 seq_type, u32 seq_val, u32 config_val, u32 delay_ms}, u32 size at +0x5ec8
  +0x5ecc power-down: same, size at +0x5f8c
  seq_type: 0 CLK (config = MCLK Hz), 1 GPIO (seq_val = msm_sensor_power_seq_gpio_t, config 0 low / else high),
            2 VREG (seq_val = msm_camera_vreg_name_t, the DT cam_vreg of that name)
Mode table: a u32 count n, then n records of 0x60 bytes {u16 x_output, u16 y_output, u16 line_length_pclk,
u16 frame_length_lines, u32 0, u32 vt_pixel_clk, u32 binning, ...} (found by search: offsets differ per sensor).
Libraries without a sensor_lib_t (EEPROM drivers) are skipped.
"""
import struct
import sys

GPIO = ["RESET", "STANDBY", "AF_PWDM", "VIO", "VANA", "VDIG", "VAF", "FL_EN", "FL_NOW", "FL_RESET",
        "CUSTOM1", "CUSTOM2", "CUSTOM3"]
VREG = ["VDIG", "VIO", "VANA", "VAF", "CUSTOM1", "CUSTOM2"]
FREQ = ["100k", "400k", "custom", "1M"]
PU, PU_N, PD, PD_N, MAXP = 0x5e08, 0x5ec8, 0x5ecc, 0x5f8c, 12


def data_section(blob):
    """(offset, size) of .data from the ELF32 section headers."""
    shoff, = struct.unpack_from("<I", blob, 0x20)
    shentsize, shnum, shstrndx = struct.unpack_from("<HHH", blob, 0x2e)
    sh = [struct.unpack_from("<10I", blob, shoff + i * shentsize) for i in range(shnum)]
    strtab = sh[shstrndx][4]
    for s in sh:
        name = blob[strtab + s[0]:blob.index(b"\0", strtab + s[0])]
        if name == b".data":
            return s[4], s[5]
    return None, 0


def seq(d, off, n):
    out = []
    for i in range(min(n, MAXP)):
        t, v, c, ms = struct.unpack_from("<4I", d, off + 16 * i)
        if t == 0:
            out.append("MCLK %.1f MHz" % (c / 1e6) if c else "MCLK off")
        elif t == 1:
            out.append("GPIO %s %s" % (GPIO[v] if v < len(GPIO) else v, "high" if c else "low"))
        elif t == 2:
            out.append("VREG %s" % (VREG[v] if v < len(VREG) else v))
        else:
            out.append("type %d val %d cfg %#x" % (t, v, c))
        if ms:
            out[-1] += " +%d ms" % ms
    return out


def modes(d):
    for off in range(0, len(d) - 0x60 * 2, 4):
        n, = struct.unpack_from("<I", d, off)
        if not 1 <= n <= 16 or off + 8 + 0x60 * n > len(d):
            continue
        recs = []
        for i in range(n):
            x, y, ll, fl = struct.unpack_from("<4H", d, off + 8 + 0x60 * i)
            pclk, = struct.unpack_from("<I", d, off + 8 + 0x60 * i + 12)
            if not (160 <= x <= 12000 and 120 <= y <= 9000 and x >= ll // 64 and ll >= x // 8 and fl >= y and pclk):
                break
            recs.append((x, y, ll, fl, pclk))
        if len(recs) == n and n >= 2:
            return off, recs
    return None, []


def main(paths):
    for p in paths:
        blob = open(p, "rb").read()
        off, size = data_section(blob)
        if off is None or size < PD_N + 4:
            continue
        d = blob[off:off + size]
        name = d[:32].split(b"\0")[0].decode("ascii", "replace")
        slave, freq, addr_type, data_type = struct.unpack_from("<4I", d, 0x20)
        id_reg, chip_id = struct.unpack_from("<2H", d, 0x30)
        npu, = struct.unpack_from("<I", d, PU_N)
        npd, = struct.unpack_from("<I", d, PD_N)
        if not name or not 0 < slave < 0x100 or not 0 < npu <= MAXP:
            continue
        print("%s (%s)" % (name, p.rsplit("/", 1)[-1]))
        print("  CCI slave %#04x (7-bit %#04x), %s, %s register addresses, chip ID %#06x at %#06x" % (
            slave, slave >> 1, FREQ[freq] if freq < 4 else freq, "16-bit" if addr_type == 2 else "8-bit",
            chip_id, id_reg))
        print("  power-up:   " + "; ".join(seq(d, PU, npu)))
        print("  power-down: " + "; ".join(seq(d, PD, npd)))
        moff, recs = modes(d)
        for i, (x, y, ll, fl, pclk) in enumerate(recs):
            fps = pclk / (ll * fl) if ll and fl else 0
            print("  mode %d: %dx%d, line %d, frame %d lines, vt_pixel_clk %d (%.1f fps)" % (i, x, y, ll, fl, pclk, fps))
        print()


if __name__ == "__main__":
    main(sys.argv[1:])
