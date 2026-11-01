#!/usr/bin/env python3
"""format-table.py FD610_FORMATS_TXT: the pixel formats of CoreAnimation's Metal path (CA::OGL::MetalContext::image_parameters + framebuffer + blur attachments, 23F84) against Turnip's
format properties for FD610 (`vulkaninfo --show-formats` on the host through drm-shim). Output: TSV. A source reading of the driver's answer, not a phone capture. Run with python3 -I."""
import re
import sys

# MTLPixelFormat -> (name, Vulkan format, use in CA)
F = {1: ("A8Unorm", "R8_UNORM", "masks, glyphs (image_parameters)"), 10: ("R8Unorm", "R8_UNORM", "masks, glyph atlas"), 25: ("R16Float", "R16_SFLOAT", "image_parameters"),
     30: ("RG8Unorm", "R8G8_UNORM", "image_parameters; biplanar chroma"), 55: ("R32Float", "R32_SFLOAT", "image_parameters; attachment 2 of a tile path"), 60: ("RG16Unorm", "R16G16_UNORM", "image_parameters"),
     65: ("RG16Float", "R16G16_SFLOAT", "image_parameters"), 70: ("RGBA8Unorm", "R8G8B8A8_UNORM", "images"), 80: ("BGRA8Unorm", "B8G8R8A8_UNORM", "framebuffer, layers, images"),
     90: ("RGB10A2Unorm", "A2B10G10R10_UNORM_PACK32", "image_parameters"), 94: ("BGR10A2Unorm", "A2R10G10B10_UNORM_PACK32", "image_parameters, wide images"), 110: ("RGBA16Unorm", "R16G16B16A16_UNORM", "image_parameters"),
     115: ("RGBA16Float", "R16G16B16A16_SFLOAT", "EDR, deep layers, attachment 1 of a tile path"), 125: ("RGBA32Float", "R32G32B32A32_SFLOAT", "image_parameters"),
     240: ("GBGR422", "G8B8G8R8_422_UNORM", "video images"), 241: ("BGRG422", "B8G8R8G8_422_UNORM", "video images"), 500: ("BGRA8Unorm_sRGB-class", "B8G8R8A8_SRGB", "(sRGB form)"),
     552: ("BGRA10_XR", None, "wide color: only when supportsExtendedXR10Formats YES (not backboardd)"), 554: ("BGR10_XR", None, "wide color: same"), 562: ("BGR10_XR_sRGB-class", None, "wide color: same")}


def groups(text):
    fmts = {}
    sec = None
    props = {}
    names = []
    for line in text.splitlines():
        if line.startswith("Common Format Group"):
            for n in names:
                fmts[n] = props
            names, props, sec = [], {}, None
        s = line.strip()
        m = re.match(r"FORMAT_(?!FEATURE_)(\S+)$", s)
        if m:
            names.append(m.group(1))
            continue
        m = re.match(r"(linearTiling|optimalTiling|buffer)Features", s)
        if m:
            sec = m.group(1)
            props[sec] = set()
            continue
        m = re.match(r"FORMAT_FEATURE_(?:2_)?(\S+?)_BIT", s)
        if m and sec:
            props[sec].add(m.group(1))
    for n in names:
        fmts[n] = props
    return fmts


def main():
    fmts = groups(open(sys.argv[1], errors="replace").read())
    print("MTLPixelFormat\tname\tuse in CA\tsampled\tlinear filter\tcolor attachment\tblend\tstorage\tsampled over linear rows (an IOSurface)\tverdict on FD610")
    for k in sorted(F):
        name, vk, use = F[k]
        p = fmts.get(vk, {}).get("optimalTiling", set()) if vk else set()
        q = fmts.get(vk, {}).get("linearTiling", set()) if vk else set()
        s = "SAMPLED_IMAGE" in p
        lin = "SAMPLED_IMAGE_FILTER_LINEAR" in p
        c = "COLOR_ATTACHMENT" in p
        b = "COLOR_ATTACHMENT_BLEND" in p
        st = "STORAGE_IMAGE" in p
        if vk is None:
            v = "emulated by metal2vulkan (BGR10_XR); only asked in posters here"
        elif not p and "SAMPLED_IMAGE" in q:
            v = "supported over linear memory only (an IOSurface): sampled, no render target"
        elif not p:
            v = "no format in Turnip: fails if asked"
        elif k in (80, 70, 115, 94, 90, 10, 30) and not (s and lin and c and b):
            v = "gap: see the columns"
        else:
            v = "supported"
        print("\t".join([str(k), name, use] + ["yes" if x else "no" for x in (s, lin, c, b, st, "SAMPLED_IMAGE" in q)] + [v]))


if __name__ == "__main__":
    main()
