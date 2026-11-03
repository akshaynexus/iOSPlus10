#!/usr/bin/env python3
"""check-table.py HEADER KERNEL_SRC RPM_MBN: laurel_rpm_scale.h against the stock source and the stock RPM firmware. Run with python3 -I. A missing input says SKIP."""
import os, re, struct, sys
hdr, ksrc, mbn = sys.argv[1:4]
h = open(hdr).read()
rows = re.findall(r'\{ (RS_\w+), (\d+), "(\w+)" \}', h)
defs = {k: int(v, 16) for k, v in re.findall(r'#define (RS_\w+)\s+0x([0-9a-f]+)u', h)}
errs = 0
def bad(m):
    global errs
    errs += 1
    print('FAIL', m)
src = os.path.join(ksrc, 'drivers/clk/qcom/clk-smd-rpm.c')
if os.path.exists(src):
    s = open(src).read()
    names = {'QCOM_SMD_RPM_BUS_CLK': 'RS_CLK1', 'QCOM_SMD_RPM_MEM_CLK': 'RS_CLK2', 'QCOM_SMD_RPM_CE_CLK': 'RS_CE', 'QCOM_SMD_RPM_IPA_CLK': 'RS_IPA', 'QCOM_SMD_RPM_QUP_CLK': 'RS_QUP', 'QCOM_SMD_RPM_MMXI_CLK': 'RS_MMXI'}
    stock = {}
    for m in re.finditer(r'DEFINE_CLK_SMD_RPM\(trinket, (\w+)_clk, \w+,\s*(\w+), (\d+)\)', s):
        stock[m.group(1)] = (names[m.group(2)], m.group(3))
    binding = open(os.path.join(ksrc, 'include/dt-bindings/clock/qcom,rpmcc.h')).read()
    tbl = s[s.index('static struct clk_hw *trinket_clks[]'):]
    tbl = tbl[:tbl.index('};')]
    order = []
    desc = re.search(r'rpm_clk_trinket = \{.*?\.num_rpm_clks = (\w+)', s, re.S).group(1)
    lim = int(re.search(r'#define ' + desc + r'\s+(\d+)', binding).group(1))
    for idx, nm in re.findall(r'\[(RPM_SMD_\w+)\] = &trinket_(\w+)\.hw', tbl):
        m = re.search(r'#define ' + idx + r'\s+(\d+)', binding)
        if m and nm.endswith('_clk') and not nm.endswith('_a_clk') and int(m.group(1)) <= lim and nm[:-4] in stock:
            order.append((int(m.group(1)), nm[:-4]))
    order = [n for _, n in sorted(order)]
    if order != [r[2] for r in rows]:
        bad(f'order: stock {order} header {[r[2] for r in rows]}')
    for t, i, n in rows:
        if stock.get(n) != (t, i):
            bad(f'{n}: stock {stock.get(n)} header {(t, i)}')
    for name, want in (('RS_KEY_KHZ', 'QCOM_RPM_SMD_KEY_RATE'), ('RS_KEY_ENAB', 'QCOM_RPM_SMD_KEY_ENABLE')):
        v = int(re.search(r'#define ' + want + r'\s+0x([0-9a-f]+)', s).group(1), 16)
        if v != defs[name]:
            bad(f'{name} {defs[name]:x} stock {v:x}')
    p = s[s.index('static int rpm_smd_clk_probe'):]
    if not (p.index('clk_vote_bimc(&trinket_bimc_clk') < p.index('clk_smd_rpm_handoff') < p.index('clk_smd_rpm_enable_scaling')):
        bad('the stock order changed')
    e = s[s.index('static int clk_smd_rpm_enable_scaling'):]
    if not e.index('QCOM_SMD_RPM_SLEEP_STATE') < e.index('QCOM_SMD_RPM_ACTIVE_STATE'):
        bad('the stock Enab order changed')
    if (2147483647 + 999) // 1000 != defs.get('RS_TOP_KHZ', 2147484):
        bad('top')
    dt = open(os.path.join(ksrc, 'arch/arm64/boot/dts/qcom/trinket.dtsi')).read()
    lat = dt[dt.index('cpu4_cpu_ddr_latmon:'):]
    lat = lat[lat.index('ddr4-map'):]
    tab = re.findall(r'<\s*(\d+) MHZ_TO_MBPS\(\s*(\d+), 8\)', lat[:lat.index('};')])
    if [(int(a) // 1000, int(b)) for a, b in tab] != [(902, 451), (1401, 1017), (1804, 1555), (2016, 1804)]:
        bad(f'Gold table: {tab}')
    print(f'ok    {len(rows)} clocks, the keys, the order, the Gold table against {ksrc}')
else:
    print('SKIP  no stock kernel source')
if os.path.exists(mbn):
    d = open(mbn, 'rb').read()
    code, data = d[0x3000:0x3000 + 0x27e04], d[0x2ae10:0x2ae10 + 0xafb4]
    if b'/clk/dcvs.ena\0' not in code:
        bad('no /clk/dcvs.ena in the firmware')
    # the rows of the DDR table: the top must be what stock's top vote and level 11 reach
    rows_ = struct.unpack_from('<20I', data, 0x9516c - 0x90000)
    ddr = [rows_[i] for i in range(0, 20, 2)]
    if ddr != [200000, 300000, 451200, 547200, 681600, 768000, 1017600, 1353600, 1555200, 1804800]:
        bad(f'DDR table in the firmware: {ddr}')
    print('ok    the firmware has /clk/dcvs.ena and the DDR table of the test')
else:
    print('SKIP  no stock rpm.mbn')
sys.exit(1 if errs else 0)
