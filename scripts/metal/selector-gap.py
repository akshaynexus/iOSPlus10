#!/usr/bin/env python3
"""selector-gap.py: which Metal selectors that QuartzCore (20H392) names are missing from the NegroniMetal frontend.

  python3 -I scripts/metal/selector-gap.py [--all] [--client NAME]

Static check, no phone. For each Metal protocol (class dumps of Metal + AGXMetalA11 in out/metal/spi, from
scripts/metal/spi-dump.sh), the selectors the client binary's strings hold (out/metal/spi/<NAME>.strings.txt,
default QuartzCore) are matched against the methods of the frontend class that stands for that protocol
(out/metal/src/flame/phone/metal2/NativeBridgeMetalFrontend.mm, after our patches), its superclasses, NSObject,
and for the device also _MTLDevice's own methods, the runtime's device answers and the plugin's methods
(userland/metal/plugin/NegroniMetal.mm).

A missing selector is a candidate crash (the frontend raises "unrecognized selector") only when the client sends it
to that object; a string match is not proof of a call [I]. Optional protocol methods are marked "opt": clients
normally ask respondsToSelector: first. Output: one line per protocol, then the missing selectors.
"""
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SPI = os.path.join(REPO, "out/metal/spi")
FRONT = os.path.join(REPO, "out/metal/src/flame/phone/metal2/NativeBridgeMetalFrontend.mm")
PLUGIN = os.path.join(REPO, "userland/metal/plugin/NegroniMetal.mm")
PRIV = os.path.join(REPO, "out/metal/src/metal2vulkan/crates/metal2vulkan-runtime/src/private_properties.rs")
OBJECTS_RS = os.path.join(REPO, "out/metal/src/flame/phone/metal2/bridge/NativeMetalObjects.rs")

# protocol -> frontend class that answers for it
CLASS_OF = {
    "MTLDevice": "NBDeviceMethods", "MTLDeviceSPI": "NBDeviceMethods",
    "MTLCommandQueue": "NBQueue", "MTLCommandQueueSPI": "NBQueue",
    "MTLCommandBuffer": "NBCommandBuffer", "MTLCommandBufferSPI": "NBCommandBuffer",
    "MTLCommandEncoder": "NBEncoder", "MTLCommandEncoderSPI": "NBEncoder",
    "MTLRenderCommandEncoder": "NBRenderEncoder", "MTLRenderCommandEncoderSPI": "NBRenderEncoder",
    "MTLBlitCommandEncoder": "NBBlitEncoder", "MTLBlitCommandEncoderSPI": "NBBlitEncoder",
    "MTLComputeCommandEncoder": "NBComputeEncoder", "MTLComputeCommandEncoderSPI": "NBComputeEncoder",
    "MTLTexture": "NBTexture", "MTLTextureSPI": "NBTexture", "MTLTextureImplementation": "NBTexture",
    "MTLBuffer": "NBBuffer", "MTLBufferSPI": "NBBuffer",
    "MTLResource": "NBBuffer", "MTLResourceSPI": "NBBuffer",
    "MTLLibrary": "NBLibrary", "MTLLibrarySPI": "NBLibrary",
    "MTLFunction": "NBFunction", "MTLFunctionSPI": "NBFunction",
    "MTLRenderPipelineState": "NBRenderPipeline", "MTLRenderPipelineStateSPI": "NBRenderPipeline",
    "MTLComputePipelineState": "NBComputePipeline", "MTLComputePipelineStateSPI": "NBComputePipeline",
    "MTLSamplerState": "NBSampler", "MTLSamplerStateSPI": "NBSampler",
    "MTLDepthStencilState": "NBDepthStencil", "MTLDepthStencilStateSPI": "NBDepthStencil",
    "MTLEvent": "NBEvent", "MTLEventSPI": "NBEvent",
    "MTLSharedEvent": "NBSharedEvent", "MTLSharedEventSPI": "NBSharedEvent",
    "MTLFence": "NBFence", "MTLFenceSPI": "NBFence",
    "MTLHeap": "NBHeap", "MTLHeapSPI": "NBHeap",
    "MTLBinaryArchive": "NBBinaryArchive", "MTLBinaryArchiveSPI": "NBBinaryArchive",
}


def protocols():
    """protocol -> {selector: optional?} from the class dumps"""
    out = {}
    for f in ("Metal.classdump.txt", "AGXMetalA11.classdump.txt", "IOGPU.classdump.txt"):
        p = os.path.join(SPI, f)
        if not os.path.exists(p):
            continue
        cur, opt = None, False
        for line in open(p, errors="replace"):
            m = re.match(r"@protocol (\w+)", line)
            if m:
                cur, opt = m.group(1), False
                out.setdefault(cur, {})
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
                sel = m.group(1)
                out[cur][sel] = out[cur].get(sel, True) and opt
    return out


def skip_parens(s, i):
    """s[i] == '(': index after the matching ')'"""
    depth = 0
    while i < len(s):
        if s[i] == "(":
            depth += 1
        elif s[i] == ")":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return i


def method_selector(decl):
    """'- (id)foo:(int)a bar:(void (^)(int))b' -> 'foo:bar:'"""
    i = decl.index("(")
    i = skip_parens(decl, i)
    parts = []
    while i < len(decl):
        m = re.match(r"\s*(\w*)\s*", decl[i:])
        name = m.group(1)
        i += m.end()
        if i < len(decl) and decl[i] == ":":
            parts.append(name + ":")
            i += 1
            while i < len(decl) and decl[i] == " ":
                i += 1
            if i < len(decl) and decl[i] == "(":
                i = skip_parens(decl, i)
            m = re.match(r"\s*\w+", decl[i:])
            i += m.end() if m else 0
        else:
            if not parts and name:
                return name
            break
    return "".join(parts)


def frontend(path):
    """class -> set of selectors, class -> superclass"""
    text = open(path, errors="replace").read()
    macros = {}
    for m in re.finditer(r"#define (\w+) \\\n((?:.*\\\n)*.*\n)", text):
        macros[m.group(1)] = set(method_selector(d) for d in re.findall(r"^\s*([-+] \(.*?)\s*\{", m.group(2), re.M))
    sels, sup = {}, {}
    for m in re.finditer(r"@interface (\w+)\s*:\s*(\w+)", text):
        sup[m.group(1)] = m.group(2)
    cur = None
    lines, pending = [], ""
    for line in text.split("\n"):        # join method declarations that span lines (up to their "{" or ";")
        if pending:
            pending += " " + line.strip()
            if "{" in line or line.rstrip().endswith(";"):
                lines.append(pending)
                pending = ""
            continue
        if re.match(r"\s*[-+] \(", line) and "{" not in line and not line.rstrip().endswith(";"):
            pending = line.strip()
            continue
        lines.append(line)
    for line in lines:
        m = re.match(r"@implementation (\w+)", line)
        if m:
            cur = m.group(1)
            sels.setdefault(cur, set())
            continue
        m = re.match(r"@interface (\w+)", line)
        if m:
            cur_if = m.group(1)
            sels.setdefault(cur_if, set())
        if line.startswith("@end"):
            cur = None
        # properties declared in an interface give a getter (and a setter unless readonly)
        m = re.match(r"@property\s*\(([^)]*)\)\s*[^;]*?\b(\w+)\s*;", line)
        if m and cur is None:
            name, attrs = m.group(2), m.group(1)
            last = [k for k in sels if True][-1] if sels else None
            if last:
                g = re.search(r"getter=(\w+)", attrs)
                sels[last].add(g.group(1) if g else name)
                if "readonly" not in attrs:
                    sels[last].add("set" + name[0].upper() + name[1:] + ":")
        if cur:
            if re.match(r"\s*[-+] \(", line):
                try:
                    sels[cur].add(method_selector(line.strip().split("{")[0].strip()))
                except ValueError:
                    pass
            for mac, ms in macros.items():
                if re.match(r"^\s*" + mac + r"\b", line):
                    sels[cur] |= ms
    return sels, sup


def device_extra():
    s = set()
    p = os.path.join(SPI, "class-_MTLDevice-re.txt")
    for line in open(p, errors="replace"):
        line = line.strip()
        if line.startswith("- (") or line.startswith("+ ("):
            s.add(method_selector(line.rstrip(";")))
        m = re.match(r"@property\s*\(([^)]*)\)\s*.*?\b(\w+);", line)
        if m:
            g = re.search(r"getter=(\w+)", m.group(1))
            s.add(g.group(1) if g else m.group(2))
    for f in (PRIV, OBJECTS_RS):
        if os.path.exists(f):
            s |= set(re.findall(r'\(\s*"([A-Za-z]\w*:?)"\s*,\s*[\[\d]', open(f).read()))
    psel, _ = frontend(PLUGIN)
    for v in psel.values():
        s |= v
    s.add("supportsExtendedXR10Formats")
    return s


def main():
    show_all = "--all" in sys.argv
    client = sys.argv[sys.argv.index("--client") + 1] if "--client" in sys.argv else "QuartzCore"
    strings = set(re.findall(r'^0x[0-9a-f]+: "([A-Za-z_][\w:]*)"$',
                             open(os.path.join(SPI, client + ".strings.txt"), errors="replace").read(), re.M))
    protos = protocols()
    nsobject = set(protos.get("NSObject", {})) | {"retain", "release", "autorelease", "dealloc", "init", "copy",
                                                  "description", "debugDescription", "hash", "isEqual:", "class"}
    sels, sup = frontend(FRONT)
    dev = device_extra()
    total_used = total_missing = 0
    report = []
    for proto in sorted(CLASS_OF):
        if proto not in protos:
            continue
        cls = CLASS_OF[proto]
        have = set()
        c = cls
        while c and c != "NSObject":
            have |= sels.get(c, set())
            c = sup.get(c)
        if cls == "NBDeviceMethods":
            have |= dev
        if cls == "NBTexture":
            have |= sels.get("NBTexture", set())
        if cls == "NBBuffer":
            have |= sels.get("NBBuffer", set())
        used = sorted(s for s in protos[proto] if s in strings and s not in nsobject)
        missing = [s for s in used if s not in have]
        total_used += len(used)
        total_missing += len(missing)
        report.append((proto, cls, used, missing))
    print(f"client {client}: {total_used} protocol selectors named, {total_missing} not in the frontend")
    for proto, cls, used, missing in report:
        if not used:
            continue
        req = [s for s in missing if not protos[proto][s]]
        print(f"{proto:34s} {cls:18s} used {len(used):3d} missing {len(missing):3d} (required {len(req)})")
        for s in missing if show_all else req:
            print(f"    {'opt ' if protos[proto][s] else 'REQ '}{s}")


if __name__ == "__main__":
    main()
