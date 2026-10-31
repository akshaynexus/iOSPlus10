#!/usr/bin/env python3
"""Check the Adreno 610 facts the laurel Metal path depends on, in a patched Turnip (Mesa) tree.

    scripts/laurel/metal-a610.py MESA_TREE CHIP_ID       (scripts/laurel/metal-build.sh check)

CHIP_ID = what the kernel answers for MSM_PARAM_CHIP_ID (topaz TopazAdreno.cpp: 0x06010001).
Checks (each prints one line, exit 1 if one fails):
  1. Mesa's device table (src/freedreno/common/freedreno_devices.py) has an entry whose chip id matches CHIP_ID with
     the rule of freedreno_dev_info.c (exact, or patch id 0xff = wildcard) and prints its A6xx properties;
  2. Turnip's msm KMD (tu_knl_drm_msm.cc) falls back to kernel-chosen GPU addresses when the kernel has no
     MSM_PARAM_VA_START (topaz RedwoodGPU: the SMMU is pass-through, GPU VA = PA);
  3. Turnip has an A6xx (gen 6) path (tu_device.cc "case 6").
Only reads files; no build.
"""
import ast
import os
import re
import sys


def gpu_ids(call_src):
    """chip ids of the GPUId(...) entries of one add_gpus([...]) call."""
    ids = []
    for m in re.finditer(r"GPUId\(([^)]*)\)", call_src):
        args = m.group(1)
        kw = dict(re.findall(r"(\w+)\s*=\s*([^,]+)", args))
        if "chip_id" in kw:
            ids.append(int(kw["chip_id"].strip(), 0))
            continue
        first = args.split(",")[0].strip()
        if not first or "=" in first:
            continue
        val = int(first, 0)
        core, val = divmod(val, 100)
        major, minor = divmod(val, 10)
        ids.append((core << 24) | (major << 16) | (minor << 8) | 0xFF)
    return ids


def matches(ref, chip):
    # freedreno_dev_info.c: exact, or table patch id 0xff + same core/major/minor
    return ref == chip or ((ref & 0xFF) == 0xFF and (ref & 0xFFFFFF00) == (chip & 0xFFFFFF00))


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    tree, chip = sys.argv[1], int(sys.argv[2], 0)
    fail = 0
    dev = os.path.join(tree, "src/freedreno/common/freedreno_devices.py")
    src = open(dev).read()
    found = None
    for chunk in src.split("\nadd_gpus([")[1:]:
        ids, _, info = chunk.partition("],")
        for ref in gpu_ids(ids):
            if matches(ref, chip):
                found = (ref, ids, info.split("\nadd_gpus(")[0])
                break
        if found:
            break
    if not found:
        print(f"a610: FAIL: no entry of {dev} matches chip id {chip:#010x}")
        fail = 1
    else:
        ref, ids, info = found
        props = re.search(r"\[([^\]]*)\]", info).group(1)
        keys = {}
        for k in ("num_ccu", "tile_align_w", "tile_align_h", "num_vsc_pipes", "cs_shared_mem_size", "highest_bank_bit",
                  "ubwc_swizzle", "macrotile_mode"):
            mm = re.search(rf"\b{k}\s*=\s*([^,\n]+)", info)
            if mm:
                keys[k] = mm.group(1).strip()
        print(f"a610: Mesa table entry chip {ref:#010x} matches {chip:#010x} (group {', '.join(f'{i:#010x}' for i in gpu_ids(ids))}); "
              f"props {props.strip()}; " + ", ".join(f"{k} {v}" for k, v in keys.items()))
        low = re.search(r"a6xx_gen1_low = A6XXProps\((.*?)\n\s*\)\n", src, re.S)
        if "a6xx_gen1_low" in props and low:
            flags = ", ".join(re.sub(r"\s+", " ", l.strip().rstrip(",")) for l in low.group(1).splitlines()
                              if "=" in l and not l.strip().startswith("#"))
            print(f"a610: a6xx_gen1_low: {flags}")
    knl = os.path.join(tree, "src/freedreno/vulkan/tu_knl_drm_msm.cc")
    k = open(knl).read()
    if re.search(r"has_set_iova\s*=\s*!tu_drm_get_va_prop", k):
        print("a610: Turnip msm KMD: no MSM_PARAM_VA_START -> has_set_iova = false -> kernel-chosen GPU addresses (GET_IOVA)")
    else:
        print("a610: FAIL: Turnip msm KMD has no VA_START fallback")
        fail = 1
    tud = open(os.path.join(tree, "src/freedreno/vulkan/tu_device.cc")).read()
    if re.search(r"switch \(fd_dev_gen\(&device->dev_id\)\)\s*\{\s*case 6:", tud):
        print("a610: Turnip has the A6xx (gen 6) device path")
    else:
        print("a610: FAIL: no A6xx path in tu_device.cc")
        fail = 1
    ver = open(os.path.join(tree, "VERSION")).read().strip() if os.path.exists(os.path.join(tree, "VERSION")) else "?"
    print(f"a610: Mesa {ver}: {'PASS' if fail == 0 else 'FAIL'}")
    return fail


if __name__ == "__main__":
    sys.exit(main())
