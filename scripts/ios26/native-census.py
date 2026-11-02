#!/usr/bin/env python3
"""native-census.py [--front FRONTEND.mm]: which Metal driver calls the 23F84 compositor images send, per protocol, with each image's count.
Static [V]: the objc_msgSend$ stubs of `dsc-image.py lst` and `syms` output (out/ios26/metal-spi, scripts/ios26/metal-trace.sh) against the protocols of Metal's class dump.
A selector name can be sent to a non-Metal object too, so a row says "an image sends this name", not "this image calls Metal with it". Only names; no Apple code.
Output: TSV on stdout (protocol, selector, in frontend, images), one summary line per image on stderr. Run with python3 -I."""
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SPI = os.path.join(REPO, os.environ.get("METAL_SPI", "out/ios26/metal-spi"))
IMAGES = ["QuartzCore.lst", "RenderBox.lst", "RenderBox.sel", "IconRendering.sel", "CoreUI.sel", "CoreImage.sel", "SwiftUICore.sel", "UIKitCore.sel", "MaterialKit.sel", "IconServices.sel"]
PROTOCOLS = {"MTLDevice", "MTLDeviceSPI", "MTLCommandQueue", "MTLCommandQueueSPI", "MTLCommandBuffer", "MTLCommandBufferSPI", "MTLRenderCommandEncoder", "MTLRenderCommandEncoderSPI",
             "MTLComputeCommandEncoder", "MTLComputeCommandEncoderSPI", "MTLBlitCommandEncoder", "MTLBlitCommandEncoderSPI", "MTLCommandEncoder", "MTLCommandEncoderSPI", "MTLTexture", "MTLTextureSPI",
             "MTLBuffer", "MTLBufferSPI", "MTLResource", "MTLResourceSPI", "MTLHeap", "MTLHeapSPI", "MTLFence", "MTLEvent", "MTLSharedEvent", "MTLSharedEventSPI", "MTLLibrary", "MTLLibrarySPI", "MTLFunction", "MTLFunctionSPI",
             "MTLRenderPipelineState", "MTLRenderPipelineStateSPI", "MTLComputePipelineState", "MTLComputePipelineStateSPI", "MTLDepthStencilState", "MTLSamplerState", "MTLArgumentEncoder", "MTLResidencySet",
             "MTLBinaryArchive", "MTLDrawable", "MTLIndirectCommandBuffer", "MTLParallelRenderCommandEncoder", "MTLAllocation"}


def protocols():
    out = {}
    cur = None
    p = os.path.join(SPI, "Metal.classdump.txt")
    for line in open(p, errors="replace"):
        m = re.match(r"@protocol (\w+)", line)
        if m:
            cur = m.group(1) if m.group(1) in PROTOCOLS else None
            continue
        if line.startswith("@end"):
            cur = None
        if cur is None:
            continue
        m = re.match(r"-\[\w+ ([\w:]+)\];", line.strip())
        if m:
            out.setdefault(m.group(1), set()).add(cur)
        m = re.match(r"@property \(([^)]*)\) (\w+);", line.strip())
        if m:
            attrs = m.group(1).split(",")
            g = [a[1:] for a in attrs if a.startswith("G")]
            s = [a[1:] for a in attrs if a.startswith("S")]
            out.setdefault(g[0] if g else m.group(2), set()).add(cur)
            if "R" not in attrs:
                out.setdefault(s[0] if s else "set" + m.group(2)[0].upper() + m.group(2)[1:] + ":", set()).add(cur)
    return out


def sent(path):
    names = {}
    for line in open(path, errors="replace"):
        for m in re.finditer(r"objc_msgSend\$([\w:]+)", line):
            names[m.group(1)] = names.get(m.group(1), 0) + 1
    return names


def main():
    front = None
    if len(sys.argv) > 2 and sys.argv[1] == "--front":
        front = open(sys.argv[2], errors="replace").read()
    pro = protocols()
    rows = {}
    for image in IMAGES:
        path = os.path.join(SPI, image)
        if not os.path.exists(path):
            continue
        s = sent(path)
        hit = {k: v for k, v in s.items() if k in pro}
        print(f"{image}: {sum(s.values())} calls of {len(s)} names; {sum(hit.values())} calls of {len(hit)} names in Metal's protocols", file=sys.stderr)
        for k, v in hit.items():
            rows.setdefault(k, {})[image.split(".")[0]] = rows.setdefault(k, {}).get(image.split(".")[0], 0) + v
    print("protocol\tselector\tin_frontend\timages")
    for k in sorted(rows, key=lambda k: (sorted(pro[k])[0], k)):
        head = re.split(r":", k)[0]
        infront = "?" if front is None else ("yes" if re.search(r"\b" + re.escape(head) + r"\b", front) else "no")
        print(f"{'|'.join(sorted(pro[k]))}\t{k}\t{infront}\t{','.join(f'{i}={n}' for i, n in sorted(rows[k].items()))}")


if __name__ == "__main__":
    main()
