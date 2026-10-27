#!/usr/bin/env python3
"""Apply the negroni kernel series to an xnu-12377 tree.

The iOS 26 kernel uses the SAME series as the iOS 16 kernel (scripts/kernel/build-local.sh): the slop
negroni patches (external/slop/negroni-ios/xnu/patches) and patches/xnu/*.patch, in file-name order, on top
of the small 12377 base (patches/xnu-12377/NNNN-*.patch). The iOS 16 patch files are not copied or changed in
git: the 12377 differences are RULES in scripts/ios26/patch-rules.py, applied to the patch text (or to the
tree right after the patch). Rule and layout: patches/xnu-12377/README.md.

    scripts/ios26/apply-series.py XNU_DIR [--dev] [--commit] [--upto NNNN] [--only NAME...]

Order: base patches, then the slop stage scripts (*.sh), then the series. One result line per patch:
    base | ran | applied | applied+rules(N) | replaced | skipped: REASON | ERROR: ...
Any ERROR (a patch that does not apply, a rule that no longer matches, a stale skip/replace entry) makes the
exit status 1, so a new iOS 16 patch that breaks on 12377 shows at once.

--dev     a failing patch is applied with --reject; the result line lists the rejected files (to write rules)
--commit  one git commit per step in XNU_DIR ("git diff HEAD" after an edit shows what a rule must do)
--upto    stop before the first series patch whose name sorts at or after NNNN
"""
import argparse
import fnmatch
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
P26 = REPO / "patches" / "xnu-12377"
sys.path.insert(0, str(HERE))
import importlib.util  # noqa: E402

_spec = importlib.util.spec_from_file_location("patch_rules", HERE / "patch-rules.py")
rules_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(rules_mod)


def slop_dir():
    s = Path(os.environ.get("SLOP", REPO / "external" / "slop"))
    if not (s / "negroni-ios").is_dir():  # a worktree without submodules: use the main checkout's slop
        out = subprocess.run(["git", "-C", str(REPO), "worktree", "list", "--porcelain"],
                             capture_output=True, text=True).stdout
        main = next(line.split(" ", 1)[1] for line in out.splitlines() if line.startswith("worktree "))
        s = Path(main) / "external" / "slop"
    return s / "negroni-ios" / "xnu" / "patches"


def run(cmd, cwd, inp=None):
    return subprocess.run(cmd, cwd=cwd, input=inp, capture_output=True, text=True, encoding="latin-1")


# ---- patch text model: sections ("diff --git" blocks), each = header lines + hunks ----
class Section:
    def __init__(self, lines):
        self.header, self.hunks = [], []
        for line in lines:
            if line.startswith("@@"):
                self.hunks.append([line])
            elif self.hunks:
                self.hunks[-1].append(line)
            else:
                self.header.append(line)

    @property
    def path(self):
        plus = next((l for l in self.header if l.startswith("+++ ")), None)
        if plus and not plus.startswith("+++ /dev/null"):
            return re.sub(r"^b/", "", plus[4:].split("\t")[0].strip())
        minus = next((l for l in self.header if l.startswith("--- ")), None)
        if minus and not minus.startswith("--- /dev/null"):
            return re.sub(r"^a/", "", minus[4:].split("\t")[0].strip())
        return re.match(r"diff --git a/(\S+) b/(\S+)", self.header[0]).group(2)

    def text(self):
        return "".join(self.header) + "".join("".join(_recount(h)) for h in self.hunks)


def _recount(h):
    """Hunk header counts from the hunk lines (rules may add lines; git apply --recount would read a
    following plain-diff "--- a/..." header as a removed line)."""
    m = re.match(r"@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@(.*)", h[0], re.S)
    if not m:
        return h
    body = h[1:]
    # trailing lines that are not hunk lines (blank separators, "-- " signatures) stay as they are
    old = sum(1 for l in body if l[:1] in " -" and not l.startswith("-- \n"))
    new = sum(1 for l in body if l[:1] in " +")
    return [f"@@ -{m.group(1)},{old} +{m.group(2)},{new} @@{m.group(3)}"] + body


def parse(text):
    lines = text.splitlines(keepends=True)
    pre, secs, cur = [], [], None
    for i, line in enumerate(lines):
        # a section starts at "diff --git", or at "--- " + "+++ " (plain unified diff) outside a git header
        plain = (line.startswith("--- ") and i + 1 < len(lines) and lines[i + 1].startswith("+++ ")
                 and (cur is None or any(l.startswith("@@") for l in cur)))
        if line.startswith("diff --git ") or plain:
            cur = [line]
            secs.append(cur)
        elif cur is None:
            pre.append(line)
        else:
            cur.append(line)
    # a trailing "-- \n2.x" signature (git format-patch) belongs to no hunk
    return pre, [Section(s) for s in secs]


def render(pre, secs):
    return "".join(pre) + "".join(s.text() for s in secs)


def matches(rule, name):
    keys = rule["patches"]
    return keys == "*" or any(name == k or name.startswith(k + "-") for k in keys)


def apply_text_rule(rule, secs):
    """Apply one text rule to the sections; return the number of changes."""
    kind, n = rule["kind"], 0
    glob = rule.get("file", "*")
    if kind == "drop_file":
        keep = [s for s in secs if not fnmatch.fnmatch(s.path, glob)]
        n = len(secs) - len(keep)
        secs[:] = keep
    elif kind == "drop_hunk":
        emptied = []
        for s in secs:
            if fnmatch.fnmatch(s.path, glob) and s.hunks:
                keep = [h for h in s.hunks if rule["contains"] not in "".join(h)]
                n += len(s.hunks) - len(keep)
                s.hunks = keep
                if not keep:
                    emptied.append(s)
        secs[:] = [s for s in secs if s not in emptied]
    elif kind == "rename_file":
        for s in secs:
            if s.path == rule["old"]:
                s.header = [l.replace(rule["old"], rule["new"]) for l in s.header]
                n += 1
    elif kind == "sub" and rule.get("multiline"):
        # on the whole hunk body (lines keep their " "/"+"/"-" prefix): re-anchor context, change several lines
        for s in secs:
            if not fnmatch.fnmatch(s.path, glob):
                continue
            for k, h in enumerate(s.hunks):
                body = "".join(h[1:])
                if rule.get("regex"):
                    nb, c = re.subn(rule["old"], rule["new"], body, flags=re.M)
                else:
                    c = body.count(rule["old"])
                    nb = body.replace(rule["old"], rule["new"])
                if c:
                    s.hunks[k] = [h[0]] + nb.splitlines(keepends=True)
                    n += c
    elif kind == "sub":
        old, new = rule["old"], rule["new"]
        for s in secs:
            if not fnmatch.fnmatch(s.path, glob):
                continue
            for h in s.hunks:
                for i, line in enumerate(h):
                    if line[:1] not in "+- " or line.startswith("@@"):
                        continue
                    body = line[1:]
                    nb = re.sub(old, new, body) if rule.get("regex") else body.replace(old, new)
                    if nb != body:
                        # a context line that a rule changes must change in the tree too: only "+" lines
                        # and "-"/" " lines whose 12377 text is the new one may be rewritten
                        h[i] = line[0] + nb
                        n += 1
    elif kind == "insert_after":  # add "+" lines after the "+" line that contains rule["after"]
        for s in secs:
            if not fnmatch.fnmatch(s.path, glob):
                continue
            for h in s.hunks:
                for i, line in enumerate(h):
                    if line.startswith("+") and rule["after"] in line:
                        h[i + 1:i + 1] = ["+" + t + "\n" for t in rule["lines"]]
                        n += 1
                        break
                if n:
                    break
    elif kind == "port":
        keep = [s for s in secs if not fnmatch.fnmatch(s.path, glob)]
        n = len(secs) - len(keep)
        secs[:] = keep
    else:
        raise SystemExit(f"unknown rule kind {kind}")
    return n


def apply_tree_rule(rule, xnu):
    """post_sub: edit a tree file right after the patch is applied."""
    n = 0
    for f in sorted(Path(xnu).glob(rule["file"])):
        t = f.read_text(encoding="latin-1")
        if rule.get("regex"):
            nt, c = re.subn(rule["old"], rule["new"], t)
        else:
            c = t.count(rule["old"])
            nt = t.replace(rule["old"], rule["new"])
        if c:
            f.write_text(nt, encoding="latin-1")
            n += c
    return n


def _norm(line):
    return " ".join(line.split())


def apply_glue(xnu, sec):
    """Build-list files (GLUE_FILES): add each "+" line next to its context line, wherever that line is in
    the 12377 file (the lists differ from 8796 around our lines; their order does not matter). A line that is
    already there is left alone; a "-" line is removed. Returns an error text or ""."""
    f = Path(xnu) / sec.path
    if not f.exists():
        return f"{sec.path}: no such file"
    lines = f.read_text(encoding="latin-1").splitlines(keepends=True)
    for h in sec.hunks:
        body = [l for l in h[1:] if l[:1] in "+- "]
        anchor = None  # index in lines after which the next "+" line goes
        for k, l in enumerate(body):
            kind, text = l[0], l[1:]
            norm = [_norm(x) for x in lines]
            if kind in " -":
                if _norm(text) and _norm(text) in norm:
                    i = norm.index(_norm(text))
                    if kind == "-":
                        del lines[i]
                        anchor = i - 1
                    else:
                        anchor = i
                continue
            if _norm(text) and _norm(text) in norm:
                anchor = norm.index(_norm(text))
                continue
            if anchor is None:  # no context before: the first later context line that exists
                nxt = next((b[1:] for b in body[k + 1:] if b[0] == " " and _norm(b[1:]) in norm and _norm(b[1:])), None)
                # no context line is in the 12377 list at all: append at the end
                anchor = norm.index(_norm(nxt)) - 1 if nxt is not None else len(lines) - 1
            lines.insert(anchor + 1, text if text.endswith("\n") else text + "\n")
            anchor += 1
    f.write_text("".join(lines), encoding="latin-1")
    return ""


def git_apply(xnu, text, check_only=False, reject=False):
    with tempfile.NamedTemporaryFile("w", suffix=".patch", delete=False, encoding="latin-1") as t:
        t.write(text)
        path = t.name
    try:
        args = ["git", "apply", "--whitespace=nowarn"]
        if reject:
            r = run(args + ["--reject", path], xnu)
            rej = sorted({re.sub(r"\.rej$", "", str(p.relative_to(xnu))) for p in Path(xnu).rglob("*.rej")
                          if ".git" not in p.parts})
            for p in Path(xnu).rglob("*.rej"):
                if ".git" not in p.parts:
                    p.unlink()
            errs = set(re.findall(r"^error: patch failed: ([^:\s]+):", r.stderr, re.M))
            errs |= set(re.findall(r"^error: ([^:\s]+): (?:already exists|does not exist)", r.stderr, re.M))
            return sorted(set(rej) | set(errs))
        r = run(args + ["--check", path], xnu)
        if r.returncode or check_only:
            return r
        return run(args + [path], xnu)
    finally:
        os.unlink(path)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("xnu")
    ap.add_argument("--dev", action="store_true")
    ap.add_argument("--commit", action="store_true")
    ap.add_argument("--upto")
    a = ap.parse_args()
    xnu = str(Path(a.xnu).resolve())
    S = slop_dir()
    skip, rules = rules_mod.SKIP, rules_mod.RULES
    bad = []
    count = {"applied": 0, "applied+rules": 0, "replaced": 0, "skipped": 0}
    used_skip, used_replace = set(), set()
    rule_hits = [0] * len(rules)

    def res(name, what):
        print(f"{name:<62} {what}", flush=True)
        if what.startswith("ERROR"):
            bad.append(name)

    def step(msg):
        if a.commit:
            run(["git", "add", "-A"], xnu)
            run(["git", "-c", "commit.gpgsign=false", "-c", "user.name=apply-series", "-c",
                 "user.email=apply-series@localhost", "commit", "-q", "--allow-empty", "-m", msg], xnu)

    print(f"== base ({P26})")
    for p in sorted(P26.glob("[0-9][0-9][0-9][0-9]-*.patch")):
        r = git_apply(xnu, p.read_text(encoding="latin-1"))
        res(p.name, "base" if r.returncode == 0 else "ERROR: base patch does not apply: " + r.stderr.strip()[:200])
        step("base " + p.name)

    print(f"== stage scripts ({S})")
    env = dict(os.environ, MACHINE_CONFIG="NEGRONI")
    for s in sorted(S.glob("*.sh")):
        if s.name in skip:
            used_skip.add(s.name)
            count["skipped"] += 1
            res(s.name, "skipped: " + skip[s.name])
            continue
        r = subprocess.run(["bash", str(s)], cwd=xnu, env=env, capture_output=True, text=True)
        res(s.name, "ran" if r.returncode == 0 else "ERROR: stage script failed: " + r.stderr.strip()[-200:])
        step("script " + s.name)

    print("== series (slop + patches/xnu)")
    series = [p for p in S.glob("*.patch") if p.name != "0127-negroni-gpu-show.patch"]
    series += list((REPO / "patches" / "xnu").glob("*.patch"))
    for p in sorted(series, key=lambda x: x.name):
        name = p.name
        if a.upto and name >= a.upto:
            print("stop before " + name)
            break
        if name in skip:
            used_skip.add(name)
            count["skipped"] += 1
            res(name, "skipped: " + skip[name])
            continue
        rp = P26 / "replace" / name
        if rp.exists():
            used_replace.add(name)
            r = git_apply(xnu, rp.read_text(encoding="latin-1"))
            if r.returncode == 0:
                count["replaced"] += 1
                res(name, "replaced")
            else:
                res(name, "ERROR: replacement does not apply: " + r.stderr.strip()[:200])
            step(name + " (replaced)")
            continue
        text = p.read_text(encoding="latin-1")
        mine = [(i, r) for i, r in enumerate(rules) if matches(r, name)]
        tags, stale = [], []
        if mine:
            pre, secs = parse(text)
            for i, r in mine:
                if r["kind"] == "post_sub":
                    continue
                c = apply_text_rule(r, secs)
                rule_hits[i] += c
                if r["patches"] != "*":
                    tags.append(r.get("tag", r["kind"]))
                    if c == 0:
                        stale.append(r["why"])
                elif c:
                    tags.append(r.get("tag", r["kind"]))
            text = render(pre, secs)
        # files owned by the 12377 base: their iOS 16 hunks are in base 000N (ported); a patch not listed
        # for that file is an ERROR (port its change into the base patch, then list it)
        owned_err = []
        pre, secs = parse(text)
        keep = []
        for s in secs:
            own = rules_mod.BASE_OWNED.get(s.path)
            listed = lambda keys: any(name == k or name.startswith(k + "-") for k in keys.split())
            if own is None or listed(own[2] if len(own) > 2 else ""):
                keep.append(s)
            elif listed(own[1]):
                tags.append("base " + own[0])
            else:
                owned_err.append(f"{s.path} (owned by base {own[0]})")
        if owned_err:
            res(name, "ERROR: changes a file of the 12377 base: " + ", ".join(owned_err))
            continue
        if not keep:
            res(name, "ERROR: nothing left after the base-owned files: add it to skip.txt (in 12377 base)")
            continue
        glue = [s for s in keep if any(fnmatch.fnmatch(s.path, g) for g in rules_mod.GLUE_FILES)
                and not any(l.startswith(("--- /dev/null", "new file")) for l in s.header)]
        keep = [s for s in keep if s not in glue]
        if glue:
            tags.append("glue")
        text = render(pre, keep)
        if stale:
            res(name, "ERROR: rule did not match (stale): " + "; ".join(stale))
            continue
        if not keep:
            r = subprocess.CompletedProcess([], 0, "", "")
        else:
            r = git_apply(xnu, text)
        if r.returncode == 0 or a.dev:
            gerr = [e for e in (apply_glue(xnu, s) for s in glue) if e]
            if gerr:
                res(name, "ERROR: build-list lines: " + "; ".join(gerr))
        if r.returncode:
            if a.dev:
                rej = git_apply(xnu, text, reject=True)
                why = (r.stderr or r.stdout).strip().splitlines()[:1]
                res(name, "ERROR: does not apply (dev: applied with rejects in: " + " ".join(rej) + ") " + " ".join(why)[:160])
            else:
                res(name, "ERROR: does not apply: " + (r.stderr or r.stdout).strip().splitlines()[0][:200])
            step(name + " (rejects)")
            continue
        for i, r in mine:
            if r["kind"] == "port":
                part = P26 / "parts" / r["part"]
                pr = git_apply(xnu, part.read_text(encoding="latin-1")) if part.exists() else None
                if pr is None or pr.returncode:
                    res(name, f"ERROR: port part {part.name} does not apply" + (": " + pr.stderr.strip()[:160] if pr else " (missing)"))
            if r["kind"] == "post_sub":
                c = apply_tree_rule(r, xnu)
                rule_hits[i] += c
                tags.append("post_sub")
                if c == 0 and r["patches"] != "*":
                    res(name, "ERROR: post rule did not match (stale): " + r["why"])
        if tags:
            count["applied+rules"] += 1
            res(name, f"applied+rules({len(tags)}): " + ", ".join(sorted(set(tags))))
        else:
            count["applied"] += 1
            res(name, "applied")
        step(name)

    if not a.upto:
        for n in sorted(set(skip) - used_skip):
            res(n, "ERROR: skip.txt entry names no series patch (stale)")
        for rp in sorted((P26 / "replace").glob("*.patch")) if (P26 / "replace").is_dir() else []:
            if rp.name not in used_replace and rp.name not in skip:
                res(rp.name, "ERROR: replacement names no series patch (stale)")
    print("== series: " + ", ".join(f"{v} {k}" for k, v in count.items()) + f", {len(bad)} errors")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
