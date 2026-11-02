#!/usr/bin/env python3
"""The table of laurel_gpu_opp.h against the stock source and the stock DTB of the phone. Args: HEADER KERNEL_TREE BOOT_IMG DTBO_IMG."""
import os, re, struct, subprocess, sys, tempfile

hdr, kernel, boot, dtbo = sys.argv[1:5]
errors = []
def need(cond, msg):
    if not cond:
        errors.append(msg)

text = open(hdr).read()
corners = {m[1]: int(m[2]) for m in re.finditer(r'#define (CX_\w+)\s+(\d+)u', text)}
SRC = {'OPP_SRC_PLL0': (2, 0), 'OPP_SRC_PLL1': (4, 1), 'OPP_SRC_GPLL0': (5, None)}
rows = re.findall(r'\{\s*(\d+), (OPP_SRC_\w+),\s+(\d), (OPP_NO_PLL|\d),\s+(\d+), (0x\w+), (0x\w+), (\d), (CX_\w+),\s+(\d+), (\d) \}', text)
assert len(rows) == 8, f'{len(rows)} rows'
opp = {int(r[0]): dict(src=SRC[r[1]][0], pll=SRC[r[1]][1], div=int(r[2]), hdr_pll=r[3], l=int(r[4]), u=int(r[5], 16), a=int(r[6], 16), vco=int(r[7]),
                       cx=corners[r[8]], bus=int(r[9]), ipeak=int(r[10])) for r in rows}

def stock_pll(rate):
    """clk-alpha-pll.c alpha_pll_round_rate + clk_alpha_pll_set_rate (40-bit register), 19.2 MHz."""
    p = 19200000
    l, rem = divmod(rate, p)
    a32 = 0
    if rem:
        a32, r = divmod(rem << 32, p)
        a32 += 1 if r else 0
    a40 = a32 << 8
    return l, a40 >> 32, a40 & 0xffffffff

# ---------- gpucc-trinket.c, trinket-gpu.dtsi, vdd-level, gpulist
g = os.path.join(kernel, 'drivers/clk/qcom/gpucc-trinket.c')
if os.path.exists(g):
    s = open(g).read()
    ftbl = s[s.index('ftbl_gpu_cc_gx_gfx3d_clk_src[]'):]
    ftbl = ftbl[:ftbl.index('{ }')]
    stock = {int(m[1]) // 1000000: (m[2], int(m[3])) for m in re.finditer(r'F\((\d+), (P_\w+), (\d), 0, 0\)', ftbl)}
    need(sorted(stock) == [320, 465, 600, 745, 820, 900, 950], f'stock rates {sorted(stock)}')
    pmap = dict(re.findall(r'\{ (P_\w+), (\d) \}', s[s.index('gpu_cc_parent_map_1[]'):s.index('gpu_cc_parent_names_1[]')]))
    # the CX limit of each rate
    rm = s[s.index('.name = "gpu_cc_gx_gfx3d_clk_src"'):]
    rm = rm[:rm.index('}')+200]
    limit = [(m[1], int(m[2]) // 1000000) for m in re.finditer(r'\[(VDD_\w+)\] = (\d+)', rm)]
    v = open(os.path.join(kernel, 'drivers/clk/qcom/vdd-level-trinket.h')).read()
    names = re.findall(r'^\s*(VDD_\w+),', v[v.index('enum vdd_dig_levels'):v.index('VDD_NUM')], re.M)
    lv = re.findall(r'RPM_REGULATOR_LEVEL_(\w+),', v[v.index('vdd_corner[]'):])
    r = open(os.path.join(kernel, 'include/linux/regulator/rpm-smd-regulator.h')).read()
    level = {m[1]: int(m[2]) for m in re.finditer(r'RPM_REGULATOR_LEVEL_(\w+)\s*=\s*(\d+)', r)}
    corner_of = {n: level[lv[i]] for i, n in enumerate(names)}
    for mhz, (src, h) in stock.items():
        o = opp[mhz]
        lim = min((m for _, m in limit if m >= mhz))
        name = [n for n, m in limit if m == lim][0]
        need(o['cx'] == corner_of[name], f'{mhz}: CX {o["cx"]}, stock {name} = {corner_of[name]}')
        if mhz == 600:
            need(src == 'P_GPU_CC_PLL0_OUT_AUX2' and o['src'] == 5 and o['div'] == 1, '600: stock PLL0 AUX2; here GPLL0 / 1 on purpose')
            continue
        need(int(pmap[src]) == o['src'], f'{mhz}: source {o["src"]}, stock {pmap[src]}')
        need(h == o['div'], f'{mhz}: divider {o["div"]}, stock {h}')
        vco = mhz * 2 * 1000000
        need((vco >= 1000000000 and o['vco'] == 0) or (vco < 1000000000 and o['vco'] == 2), f'{mhz}: VCO range {o["vco"]}')
        need(vco <= 2000000000, f'{mhz}: VCO above the MX NOM limit')
        l, u, a = stock_pll(vco)
        need((o['l'], o['u'], o['a']) == (l, u, a), f'{mhz}: L {o["l"]} {o["u"]:#x} {o["a"]:#x}, stock {l} {u:#x} {a:#x}')
    # GPLL0 rates: 600 from GPLL0 / 1, 300 from GPLL0 / 2 (not stock, and not above the corner of 320)
    need(opp[300]['src'] == 5 and opp[300]['div'] == 2 and opp[300]['cx'] <= opp[320]['cx'], '300: GPLL0 / 2 at the corner of 320')
    # bus: pwrlevels and msm-bus vectors
    d = open(os.path.join(kernel, 'arch/arm64/boot/dts/qcom/trinket-gpu.dtsi')).read()
    vec = [int(x) for x in re.findall(r'<26 512 0 (\d+)>', d)]
    mine = {int(m[1]) // 1000000: int(m[2]) for m in re.finditer(r'qcom,gpu-freq = <(\d+)>;\s*qcom,bus-freq = <(\d+)>', d) if int(m[1])}
    need(sorted(mine) == sorted(stock), 'pwrlevels')
    for mhz, lvl in mine.items():
        bus = vec[lvl] // 8 // 1000
        need(opp[mhz]['bus'] == bus, f'{mhz}: bus {opp[mhz]["bus"]}, stock level {lvl} = {bus}')
    # iPeak
    gl = open(os.path.join(kernel, 'drivers/gpu/msm/adreno-gpulist.h')).read()
    m = re.search(r'ADRENO_REV_A610.*?cx_ipeak_gpu_freq = (\d+)', gl, re.S)
    ip = int(m[1]) // 1000000
    for mhz, o in opp.items():
        need(o['ipeak'] == (1 if mhz >= ip else 0), f'{mhz}: iPeak {o["ipeak"]}, stock from {ip}')
    need('gpu-cx-ipeak = <&cx_ipeak_lm 5>' in d, 'iPeak client 5')
    # the thermal limits
    t = open(os.path.join(kernel, 'arch/arm64/boot/dts/qcom/trinket-thermal.dtsi')).read()
    z = t[t.index('gpu-step {'):]
    need('tsens0 15' in z[:400], 'sensor')
    hot = re.search(r'gpu-trip \{\s*temperature = <(\d+)>;\s*hysteresis = <(\d+)>', z)
    crit = re.search(r'gpu-cx-mon \{\s*temperature = <(\d+)>;\s*hysteresis = <(\d+)>', z)
    defs = {m[1]: int(m[2]) for m in re.finditer(r'#define (OPP_\w+_DC)\s+(\d+)', text)}
    need(defs['OPP_HOT_DC'] * 100 == int(hot[1]), f'hot {hot[1]}')
    need(defs['OPP_CRIT_DC'] * 100 == int(crit[1]), f'crit {crit[1]}')
    need(defs['OPP_CRIT_CLR_DC'] * 100 == int(crit[1]) - int(crit[2]), 'crit clear')
    print('ok    table against gpucc-trinket.c, trinket-gpu.dtsi, vdd-level-trinket.h, adreno-gpulist.h, trinket-thermal.dtsi')
else:
    print('SKIP  stock source: no external/laurel-kernel-los')

# ---------- the phone's DTB
if os.path.exists(boot) and subprocess.run(['sh', '-c', 'command -v dtc >/dev/null']).returncode == 0:
    b = open(boot, 'rb').read()
    seen = 0
    with tempfile.TemporaryDirectory() as w:
        off = 0
        while True:
            i = b.find(b'\xd0\x0d\xfe\xed', off)
            if i < 0:
                break
            sz = struct.unpack('>I', b[i+4:i+8])[0]
            if not (0x100 < sz < 0x400000 and i + sz <= len(b)):
                off = i + 4
                continue
            f = os.path.join(w, 'x.dtb')
            open(f, 'wb').write(b[i:i+sz])
            off = i + sz
            dts = subprocess.run(['dtc', '-q', '-I', 'dtb', '-O', 'dts', f], capture_output=True, text=True).stdout
            if 'TRINKET SoC' not in dts:
                continue
            seen += 1
            lv = re.findall(r'qcom,gpu-freq = <(0x\w+)>;\s*qcom,bus-freq = <(0x\w+)>;\s*qcom,bus-min = <(0x\w+)>;\s*qcom,bus-max = <(0x\w+)>', dts)
            for fr, bf, _, _ in lv:
                mhz = int(fr, 16) // 1000000
                if mhz:
                    need(mhz in opp, f'DTB level {mhz} is not in the table')
            need({int(x[0], 16) // 1000000 for x in lv if int(x[0], 16)} == {320, 465, 600, 745, 820, 900, 950}, 'DTB levels')
            need('qcom,gpu-speed-bin' not in dts, 'the DTB has a speed bin: the table is not the same for all parts')
            z = dts[dts.index('gpu-step {'):]
            need(re.search(r'gpu-trip \{\s*temperature = <0x17318>', z) is not None, 'DTB hot trip')
            need(re.search(r'gpu-cx-mon \{\s*temperature = <0x186a0>;\s*hysteresis = <0x1388>', z) is not None, 'DTB cx trip')
    need(seen > 0, 'no TRINKET DTB in boot.img')
    # no dtbo entry touches the GPU's levels
    if os.path.exists(dtbo):
        d = open(dtbo, 'rb').read()
        need(b'qcom,gpu-freq' not in d, 'dtbo.img changes GPU levels')
    print(f'ok    table against the stock DTB ({seen} TRINKET in boot.img), dtbo.img has no GPU levels')
else:
    print('SKIP  stock DTB: no ~/laurel-backup/stock/images/boot.img or no dtc')

for e in errors:
    print('FAIL', e)
sys.exit(1 if errors else 0)
