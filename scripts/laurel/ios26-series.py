"""Mi A3 (SWEET machine config) series on xnu-12377.121.6: profile for scripts/ios26/apply-series.py.

Same method as the negroni port (patches/xnu-12377/README.md): one series, data rules, base-owned files, an explicit
skip list. Series = external/ios-topaz/xnu/patches/*.patch + patches/laurel/xnu/*.patch, sorted by name, the same
patches as the iOS 16 kernel (scripts/laurel/kernel-linux.sh). A driver fix lands once.

Base: patches/xnu-12377/0001 (non-Apple SoC base, shared with negroni) + patches/laurel/xnu-12377/NNNN-*.patch.
SHADOW: the same series on xnu-8796.141.3 (scripts/laurel/ios26-series-tree.sh makes it). A section that does not apply
as text is merged three-way (git merge-file) with the iOS 16 change: the result line says "3way FILE". A conflict is an
ERROR: the file goes into BASE_OWNED with its port in a base patch. No 8796 snapshot is copied.
"""
import os
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
P26 = REPO / "patches" / "laurel" / "xnu-12377"


def _ref(name):
    """external/NAME of this checkout, or of the main checkout (a worktree has no reference repos)."""
    d = REPO / "external" / name
    if d.exists() and any(d.iterdir()):
        return d
    import subprocess
    out = subprocess.run(["git", "-C", str(REPO), "worktree", "list", "--porcelain"], capture_output=True, text=True).stdout
    return Path(out.splitlines()[0].split(" ", 1)[1]) / "external" / name


TOPAZ = _ref("ios-topaz") / "xnu" / "patches"
SHADOW = os.environ.get("IOS26_SHADOW") or None
BASE = [REPO / "patches" / "xnu-12377" / "0001-non-apple-soc-base.patch"] + sorted(P26.glob("[0-9][0-9][0-9][0-9]-*.patch"))
POST = sorted(P26.glob("post/*.patch"))
STAGE_ENV = {"MACHINE_CONFIG": "SWEET", "MACOS_VERSION": "26.5"}


def stage_scripts():
    return sorted(TOPAZ.glob("*.sh")) + sorted((P26 / "stage").glob("*.sh"))


def series():
    return sorted(TOPAZ.glob("*.patch")) + sorted((REPO / "patches" / "laurel" / "xnu").glob("*.patch"))


def _read_skip():
    skip = {}
    for line in (P26 / "skip.txt").read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            name, _, why = line.partition(" ")
            skip[name] = why.strip()
    return skip


SKIP = _read_skip()

RULES = [
    dict(patches="*", kind="sub", file="bsd/dev/*.c", old="#include <vm/vm_kern.h>", new="#include <vm/vm_kern_xnu.h>",
         tag="vm_kern_xnu.h", why="12377: kmem_alloc/kmem_free/KMA_* moved from vm_kern.h to vm_kern_xnu.h"),
    dict(patches=["0008"], kind="drop_file", file="osfmk/arm/pmap/pmap.c",
         why="in base patches/xnu-12377/0001 (pmap_phys_write_disable prototype, iommu ptep panic, pmap_cs lockdown guard)"),
    dict(patches=["0008"], kind="drop_file", file="osfmk/arm64/amcc_rorgn_*",
         why="12377: base 0001 builds the amcc files only with the apple_amcc option; no stub needed"),
    dict(patches=["0008"], kind="drop_file", file="osfmk/arm64/kpc.c",
         why="12377 has osfmk/arm64/kpc.c (optional config_cpu_counters; off in MASTER.arm64.sweet): no stub needed"),
    dict(patches=["0014"], kind="drop_file", file="osfmk/prng/entropy.c",
         why="12377 entropy.c has no crypto_init wait and hashes with SHA512_*: BearSSL (0033) gives those without the kext"),
    dict(patches=["0015"], kind="sub", multiline=True, regex=True, file="bsd/kern/kern_trustcache.c",
         old=r"^ #if   PMAP_CS_PPL_MONITOR\n \tret = ppl_(\w+)\((.*)\);\n",
         new=r" #if CONFIG_SPTM\n \tret = txm_\1(\2);\n #elif PMAP_CS_PPL_MONITOR\n \tret = ppl_\1(\2);\n",
         why="12377 puts a CONFIG_SPTM (TXM) branch before each PPL trust cache call"),
    dict(patches=["0039"], kind="sub", file="bsd/kern/kern_core.c", old="#if CONFIG_COREDUMP\n",
         new="#if CONFIG_COREDUMP || CONFIG_UCOREDUMP\n", why="12377 guard of kern_core.c"),
    dict(patches=["0070"], kind="rename_file", old="bsd/vm/vm_unix.c", new="bsd/kern/kern_proc.c",
         why="12377 moved pid_hibernate from vm_unix.c to kern_proc.c"),
    dict(patches=["0070"], kind="sub", multiline=True, file="bsd/kern/kern_proc.c", old=" #if SOCKETS\n int\n",
         new=" #if SOCKETS\n \n", why="context: in kern_proc.c a blank line follows #if SOCKETS"),
    dict(patches=["3080"], kind="drop_file", file="osfmk/vm/vm_fault.c",
         why="12377 reads vm_compressor_mode as a TUNABLE_DT and sets vm_config in osfmk/vm/vm_pageout.c vm_config_init, not in vm_fault_init: post/9024 holds the laurel_swap_choose hook"),
]

# Files that the base patches own. file -> (base patch, "series patches whose hunks for this file the base holds"[, "kept"]).
# A series patch that changes the file and is not listed is an ERROR: port its change into the base, then list it.
BASE_OWNED = {}
_owned = P26 / "owned.txt"
if _owned.exists():
    for _l in _owned.read_text().splitlines():
        if _l and not _l.startswith("#"):
            _f, _b, *_n = _l.split()
            BASE_OWNED[_f] = (_b, " ".join(_n))

GLUE_FILES = [
    "bsd/conf/files", "bsd/conf/files.arm64", "iokit/conf/files", "iokit/conf/files.arm64",
    "libkern/conf/files", "osfmk/conf/files", "osfmk/conf/files.arm64",
]
