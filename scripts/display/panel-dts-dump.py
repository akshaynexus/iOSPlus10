#!/usr/bin/env python3
"""Decode the booted panel node of out/live.dts: timings, TE/qsync/ADFR properties and every DCS
command set in the dsi_panel.c packet format (7-byte header {type, last, vc, flags, wait ms,
len hi, len lo} + payload). Source of docs/display-refresh-plan.md section 3 and of the byte
arrays in patches/xnu/0259-negroni-display-te-vrr.patch.

  scripts/display/panel-dts-dump.py                 the whole node, one packet per line
  scripts/display/panel-dts-dump.py --sets          C arrays of the FHD timing-switch sets (0259)
  scripts/display/panel-dts-dump.py --dts FILE --panel NAME
"""
import argparse
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PANEL = "qcom,mdss_dsi_panel_samsung_amb670yf08_fs_1440_3216_dsc_cmd"
KEYS = ("qcom,mdss-dsi-panel-framerate", "qcom,mdss-dsi-panel-width", "qcom,mdss-dsi-panel-height",
        "qcom,mdss-dsi-h-", "qcom,mdss-dsi-v-", "qcom,mdss-dsi-panel-clockrate", "qcom,mdss-dsi-qsync-min-fps",
        "oplus,", "qcom,mdss-dsi-te", "qcom,panel-te", "qcom,mdss-dsi-panel-jitter", "qcom,qsync",
        "qcom,dynamic", "qcom,mdss-dsi-panel-mode", "qcom,mdss-dsi-bl", "qcom,mdss-dsi-panel-name",
        "qcom,mdss-dsi-wr-mem", "qcom,mdss-dsc", "qcom,mdss-dsi-dma", "qcom,mdss-dsi-reset",
        "qcom,mdss-dsi-panel-status", "qcom,mdss-mdp-transfer")


def node_lines(lines, name):
    start = next(i for i, l in enumerate(lines) if l.strip().startswith(name + " {"))
    depth = 0
    for i in range(start, len(lines)):
        depth += lines[i].count("{") - lines[i].count("}")
        if depth == 0:
            return start, i
    raise SystemExit("unbalanced node")


def to_bytes(val):
    val = val.strip().rstrip(";")
    if val.startswith("["):
        return bytes(int(x, 16) for x in val[1:-1].split())
    if val.startswith("<"):
        b = bytearray()
        for x in val[1:-1].split():
            b += int(x, 16).to_bytes(4, "big")
        return bytes(b)
    return None


def packets(b):
    i = 0
    out = []
    while i + 7 <= len(b):
        n = (b[i + 5] << 8) | b[i + 6]
        out.append(b[i:i + 7 + n])
        i += 7 + n
    if i != len(b):
        raise SystemExit("packet framing error (%d of %d bytes)" % (i, len(b)))
    return out


def dump(lines, start, end):
    for ln in range(start, end + 1):
        l = lines[ln].strip()
        m = re.match(r"(timing@\S+) \{", l)
        if m:
            print("\n== %s (line %d)" % (m.group(1), ln + 1))
        key = l.split("=")[0].strip()
        if any(key.startswith(k) for k in KEYS) and "command" not in key:
            print("   %d %s" % (ln + 1, l[:160]))
        m = re.match(r"((?:qcom|oplus),[\w-]*command[\w-]*)\s*=\s*(.*)", l)
        if not m:
            continue
        k, v = m.group(1), m.group(2)
        if "state" in k:
            print("   %d %s %s" % (ln + 1, k, v))
            continue
        b = to_bytes(v)
        if b is None:
            print("   %d %s = %s" % (ln + 1, k, v[:60]))
            continue
        print("   %d %s (%d bytes)" % (ln + 1, k, len(b)))
        for p in packets(b):
            print("      %02x fl=%02x wait=%d: %s" % (p[0], p[3], p[4], p[7:].hex(" ")))


def c_array(lines, start, end, timing, prop="qcom,mdss-dsi-timing-switch-command"):
    s, e = node_lines(lines[start:end + 1], timing)
    for ln in range(start + s, start + e + 1):
        l = lines[ln].strip()
        if l.startswith(prop + " ="):
            b = to_bytes(l.split("=", 1)[1])
            pk = packets(b)
            name = "negroni_vrr_switch_" + timing.split("_")[-1]
            print("/* out/live.dts line %d: %s %s (%d bytes, %d packets) */" % (ln + 1, timing, prop, len(b), len(pk)))
            print("static const uint8_t %s[%d] = {" % (name, len(b)))
            for p in pk:
                print("\t" + " ".join("0x%02x," % x for x in p))
            print("};")
            return
    raise SystemExit("no %s in %s" % (prop, timing))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dts", default=os.path.join(REPO, "out", "live.dts"))
    ap.add_argument("--panel", default=PANEL)
    ap.add_argument("--sets", action="store_true", help="C arrays of the fhd_sdc_120/90/60 switch sets")
    a = ap.parse_args()
    lines = open(a.dts).read().split("\n")
    start, end = node_lines(lines, a.panel)
    if a.sets:
        for t in ("timing@fhd_sdc_120", "timing@fhd_sdc_90", "timing@fhd_sdc_60"):
            c_array(lines, start, end, t)
        return
    print("node %s lines %d-%d" % (a.panel, start + 1, end + 1))
    dump(lines, start, end)


if __name__ == "__main__":
    main()
