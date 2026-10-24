#!/usr/bin/env python3
"""Camera facts from NE2211 device trees (stock DTBO table and the live DTB).

  camdt.py split DTBO OUTDIR   split an Android DTBO table into OUTDIR/NN.dtbo; print each entry's
                               id/rev/custom words and root model/board ids
  camdt.py table DTB           print one block per camera node (sensor, EEPROM, actuator, OIS, flash,
                               CSIPHY, CCI) with phandles resolved: regulator names and voltages,
                               GPIO controller + pin, clock provider + id, *-src links

Needs the PyPI library `fdt` (scripts/setup/native-tools.sh puts it into out/venv).
Run with `python3 -I`. Read-only on its inputs.
"""
import struct
import sys
from pathlib import Path

import fdt

CAM = ("qcom,cam-sensor", "qcom,eeprom", "qcom,actuator", "qcom,ois", "qcom,camera-flash",
       "qcom,csiphy", "qcom,cci")


def split(dtbo, outdir):
    # Android DTBO table: big-endian header (magic 0xd7b7ab1e) + dt_table_entry[] (AOSP
    # system/libufdt/utils/src/dt_table.h): dt_size, dt_offset, id, rev, custom[4].
    data = Path(dtbo).read_bytes()
    magic, _total, _hsize, esize, count, eoff = struct.unpack_from(">6I", data, 0)
    if magic != 0xD7B7AB1E:
        sys.exit(f"{dtbo}: not a DTBO table (magic {magic:#x})")
    out = Path(outdir)
    out.mkdir(parents=True, exist_ok=True)
    for i in range(count):
        size, off, eid, rev, *custom = struct.unpack_from(">8I", data, eoff + i * esize)
        blob = data[off:off + size]
        (out / f"{i:02d}.dtbo").write_bytes(blob)
        root = fdt.parse_dtb(blob).get_node("/")
        info = {k: prop_text(root.get_property(k)) for k in
                ("model", "compatible", "qcom,board-id", "qcom,msm-id", "oplus,project-id",
                 "oplus,hw-id", "oplus,pcb-range") if root.get_property(k) is not None}
        print(f"entry {i:02d} size={size:#x} id={eid:#x} rev={rev:#x} "
              f"custom={[hex(c) for c in custom]} {info}")


def prop_text(p):
    if p is None:
        return None
    v = list(p.data) if hasattr(p, "data") else []
    if isinstance(p, fdt.PropStrings):
        return v[0] if len(v) == 1 else v
    if isinstance(p, fdt.PropWords):
        return [hex(x) for x in v]
    return v


def table(dtb):
    t = fdt.parse_dtb(Path(dtb).read_bytes())
    ph, label = {}, {}
    for path, _nodes, props in t.walk():
        for p in props:
            if p.name in ("phandle", "linux,phandle"):
                ph[p.value] = path
    sym = t.get_node("/__symbols__") if t.exist_node("/__symbols__") else None
    if sym:
        for p in sym.props:
            label.setdefault(p.value, p.name)

    def ref(h):
        path = ph.get(h, f"<phandle {h:#x} unresolved>")
        return f"{path} ({label[path]})" if path in label else path

    def node(path):
        return t.get_node(path)

    for path, _nodes, props in t.walk():
        d = {p.name: p for p in props}
        comp = d.get("compatible")
        if comp is None or not any(c in CAM for c in comp.data):
            continue
        print(f"== {path}")
        for k in ("compatible", "status", "cell-index", "reg", "cci-master", "csiphy-sd-index",
                  "sensor-position-roll", "sensor-position-yaw", "sensor-position-pitch",
                  "ois,name", "clock-names", "clock-rates", "gpio-req-tbl-label",
                  "gpio-req-tbl-num", "gpio-reset", "gpio-vana", "gpio-vdig", "gpio-vio",
                  "regulator-names", "rgltr-min-voltage", "rgltr-max-voltage"):
            if k in d:
                print(f"  {k} = {prop_text(d[k])}")
        if "gpios" in d:  # tlmm: #gpio-cells = 2 -> <phandle pin flags>
            g = list(d["gpios"].data)
            print("  gpios = " + ", ".join(
                f"{ref(g[i]).split('/')[-1]} pin {g[i + 1]} flags {g[i + 2]}"
                for i in range(0, len(g) - 2, 3)))
        if "clocks" in d:  # camcc/gcc: #clock-cells = 1 -> <phandle id>
            c = list(d["clocks"].data)
            print("  clocks = " + ", ".join(
                f"{ref(c[i]).split('/')[-1]} id {c[i + 1]:#x}" for i in range(0, len(c) - 1, 2)))
        for k, p in d.items():
            if k.endswith("-supply"):
                rp = ph.get(p.value)
                r = node(rp) if rp else None
                name = prop_text(r.get_property("regulator-name")) if r else None
                lo = r.get_property("regulator-min-microvolt") if r else None
                hi = r.get_property("regulator-max-microvolt") if r else None
                v = f" {lo.value}-{hi.value} uV" if lo is not None and hi is not None else ""
                print(f"  {k} -> {name} [{ref(p.value)}]{v}")
            elif k.endswith("-src"):
                print(f"  {k} -> {ref(p.value)}")
            elif k.endswith("-source") and isinstance(p, fdt.PropWords):  # flash LED channels
                print(f"  {k} -> " + ", ".join(ref(h) for h in p.data))
            elif k.startswith("pinctrl-") and k[8:].isdigit() and "pinctrl-names" in d:
                names = list(d["pinctrl-names"].data)
                state = names[int(k[8:])] if int(k[8:]) < len(names) else ""
                if not state.endswith(("active", "default")):
                    continue
                for h in p.data:  # active pin states: node name, pins and function below it
                    if h not in ph:
                        continue
                    pins = sorted({v for _p, _n, ps in t.walk(ph[h]) for q in ps
                                   if q.name in ("pins", "function") for v in q.data})
                    print(f"  {state} -> {ph[h].split('/')[-1]}: {' '.join(pins)}")


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "split":
        split(sys.argv[2], sys.argv[3])
    elif len(sys.argv) == 3 and sys.argv[1] == "table":
        table(sys.argv[2])
    else:
        sys.exit(__doc__)
