#!/usr/bin/env python3
"""pipeline-table.py > docs/laurel_sprout/ios26-evidence/metal-pipelines.tsv: every function of QuartzCore's 23F84 default.metallib: what it serves, the translator's result (metal2vulkan -> SPIR-V, A610 profile),
the real compile for FD610 (Turnip + ir3 on the host through drm-shim), ir3's numbers, and a verdict. Inputs: out/ios26/metal-corpus/<set>/<lib>/results.tsv, out/ios26/ir3/<lib>/{result,stats}.tsv,
out/ios26/metal-spi/QuartzCore-metallib.txt. Text only: names and counts. Host result: no pixel exists, no speed measured. Run with python3 -I."""
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
LIB = "Frameworks_QuartzCore.framework_default.metallib"
OUT = os.path.join(REPO, "out/ios26")


def role(n):
    table = [("glass_foreground", "Liquid Glass, top layer"), ("glass_background", "Liquid Glass, backdrop refraction + blur"), ("fixed_", "CA's fixed-function shader (every layer, image, color)"),
             ("std_vert", "plain quads"), ("variable_blur", "backdrop filter: variable blur"), ("narrow_blur", "backdrop filter: Gaussian blur"), ("downsample_blur", "backdrop filter: blur downsample"),
             ("downsample_", "blur / mip downsample"), ("upsample", "blur upsample"), ("single_pass_blur", "small blur"), ("asg_", "adaptive scale (ASG) image resample"),
             ("resolve_blur", "blur resolve"), ("tile_", "Apple tile shader (imageblocks)"), ("inplace_copy", "framebuffer in-place copy (raster order groups)"),
             ("sdf_", "SDF generation (rounded rects, glass shapes)"), ("simple_rim", "SDF rim light"), ("brim_", "SDF rim, jump flood"), ("rim_outline", "SDF rim"),
             ("path_", "path rendering (shapes)"), ("stroke_", "strokes"), ("axial_", "gradient"), ("radial_", "gradient"), ("conic_", "gradient"), ("chromatic_", "chromatic aberration filter"),
             ("displacement_", "displacement filter"), ("alpha_", "alpha filters"), ("p3_clamp", "wide-gamut clamp"), ("edr_", "EDR"), ("color_edr", "EDR"), ("luma_", "luma"), ("home_affordance", "home bar"),
             ("buffer_image", "image upload"), ("image_rect", "image blit"), ("attachment_clear", "clear"), ("apply_apl", "APL dimming"), ("compute_apl", "APL (OLED dimming)"), ("sum_apl", "APL"),
             ("compute_average", "average luma"), ("compute_sum", "average luma"), ("read_write_surf", "surface copy"), ("read_surf", "surface readback"), ("rgb_to_420f", "video conversion"),
             ("dynamic_system_ootf", "tone mapping")]
    for pre, what in table:
        if n.startswith(pre):
            return what
    return "other"


def main():
    res = {}
    for s in ("ui", "all"):
        p = f"{OUT}/metal-corpus/{s}/{LIB}/results.tsv"
        if os.path.exists(p):
            for line in open(p):
                f = line.rstrip("\n").split("\t")
                if len(f) >= 3 and f[1] and f[1] != "bash":
                    res[f[1]] = (f[0], f[2])
    made = {}
    p = f"{OUT}/ir3/{LIB}/result.tsv"
    for line in open(p):
        f = line.rstrip("\n").split("\t")
        if len(f) >= 3:
            made[f[1]] = (f[0], f[2], f[3] if len(f) > 3 else "")
    stats = {}
    head = None
    for line in open(f"{OUT}/ir3/{LIB}/stats.tsv"):
        f = line.rstrip("\n").split("\t")
        if head is None:
            head = f
            continue
        d = dict(zip(head, f))
        if d["stage"] in ("FRAG", "CL"):                 # the largest variant
            if d["pipeline"] not in stats or int(d["instr"]) > int(stats[d["pipeline"]]["instr"]):
                stats[d["pipeline"]] = d
    print("function\tkind\trole\ttranslate\tir3 FD610\tcompile host ms\tinstr\tnops\ttex (cat5)\tmem (cat6)\tfull regs (limit 48)\tconst vec4\tverdict")
    names = [l.split()[:2] for l in open(f"{OUT}/metal-spi/QuartzCore-metallib.txt") if l.startswith("  ")]
    counts = {}
    for kind, n in names:
        tr = res.get(n, ("?", "not run"))[1]
        trs = "pass" if tr.startswith("PASS") else re.sub(r"^FALLBACK \(compile failed: ", "", tr)[:70]
        m = made.get(n)
        ms = m[1].replace(" ms", "") if m else ""
        i3 = ("made" if m[0] == "ok" else "refused: " + m[2][:60]) if m else ("vertex: compiled with its fragment" if kind == "vertex" else "not asked")
        s = stats.get(n, {})
        instr = int(s.get("instr", 0) or 0)
        if n.startswith("tile_") and kind == "kernel":
            verdict = "not used: supportsTileShaders NO (no Turnip imageblocks); CA has a render-pass path [I]"
        elif n.startswith("inplace_copy"):
            verdict = "fails, not needed if CA reads supportsRasterOrderGroups NO [I]: no pixel interlock on Turnip FD610"
        elif not tr.startswith("PASS"):
            verdict = "fails: " + trs
        elif m and m[0] != "ok":
            verdict = "fails in ir3 or Vulkan: " + m[2][:70]
        elif kind == "vertex":
            verdict = "supported (host)"
        elif n.startswith("fixed_frag"):
            verdict = "supported (host); this row has zero constants (no output, 1 instruction), so it says nothing: see the ca_generic row. Real specializations: not run"
        elif instr >= 1000:
            verdict = "supported (host), heavy: %d instructions a pixel" % instr
        elif instr >= 300:
            verdict = "supported (host), costly: %d instructions a pixel" % instr
        else:
            verdict = "supported (host)"
        counts[verdict.split(":")[0].split(",")[0]] = counts.get(verdict.split(":")[0].split(",")[0], 0) + 1
        print("\t".join([n, kind, role(n), trs, i3, ms, str(instr or ""), s.get("nops", ""), s.get("cat5", ""), s.get("cat6", ""), s.get("full", ""), s.get("constlen", ""), verdict]))
    g = stats.get("ca_generic_lph_cph", {})
    print("\t".join(["ca_generic_lph_cph (fixed_vert_lph_gen + fixed_frag_lph_cph, fc_generic=1)", "fragment", "CA's uber-shader: every draw until a specialized pipeline exists", "pass",
                     "made", made.get("ca_generic_lph_cph", ("", "", ""))[1].replace(" ms", ""), g.get("instr", ""), g.get("nops", ""), g.get("cat5", ""), g.get("cat6", ""), g.get("full", ""),
                     g.get("constlen", ""), "supported (host), heavy: %s instructions in the binary, only the taken branches run" % g.get("instr", "?")]))
    print("# summary " + "; ".join(f"{k}: {v}" for k, v in sorted(counts.items())), file=sys.stderr)


if __name__ == "__main__":
    main()
