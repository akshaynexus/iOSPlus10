"""12377 rules for the negroni series (read by scripts/ios26/apply-series.py).

The iOS 16 patches (external/slop/negroni-ios/xnu/patches, patches/xnu) stay the only copy of each change.
This file holds only what differs on xnu-12377, as data. Each rule names the patches it serves ("patches":
list of file names or number prefixes, "*" = every patch) and one line "why". Kinds:

  sub          replace text in the hunk lines of files matching "file" (glob); "regex": True for re.sub
  insert_after add "lines" (as "+" lines) after the first "+" line that contains "after"
  drop_hunk    drop the hunks of "file" whose text contains "contains" (12377 or our base has them)
  drop_file    drop every section of the patch for files matching "file"
  rename_file  move the section for "old" to "new" (file renamed in 12377)
  post_sub     after the patch is applied, replace "old" with "new" in tree files matching "file"
  port         drop the sections for "file" and apply patches/xnu-12377/parts/"part" after the patch: the
               12377 port of those files, for a change that the other kinds cannot express (listed in README)

A rule for named patches that changes nothing is an ERROR (stale rule). "*" rules may match nothing.
"tag" (optional) names the rule in the result line (default: its kind).
Skips (patches that 12377 does not need, or that are in the 12377 base) are in patches/xnu-12377/skip.txt.
"""
from pathlib import Path

_SKIP_FILE = Path(__file__).resolve().parents[2] / "patches" / "xnu-12377" / "skip.txt"


def _read_skip():
    skip = {}
    for line in _SKIP_FILE.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        name, _, why = line.partition(" ")
        skip[name] = why.strip()
    return skip


SKIP = _read_skip()

RULES = [
    dict(patches="*", kind="sub", file="bsd/dev/negroni_*.c", old="#include <vm/vm_kern.h>",
         new="#include <vm/vm_kern_xnu.h>", tag="vm_kern_xnu.h",
         why="12377: kmem_alloc/kmem_free/KMA_* moved from vm_kern.h to vm_kern_xnu.h"),
    dict(patches=["0015"], kind="sub", multiline=True, regex=True, file="bsd/kern/kern_trustcache.c",
         old=r"^ #if   PMAP_CS_PPL_MONITOR\n \tret = ppl_(\w+)\((.*)\);\n",
         new=r" #if CONFIG_SPTM\n \tret = txm_\1(\2);\n #elif PMAP_CS_PPL_MONITOR\n \tret = ppl_\1(\2);\n",
         why="12377 puts a CONFIG_SPTM (TXM) branch before each PPL trust cache call"),
    dict(patches=["0035"], kind="sub", multiline=True, file="bsd/kern/bsd_init.c",
         old=" #if NEGRONI_HFS\n \t/* HFS is built in on NEGRONI: register it like its kext would, before mounting root. */\n"
             " \textern void negroni_hfs_register(void);\n",
         new=" #if CONFIG_PROC_UUID_POLICY\n \t/* Initial proc_uuid_policy subsystem */\n"
             " \tbsd_init_kprintf(\"calling proc_uuid_policy_init()\\n\");\n",
         why="context: no built-in HFS (0026) on 12377 yet; anchor on the 12377 line after vfsinit()"),
    dict(patches=["0037", "0057"], kind="sub", file="config/MASTER.arm64.negroni", old=" negroni_hfs", new="",
         why="no negroni_hfs option in the 12377 master config (HFS, 0026, is not staged on 12377 yet)"),
    dict(patches=["0039"], kind="sub", file="bsd/kern/kern_core.c", old="#if CONFIG_COREDUMP\n",
         new="#if CONFIG_COREDUMP || CONFIG_UCOREDUMP\n", why="12377 guard of kern_core.c"),
    dict(patches=["0043"], kind="sub", file="bsd/kern/kern_exit.c",
         old="etype != EXC_RESOURCE || etype != EXC_GUARD", new="etype != EXC_RESOURCE && etype != EXC_GUARD",
         why="12377 fixed || to && in proc_prepareexit (context line)"),
    dict(patches=["0070"], kind="rename_file", old="bsd/vm/vm_unix.c", new="bsd/kern/kern_proc.c",
         why="12377 moved pid_hibernate from vm_unix.c to kern_proc.c"),
    dict(patches=["0070"], kind="sub", multiline=True, file="bsd/kern/kern_proc.c", old=" #if SOCKETS\n int\n",
         new=" #if SOCKETS\n \n", why="context: in kern_proc.c a blank line follows #if SOCKETS"),
    dict(patches=["0080"], kind="sub", file="bsd/net/rtsock.c", old="rtm->rtm_", new="RTM->rtm_",
         why="12377 route_output reads the header through the RTM macro (no rtm variable)"),
    dict(patches=["0377"], kind="sub", multiline=True, regex=True, file="bsd/kern/kern_exec.c",
         old=r"(?s)^ \t\(void\) mach_vm_allocate_kernel\(map, &scratch_addr.*\Z",
         new=" #if DEVELOPMENT || DEBUG\n \t/* Use the opportunity to initialize exec's debug log stream */\n"
             " \texec_log_handle = os_log_create(\"com.apple.xnu.bsd\", \"exec\");\n",
         why="context: 12377 load_init_program opens the exec log before mach_vm_allocate_kernel"),
    dict(patches=["0111"], kind="sub", multiline=True, file="bsd/kern/kern_exit.c",
         old=" \n \t/*\n \t * Generate a corefile/crashlog if:\n",
         new=" \n \tif (task) {\n \t\tcorpse_source = vm_map_is_corpse_source(get_task_map(task));\n",
         why="context: 12377 proc_prepareexit reads corpse_source before the corefile comment"),
    dict(patches=["0395"], kind="port", file="osfmk/kern/sched_prim.c", part="0395-negroni-cpuperf.patch",
         why="12377 scheduler: idle choice in choose_processor uses idle_map after the perfcontrol preferred/"
             "avoided maps; the realtime choice moved to sched_rt.c (non-SMT pset_choose_processor_for_realtime_thread)"),
    dict(patches=["0031"], kind="drop_file", file="bsd/negroni_hfs/*",
         why="no built-in HFS (0026) on 12377 yet: its HFS hunks wait for the 12377 HFS stage"),
]

# Files that the 12377 base patches own: the base holds the iOS 16 change of these files, ported to 12377
# (scripts/ios26/port-file.sh). For each file: (base patch, "drop", "keep"). The tool drops the hunks of the
# "drop" patches for that file (counted as one rule each) and applies the hunks of the "keep" patches as
# usual. Any other series patch that changes the file is an ERROR: port the change into the base patch, then
# list the patch number.
BASE_OWNED = {
    "config/MASTER.arm64.negroni": ("0002", "0006 0007 0008", "0021 0026 0037 0057"),
    "config/Private.arm64.exports": ("0002", "0009"),
    "config/Private.exports": ("0002", "0009"),
    "makedefs/MakeInc.def": ("0002", "0001 0004"),
    "osfmk/arm64/proc_reg.h": ("0002", "0004"),
    "pexpert/pexpert/arm64/Makefile": ("0002", "0004"),
    "pexpert/pexpert/arm64/NEGRONI.h": ("0002", "0004 0065 0078"),
    "pexpert/pexpert/arm64/board_config.h": ("0002", "0004"),
    "osfmk/arm/arm_init.c": ("0003", "0010 0012"),
    "osfmk/arm/model_dep.c": ("0003", "0121"),
    "osfmk/arm/pmap/pmap.c": ("0001", "0008 0126"),
    "osfmk/arm/pmap/pmap_misc.c": ("0003", "0008"),
    "osfmk/arm64/Makefile": ("0003", "0012"),
    "osfmk/arm64/arm_vm_init.c": ("0003", "0010 0011 0012 0088"),
    "osfmk/arm64/caches_asm.s": ("0003", "0008"),
    "osfmk/arm64/cpu.c": ("0003", "0065 0288"),
    "osfmk/arm64/machine_routines.c": ("0003", "0008 0065 0078 0083"),
    "osfmk/arm64/negroni_cpuidle.c": ("0003", "0288 0383"),
    "osfmk/arm64/negroni_early.c": ("0003", "0010 0012 0088"),
    "osfmk/arm64/negroni_early.h": ("0003", "0010 0012"),
    "osfmk/arm64/sleh.c": ("0003", "0004 0017 0084 0085 0086 0094 0288 0295 0297"),
    "osfmk/arm64/start.s": ("0003", "0004 0008 0010 0065 0088"),
    "osfmk/conf/files.arm64": ("0003", "0010 0288 0382"),
    "pexpert/arm/pe_fiq.c": ("0003", "0004 0017 0082 0288 0295"),
    "pexpert/pexpert/arm/protos.h": ("0003", "0003 0017"),
    "iokit/Kernel/IOService.cpp": ("0004", "0021 0022 0202"),
    "iokit/Kernel/IOStartIOKit.cpp": ("0004", "0200 0202 0203"),
    "iokit/Kernel/arm/NegroniCPU.cpp": ("0004", "0018 0065 0078 0091 0288 0382"),
    "iokit/Kernel/arm/NegroniPlatformExpert.cpp": ("0004", "0016 0046 0059 0203 0211 0213 0234 0244 0360 0367 0387"),
    "iokit/KernelConfigTables.cpp": ("0004", "0016 0018", "0038 0040 0046 0058 0062 0089 0124 0201 0221 0271 0301"),
    "iokit/conf/files.arm64": ("0004", "0016 0018", "0035 0038 0040 0046 0058 0062 0118 0201 0221 0250 0301 0340"),
    "osfmk/console/serial_console.c": ("0004", "0047 0067"),
    "osfmk/kern/debug.c": ("0004", "0010"),
    "osfmk/kern/negroni_top.c": ("0004", "0382"),
    "pexpert/arm/pe_serial.c": ("0004", "0003 0012"),
}

# Build-list files: the tool adds each "+" line of these files next to its context line wherever that line is
# in 12377 (apply_glue), instead of a text hunk. 8796 and 12377 differ around our lines; the order is free.
GLUE_FILES = [
    "bsd/conf/files", "bsd/conf/files.arm64", "iokit/conf/files", "iokit/conf/files.arm64",
    "libkern/conf/files", "osfmk/conf/files", "osfmk/conf/files.arm64",
]
