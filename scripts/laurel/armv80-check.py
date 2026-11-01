#!/usr/bin/env python3
"""ARMv8.0 check for Mi A3 (Kryo 260: Gold = Cortex-A73, Silver = Cortex-A53) binaries.

The CPUs have ARMv8.0 + CRC32 + AES/SHA1/SHA2/PMULL only. Any later instruction is SIGILL (or a slow kernel trap for
LSE/LDAPR, topaz 0081). This script disassembles every Mach-O given (llvm-objdump decodes all AArch64 extensions) and
counts the instructions of each later extension. Hint-space instructions (PACIASP, AUTIASP, PACIBSP, BTI, XPACLRI,
...) are NOPs on ARMv8.0 and are not counted.

  scripts/laurel/armv80-check.py FILE...         one line per file; exit 1 if any file has one
  scripts/laurel/armv80-check.py --self-test     the patterns find a sample of each class and miss v8.0 code
  scripts/laurel/armv80-check.py --data-syms A,B FILE   an unstripped kernel: words under these symbols are data that the
                                                 disassembler decodes (K256 table, jump tables, panic strings); they are
                                                 counted apart and do not fail the check
"""
import re
import subprocess
import sys

# class -> regex on "mnemonic operands" (llvm-objdump --no-show-raw-insn, lower case)
CLASSES = [
    ("LSE (v8.1)", r"(casp?|swp|ld(add|clr|eor|set|[su]m(ax|in))|st(add|clr|eor|set|[su]m(ax|in)))(a|l|al)?(b|h)?"),
    ("RCpc (v8.3/8.4)", r"(ldapu?r(b|h|sb|sh|sw)?|stlur(b|h)?)"),
    ("RDM (v8.1)", r"sqrdml[as]h"),
    ("DotProd (v8.2)", r"(us|[su])dot"),
    ("FP16 arith (v8.2)",
     r"f(add|sub|mul|mulx|div|mla|mls|nmul|max|min|maxnm|minnm|maxp|minp|maxnmp|minnmp|addp|abs|neg|sqrt|cmp|cmpe|"
     r"cm(eq|ge|gt|le|lt)|ac(ge|gt)|abd|madd|msub|nmadd|nmsub|ccmp|ccmpe|csel|recpe|recps|rsqrte|rsqrts|recpx|"
     r"rint[aimnpxz]|cvt[amnpz][su]|mov)(\s+h\d|\s+v\d+\.[48]h)"),
    ("FP16 conv (v8.2)", r"([su]cvtf)\s+(h\d|v\d+\.[48]h)"),
    ("FHM (v8.2)", r"fml[as]l2?"),
    ("SHA3/SHA512/SM (v8.2)", r"(sha512\w*|eor3|bcax|rax1|xar|sm3\w*|sm4\w*)"),
    ("JSCVT/FCMA (v8.3)", r"(fjcvtzs|fcmla|fcadd)"),
    ("PAuth non-hint (v8.3)",
     r"(retaa|retab|braaz?|brabz?|blraaz?|blrabz?|ldraa|ldrab|eretaa|eretab|pacga|"
     r"pac(ia|ib|da|db|iza|izb|dza|dzb)|aut(ia|ib|da|db|iza|izb|dza|dzb)|xpac[id])"),
    ("FlagM (v8.4/8.5)", r"(cfinv|rmif|setf8|setf16|axflag|xaflag)"),
    ("FRINTTS (v8.5)", r"frint(32|64)[xz]"),
    ("MTE (v8.5)", r"(irg|gmi|subp|subps|addg|subg|stz?2?g|stgp|ldg|ldgm|stgm|stzgm)"),
    ("BF16/I8MM (v8.6)", r"(bfdot|bfmmla|bfmlal[bt]|bfcvtn?2?|bfcvt|smmla|ummla|usmmla)"),
    ("SVE", r"\S+\s+.*\b[zp]\d+\.[bhsdq]\b"),
]
PAT = [(name, re.compile(r"^(" + rx + r")(?=[\s,]|$)")) for name, rx in CLASSES]
LINE = re.compile(r"^\s*[0-9a-f]+:\s+(.*)$")


DATA_SYMS = set()
DATA_HITS = {}


def scan(text):
    counts, examples = {}, {}
    cur = ""
    for raw in text.splitlines():
        if raw.endswith(">:"):
            cur = raw[raw.find("<") + 1:-2]
            continue
        m = LINE.match(raw)
        if not m:
            continue
        ins = m.group(1).split("//")[0].split(";")[0].strip().lower()
        for name, rx in PAT:
            if rx.match(ins):
                if cur in DATA_SYMS:
                    DATA_HITS[cur] = DATA_HITS.get(cur, 0) + 1
                    break
                counts[name] = counts.get(name, 0) + 1
                examples.setdefault(name, ins)
                break
    return counts, examples


def check_file(path):
    p = subprocess.run(["llvm-objdump", "-d", "--no-show-raw-insn", "--no-leading-addr", "--print-imm-hex", path],
                       capture_output=True, text=True)
    if p.returncode != 0:
        # --no-leading-addr drops the address: use the plain form then
        p = subprocess.run(["llvm-objdump", "-d", "--no-show-raw-insn", path], capture_output=True, text=True)
    if p.returncode != 0:
        print(f"armv80-check: {path}: llvm-objdump failed: {p.stderr.strip()[:200]}")
        return None
    # normalise: with --no-leading-addr lines are "\tmnemonic ..."; give them a fake address for LINE
    text = "\n".join(("0: " + l.strip()) if l[:1] in ("\t", " ") and l.strip() else l for l in p.stdout.splitlines())
    return scan(text)


def self_test():
    bad = {
        "LSE (v8.1)": ["ldaddal w0, w1, [x2]", "casb w0, w1, [x2]", "swph w0, w1, [x2]", "stsmaxl w0, [x1]",
                       "caspal x0, x1, x2, x3, [x4]"],
        "RCpc (v8.3/8.4)": ["ldapr x0, [x1]", "ldaprb w0, [x1]", "ldapur x0, [x1, #8]", "stlur w0, [x1]"],
        "RDM (v8.1)": ["sqrdmlah v0.4s, v1.4s, v2.4s"],
        "DotProd (v8.2)": ["udot v0.4s, v1.16b, v2.16b"],
        "FP16 arith (v8.2)": ["fadd h0, h1, h2", "fmla v0.8h, v1.8h, v2.8h", "fmov h0, w1"],
        "FP16 conv (v8.2)": ["scvtf h0, w1"],
        "SHA3/SHA512/SM (v8.2)": ["eor3 v0.16b, v1.16b, v2.16b, v3.16b"],
        "JSCVT/FCMA (v8.3)": ["fjcvtzs w0, d1"],
        "PAuth non-hint (v8.3)": ["retaa", "blraa x0, x1", "pacia x0, x1", "autda x0, x1"],
        "FlagM (v8.4/8.5)": ["cfinv"],
        "BF16/I8MM (v8.6)": ["smmla v0.4s, v1.16b, v2.16b"],
        "SVE": ["add z0.s, z1.s, z2.s"],
    }
    good = ["ldxr x0, [x1]", "stlr x0, [x1]", "ldar w0, [x1]", "ldaxr x0, [x1]", "madd x0, x1, x2, x3",
            "fcvt h0, s1", "fcvtn v0.4h, v1.4s", "fcvtl v0.4s, v1.4h", "fadd s0, s1, s2", "fmla v0.4s, v1.4s, v2.4s",
            "paciasp", "autiasp", "pacibsp", "xpaclri", "hint #0x22", "crc32cx w0, w1, x2", "aese v0.16b, v1.16b",
            "sha256h q0, q1, v2.4s", "pmull v0.1q, v1.1d, v2.1d", "ld1 { v0.8h }, [x0]", "ret", "casual_label",
            "stp x29, x30, [sp, #-16]!", "ldr h0, [x0]", "str h0, [x0]", "dup v0.8h, w1", "add v0.8h, v1.8h, v2.8h"]
    ok = True
    for name, samples in bad.items():
        for s in samples:
            c, _ = scan("0: " + s)
            if c.get(name) != 1:
                print(f"self-test: {s!r} not found as {name} ({c})")
                ok = False
    for s in good:
        c, _ = scan("0: " + s)
        if c:
            print(f"self-test: {s!r} wrongly counted: {c}")
            ok = False
    print("armv80-check: self-test " + ("PASS" if ok else "FAIL"))
    return ok


def main(argv):
    if len(argv) > 3 and argv[1] == "--data-syms":
        DATA_SYMS.update(argv[2].split(","))
        del argv[1:3]
    if argv[1:] == ["--self-test"]:
        return 0 if self_test() else 1
    if len(argv) < 2:
        print(__doc__)
        return 2
    fail = 0
    for path in argv[1:]:
        r = check_file(path)
        if r is None:
            fail = 1
            continue
        counts, examples = r
        total = sum(counts.values())
        detail = ", ".join(f"{k} {v} (e.g. {examples[k]})" for k, v in counts.items())
        print(f"armv80-check: {path.rsplit('/', 1)[-1]}: {total} instructions newer than ARMv8.0{': ' + detail if detail else ''}")
        fail |= total != 0
    return fail


if __name__ == "__main__":
    sys.exit(main(sys.argv))
