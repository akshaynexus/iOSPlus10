#!/usr/bin/env python3
"""Print the probe facts of CAMX sensor module files (com.qti.sensormodule.*.bin).

  cammodule.py MODULE.bin...

The files are "QTI Chromatix Header" / "Parameter Parser V3.5.1" files (NE2211 odm image,
/odm/lib64/camera). Layout, as seen in these files (the older V3.0.1 layout is described in
external/hackios-xnu-kernel/tools/camsensor.py; V3.5.1 symbols are 0x3c bytes, not 0x38):
  0xa4 entry count, 0xa8 entries {id, offset, size}: entry 0 = symbol table, entry 1 = data pool
  symbol {id u32, name[32], kind, ?, parent, offset, size, ?} -> value = pool[offset:offset+size]
  sensorDriverData (pool offset 0) as u32 words: [11] slave address (8-bit form), [12]/[13]
    address/data bytes, [14] chip-ID register, [15] chip ID, [17] ID mask
  moduleConfiguration: first u16 = cameraId (= DT cell-index of qcom,cam-sensor)
  resolutionData: 304-byte elements; u32 [21] lane count, [24] settle count, [25] C-PHY flag,
    double at byte 68 = frame rate; streamConfiguration [5]/[6] width/height, [2] data type
  powerSetting: {type, value, delay ms} u32 triples; types are the kernel's
    msm_camera_power_seq_type (cam_sensor_cmn_header.h)
  actuator/EEPROM/OIS slave address: u16 at byte 28 / 20 / 20 of their driver blocks
The word positions were found by matching the known chip IDs of all four NE2211 modules; treat
them as inferred, not as a documented format. Read-only on its inputs. Run with python3 -I.
"""
import struct
import sys

PWR = {0: "MCLK", 1: "VANA", 2: "VDIG", 3: "VIO", 4: "VAF", 5: "VAF_PWDM", 6: "CUSTOM_REG1",
       7: "CUSTOM_REG2", 8: "RESET", 9: "STANDBY", 10: "CUSTOM_GPIO1", 11: "CUSTOM_GPIO2"}


def load(path):
    d = open(path, "rb").read()
    if not d.startswith(b"QTI Chromatix Header") or b"Parameter Parser V3.5" not in d[:0x60]:
        sys.exit(f"{path}: not a V3.5 CAMX parameter file")
    n = struct.unpack_from("<I", d, 0xA4)[0]
    ent = [struct.unpack_from("<3I", d, 0xA8 + 12 * i) for i in range(n)]
    tab, tsize, pool = ent[0][1], ent[0][2], ent[1][1]
    syms = {}
    for at in range(tab, tab + tsize - 0x3B, 0x3C):
        name = d[at + 4:at + 36].split(b"\0")[0].decode("latin1")
        off, size = struct.unpack_from("<2i", d, at + 48)
        syms.setdefault(name, []).append(d[pool + off:pool + off + size])
    return d, pool, syms


def cstr(b):
    return b.split(b"\0")[0].decode("latin1")


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    for path in sys.argv[1:]:
        d, pool, s = load(path)
        w = struct.unpack_from("<18I", d, pool)
        cam_id = struct.unpack_from("<H", s["moduleConfiguration"][0])[0]
        lane = s["laneAssign"][0]
        print(f"== {path.rsplit('/', 1)[-1]}")
        print(f"  cameraId (DT cell-index) {cam_id}; sensor {cstr(s['sensorName'][0])}; "
              f"slave {w[11]:#04x} (7-bit {w[11] >> 1:#04x}); chip ID {w[15]:#x} at {w[14]:#06x} "
              f"(mask {w[17]:#x}, {w[12]}/{w[13]}-byte address/data)")
        print(f"  laneAssign {struct.unpack('<H', lane)[0]:#06x}" if len(lane) == 2 else "  laneAssign ?")
        for name, sym in (("actuator", "actuatorDriver"), ("EEPROM", "EEPROMDriverData"),
                          ("OIS", "OISDriver")):
            blk = s.get(sym, [b""])[0]
            pos = 28 if name == "actuator" else 20
            nm = {"actuator": "actuatorName", "EEPROM": "EEPROMName", "OIS": "OISName"}[name]
            label = next((cstr(v) for v in s.get(nm, []) if len(v) > 8 or b"_" in v), "")
            if len(blk) > pos + 2 and label:
                print(f"  {name} {label}: slave {struct.unpack_from('<H', blk, pos)[0]:#04x}")
        for i, ps in enumerate(s["powerSetting"][:2]):
            seq = [struct.unpack_from("<3I", ps, k) for k in range(0, len(ps) - 11, 12)]
            print(f"  power {'up' if i == 0 else 'down'}: " + ", ".join(
                f"{PWR.get(t, t)}={v}{'Hz' if t == 0 else ''}+{ms}ms" for t, v, ms in seq))
        streams = s["streamConfiguration"]
        res = s["resolutionData"][0]
        for k in range(len(res) // 304):
            m = struct.unpack_from("<26I", res, 304 * k)
            fps = struct.unpack_from("<d", res, 304 * k + 68)[0]
            sc = struct.unpack_from("<7I", streams[k]) if k < len(streams) else (0,) * 7
            print(f"  mode {k}: {sc[5]}x{sc[6]} dt {sc[2]:#x} {fps:.2f} fps, {m[21]} "
                  f"{'trio(s) C-PHY' if m[25] else 'lane(s) D-PHY'}, settle {m[24]}")


main()
