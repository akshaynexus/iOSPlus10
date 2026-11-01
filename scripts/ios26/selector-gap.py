#!/usr/bin/env python3
"""selector-gap.py [--front FILE] [--plugin FILE] LISTING...: Metal selectors that images of the 23F84 cache send and the frontend does not answer.

  LISTING = a `dsc-image.py lst` listing (out/ios26/metal-spi/QuartzCore.lst); FUNCTION filter with NAME@REGEX ("QuartzCore.lst@MetalContext");
            or NAME.sel = `dsc-image.py syms IMAGE` output: all selector stubs of an image (scripts/ios26/metal-trace.sh).
Static [V]: every `_objc_msgSend$sel` stub call in the listing, against the protocols of Metal's class dump (out/ios26/metal-spi/Metal.classdump.txt)
and the methods of the frontend (out/metal/src/flame/.../NativeBridgeMetalFrontend.mm), including _MTLDevice's own for the device.
A missing selector is a crash only if the object that receives it is ours [I]; `respondsToSelector:` guards are not read here.
Exit 0 always; the last line counts "required" (protocol @required) and "optional" misses. Run with python3 -I.
"""
import importlib.util
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
spec = importlib.util.spec_from_file_location("gap16", os.path.join(REPO, "scripts/metal/selector-gap.py"))
gap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gap)
SPI = os.path.join(REPO, os.environ.get("METAL_SPI", "out/ios26/metal-spi"))


def protocols():
    """protocol -> {selector: optional}, from `ipsw class-dump` text (methods and @property)."""
    out, sup = {}, {}
    for f in ("Metal.classdump.txt", "AGXMetalA13.classdump.txt", "IOGPU.classdump.txt"):
        p = os.path.join(SPI, f)
        if not os.path.exists(p):
            continue
        cur, opt = None, False
        for line in open(p, errors="replace"):
            m = re.match(r"@protocol (\w+)(?: <([^>]*)>)?", line)
            if m:
                cur, opt = m.group(1), False
                out.setdefault(cur, {})
                sup[cur] = [x.strip() for x in (m.group(2) or "").split(",") if x.strip()]
                continue
            if line.startswith("@end"):
                cur = None
            if cur is None:
                continue
            if "@optional" in line or "optional instance methods" in line:
                opt = True
            if "@required" in line or "required instance methods" in line:
                opt = False
            m = re.match(r"-\[\w+ ([\w:]+)\];", line.strip())
            if m:
                out[cur][m.group(1)] = out[cur].get(m.group(1), True) and opt
            m = re.match(r"@property \(([^)]*)\) (\w+);", line.strip())
            if m:
                attrs = m.group(1).split(",")
                g = [a[1:] for a in attrs if a.startswith("G")]
                s = [a[1:] for a in attrs if a.startswith("S")]
                out[cur][g[0] if g else m.group(2)] = opt
                if "R" not in attrs:
                    out[cur][s[0] if s else "set" + m.group(2)[0].upper() + m.group(2)[1:] + ":"] = opt
    return out, sup


def class_methods(name):
    """-[name sel] of the class dumps, with the superclass chain below NSObject."""
    have, seen = set(), set()
    while name and name != "NSObject" and name not in seen:
        seen.add(name)
        nxt = None
        for f in ("Metal.classdump.txt", "IOGPU.classdump.txt"):
            p = os.path.join(SPI, f)
            if not os.path.exists(p):
                continue
            on = False
            for line in open(p, errors="replace"):
                m = re.match(r"@interface (\w+) : (\w+)", line)
                if m and m.group(1) == name:
                    on, nxt = True, m.group(2)
                    continue
                if line.startswith("@end"):
                    on = False
                if on:
                    q = re.match(r"-\[\w+ ([\w:]+)\];", line.strip())
                    if q:
                        have.add(q.group(1))
                    q = re.match(r"@property \(([^)]*)\) (\w+);", line.strip())
                    if q:
                        have.add(q.group(2))
                        if "R" not in q.group(1).split(","):
                            have.add("set" + q.group(2)[0].upper() + q.group(2)[1:] + ":")
        name = nxt
    return have


def sent(listing):
    if listing.endswith(".sel"):            # dsc-image.py syms IMAGE | grep objc_msgSend$: every selector stub of the image
        return {m.group(1) for m in re.finditer(r"_objc_msgSend\$(\S+)", open(listing, errors="replace").read())}
    path, _, rx = listing.partition("@")
    want = re.compile(rx) if rx else None
    on, out = want is None, set()
    for line in open(path, errors="replace"):
        if line.endswith(":\n") and line.strip() and not line[0].isdigit():
            on = want is None or bool(want.search(line))
            continue
        if on:
            m = re.search(r"_objc_msgSend\$(\S+)", line)
            if m:
                out.add(m.group(1))
    return out


def main():
    argv = sys.argv[1:]
    front = os.path.join(REPO, "out/metal/src/flame/phone/metal2/NativeBridgeMetalFrontend.mm")
    plugin = os.path.join(REPO, "userland/metal/plugin/NegroniMetal.mm")
    if "--front" in argv:
        i = argv.index("--front")
        front = argv[i + 1]
        del argv[i:i + 2]
    if "--plugin" in argv:
        i = argv.index("--plugin")
        plugin = argv[i + 1]
        del argv[i:i + 2]
    if not argv:
        sys.exit(__doc__)
    protos, psup = protocols()
    sels, sup = gap.frontend(front)
    psel, _ = gap.frontend(plugin)
    have_any = set().union(*sels.values()) | set().union(*psel.values())
    # runtime answers: installed from the bridge's tables
    for f in (os.path.join(os.path.dirname(front), "bridge/NativeMetalObjects.rs"),
              os.path.join(os.path.dirname(front), "../../../metal2vulkan/crates/metal2vulkan-runtime/src/private_properties.rs")):
        if os.path.exists(f):
            have_any |= set(re.findall(r'\(\s*"([A-Za-z]\w*:?)"\s*,', open(f).read()))
    dev = class_methods("_MTLDevice")
    driver = {p: s for p, s in protos.items() if p.startswith("MTL") and not p.startswith(("MTLGPUDebug", "MTLDebug", "MTL4Machine"))}
    of = {}
    for p, s in driver.items():
        for k, opt in s.items():
            of.setdefault(k, []).append((p, opt))
    total = {"required": 0, "optional": 0}
    for listing in argv:
        name = os.path.basename(listing)
        q = sent(listing)
        used = sorted(k for k in q if k in of)
        miss = [k for k in used if k not in have_any]
        print(f"# {name}: {len(q)} selectors sent, {len(used)} in Metal driver protocols, {len(miss)} not in the frontend")
        for k in miss:
            ps = of[k]
            in_dev = k in dev
            req = any(not opt and not p.endswith(("SPI", "GGDSPI", "Internal", "Private")) for p, opt in ps)
            kind = "required" if req else "optional"
            if not in_dev:
                total[kind] += 1
            print(f"{kind:8} {'_MTLDevice has it' if in_dev else 'MISSING          '} {k:60} {','.join(sorted(set(p for p, _ in ps)))[:90]}")
        # per object: the protocols of the objects the frontend makes, against the class that stands for each
        classes = dict(gap.CLASS_OF)
        for x in ("NBBuffer", "NBTexture"):
            for pr in ("MTLResource", "MTLResourceSPI", "MTLAllocation"):
                classes.setdefault(pr + "@" + x, x)
        for pr, cls in sorted(classes.items()):
            pname = pr.split("@")[0]
            if pname not in protos:
                continue
            chain, c = set(), cls
            while c and c != "NSObject":
                chain |= sels.get(c, set())
                c = sup.get(c)
            if cls == "NBDeviceMethods":
                chain |= dev | set().union(*psel.values()) | have_any
            chain |= {"retain", "release", "autorelease", "class", "description", "debugDescription", "hash", "isEqual:", "self", "copy"}
            lost = [k for k in sorted(protos[pname]) if k in q and k not in chain]
            if lost:
                print(f"object {pr:44} {cls:18}: " + " ".join(lost))
    print(f"selector-gap: missing, not in _MTLDevice: {total['required']} required, {total['optional']} optional/SPI")


if __name__ == "__main__":
    main()
