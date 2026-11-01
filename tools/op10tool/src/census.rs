//! `op10tool a64-census`: walk every executable section of a split dyld shared cache and of a tree of Mach-O files, and
//! count each word by what it does on an ARMv8.0 CPU (Mi A3: Cortex-A73/A53, fp asimd aes pmull sha1 sha2 crc32).
//!
//! The decoder is llvm-mc: every unique word is decoded with `-mcpu=cortex-a73`; each word that CPU cannot decode goes to a
//! decode with all A-profile features and then to one decode per feature, so each class name comes from LLVM's own
//! feature table. Our hand decoders in a64.rs (hints, PAC, LSE, RCpc) are cross-checked against that result. Words in the
//! system-instruction space decode on any CPU as generic MSR/MRS/SYS, so they get an EL0 allow list.
//!
//! Two counts per class:
//!   linear: every word of the section (data in code included).
//!   proven: the word is inside a function range with no undecodable word, or a static-flow walk from the function start
//!           reaches it, or it is in a stub section. Same idea as UniXNU-zeta prove-zeta-dyld-cache.py, simpler rules.
//!
//! Output in OUTDIR: census.md, classes.tsv, lse-forms.tsv, images.tsv, layout.tsv, slide.tsv, apple-opcodes.tsv,
//! sysreg.tsv, undecodable.tsv, hot-<image>.tsv.

use crate::a64::{self, LseOp};
use crate::dsc::{self, Cache, Macho, Map};
use anyhow::{bail, Context, Result};
use rayon::prelude::*;
use std::collections::{BTreeMap, HashMap};
use std::fmt::Write as _;
use std::fs;
use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};

const BATCH: usize = 1 << 20;
/// The phone: Cortex-A73 in LLVM has armv8-a + crc, aes, sha2. /proc/cpuinfo: fp asimd evtstrm aes pmull sha1 sha2 crc32 cpuid.
pub(crate) const BASE: &[&str] = &["-mcpu=cortex-a73"];
pub(crate) const FULL_ATTR: &str = "+v9.5a,+sve2,+sve2-aes,+sve2-sha3,+sve2-sm4,+sve2-bitperm,+sme2p1,+sme-f64f64,+sme-i16i64,+bf16,+i8mm,+mops,+cssc,+sha3,+sm4,+fp16fml,+rcpc3,+lse128,+the,+d128,+gcs,+ite,+lut,+faminmax,+fp8,+jsconv,+complxnum,+rand,+mte,+ls64,+wfxt,+hbc,+flagm,+altnzcv,+pauth,+predres,+sb,+specrestrict,+ssbs,+tme,+dit,+ecv,+ccdp,+ccpp";
/// Order: oldest first, so a word gets the lowest feature that decodes it.
const FEATURES: &[&str] = &[
    "lse", "rdm", "pauth", "rcpc", "rcpc-immo", "fullfp16", "fp16fml", "dotprod", "complxnum", "jsconv", "sha3", "sm4",
    "flagm", "altnzcv", "fptoint", "sb", "predres", "bti", "mte", "rand", "i8mm", "bf16", "ccdp", "ccpp", "dit", "ssbs",
    "ecv", "wfxt", "hbc", "mops", "cssc", "ls64", "lse128", "d128", "the", "rcpc3", "gcs", "tme", "lut", "faminmax",
    "fp8", "sve", "sve2", "sve2-aes", "sve2-sha3", "sve2-sm4", "sve2-bitperm", "sme", "sme2", "sme2p1", "sme-f64f64",
    "sme-i16i64",
];
/// Hot libraries for the named table; a substring of the install name.
const HOT: &[&str] = &[
    "/usr/lib/system/libsystem_platform.dylib",
    "/usr/lib/system/libsystem_malloc.dylib",
    "/usr/lib/system/libsystem_pthread.dylib",
    "/usr/lib/system/libsystem_kernel.dylib",
    "/usr/lib/system/libdispatch.dylib",
    "/usr/lib/system/libxpc.dylib",
    "/usr/lib/libobjc.A.dylib",
    "/usr/lib/dyld",
    "/usr/lib/libc++.1.dylib",
    "/usr/lib/libc++abi.dylib",
    "/usr/lib/swift/libswiftCore.dylib",
    "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation",
    "/System/Library/Frameworks/Foundation.framework/Foundation",
    "/System/Library/Frameworks/QuartzCore.framework/QuartzCore",
    "/System/Library/PrivateFrameworks/UIKitCore.framework/UIKitCore",
    "/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore",
    "/System/Library/Frameworks/Accelerate.framework/Frameworks/vecLib.framework/libBLAS.dylib",
    "/System/Library/Frameworks/Metal.framework/Metal",
    "/System/Library/Frameworks/OpenGLES.framework/OpenGLES",
    "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
    "/System/Library/PrivateFrameworks/RenderBox.framework/RenderBox",
    "/System/Library/Frameworks/Accelerate.framework/Frameworks/vImage.framework/vImage",
];

pub(crate) fn word_bytes(s: &[u8]) -> Option<&[u32]> {
    // SAFETY: u32 has no invalid bit patterns; align_to returns the aligned middle only.
    let (a, m, b) = unsafe { s.align_to::<u32>() };
    (a.is_empty() && b.is_empty()).then_some(m)
}

/// 2^32-entry bit set, safe to fill from many threads.
pub(crate) struct WordSet(Vec<AtomicU64>);
impl WordSet {
    pub(crate) fn new() -> WordSet {
        let mut v = Vec::with_capacity(1 << 26);
        v.resize_with(1 << 26, || AtomicU64::new(0));
        WordSet(v)
    }
    pub(crate) fn insert(&self, w: u32) {
        let (i, b) = ((w >> 6) as usize, 1u64 << (w & 63));
        if self.0[i].load(Ordering::Relaxed) & b == 0 {
            self.0[i].fetch_or(b, Ordering::Relaxed);
        }
    }
    pub(crate) fn has(&self, w: u32) -> bool {
        self.0[(w >> 6) as usize].load(Ordering::Relaxed) >> (w & 63) & 1 != 0
    }
    pub(crate) fn to_vec(&self) -> Vec<u32> {
        let mut out = Vec::new();
        for (i, a) in self.0.iter().enumerate() {
            let mut bits = a.load(Ordering::Relaxed);
            while bits != 0 {
                let t = bits.trailing_zeros();
                out.push(((i as u64) << 6 | t as u64) as u32);
                bits &= bits - 1;
            }
        }
        out
    }
}

/// llvm-mc on one batch of words. The result has one entry per word; None = invalid encoding.
fn llvm_batch(words: &[u32], args: &[&str], tmp: &Path, tag: usize, keep_text: bool) -> Result<Vec<Option<Box<str>>>> {
    let path = tmp.join(format!("batch-{tag}-{}.txt", std::process::id()));
    {
        let mut f = std::io::BufWriter::new(fs::File::create(&path)?);
        for w in words {
            let b = w.to_le_bytes();
            writeln!(f, "0x{:02x} 0x{:02x} 0x{:02x} 0x{:02x}", b[0], b[1], b[2], b[3])?;
        }
    }
    let input = fs::File::open(&path)?;
    let output = Command::new("llvm-mc")
        .arg("--disassemble")
        .arg("-triple=aarch64")
        .args(args)
        .stdin(Stdio::from(input))
        .output()
        .context("run llvm-mc (needs LLVM on PATH)")?;
    let _ = fs::remove_file(&path);
    let err = String::from_utf8_lossy(&output.stderr);
    let mut invalid = vec![false; words.len()];
    for line in err.lines() {
        if let Some(rest) = line.strip_prefix("<stdin>:") {
            if line.ends_with("invalid instruction encoding") {
                let n: usize = rest.split(':').next().unwrap_or("0").parse().unwrap_or(0);
                if n >= 1 && n <= words.len() {
                    invalid[n - 1] = true;
                }
            }
        }
    }
    let out = String::from_utf8_lossy(&output.stdout);
    let mut valid = out.lines().filter(|l| l.starts_with('\t') && !l[1..].starts_with('.'));
    let mut res = Vec::with_capacity(words.len());
    let mut misses = 0usize;
    for bad in invalid {
        if bad {
            res.push(None);
        } else {
            match valid.next() {
                Some(l) => res.push(Some(if keep_text { l.trim().replace('\t', " ").into() } else { "".into() })),
                None => {
                    misses += 1;
                    res.push(None)
                }
            }
        }
    }
    if misses != 0 {
        bail!("llvm-mc gave {misses} lines too few for {args:?}");
    }
    Ok(res)
}

pub(crate) fn llvm_all(words: &[u32], args: &[&str], tmp: &Path, keep_text: bool) -> Result<Vec<Option<Box<str>>>> {
    let parts: Vec<_> = words
        .par_chunks(BATCH)
        .enumerate()
        .map(|(i, c)| llvm_batch(c, args, tmp, i, keep_text))
        .collect::<Result<Vec<_>>>()?;
    Ok(parts.into_iter().flatten().collect())
}

/// One code range: an executable section or a part of an executable mapping that no section covers.
#[derive(Clone)]
pub(crate) struct Range<'a> {
    pub addr: u64,
    pub words: &'a [u32],
    pub stub: bool,
    pub section: String,
}

pub(crate) struct Unit<'a> {
    pub name: String,
    pub root: bool,
    pub file: Option<usize>,
    pub ranges: Vec<Range<'a>>,
    pub starts: Vec<u64>,
    pub symbols: Vec<(u64, String)>,
}

#[derive(Clone)]
struct Class {
    group: String,
    feature: String,
    mnemonic: String,
    /// LLVM's apple-a13 decodes the word the same way. A word that is not `a13` cannot run on a real iPhone 11, so Apple's
    /// own code gates it behind a CPU check: it is not code this userland has to run on our CPU.
    a13: bool,
}

#[derive(Default)]
struct UnitCount {
    words: u64,
    proven_words: u64,
    undecodable: u64,
    linear: HashMap<u16, u64>,
    proven: HashMap<u16, u64>,
    amx: u64,
    amx_proven: u64,
    apple: HashMap<u32, u64>,
    lse_words: HashMap<u32, (u64, u64)>,
    hot_sites: Vec<(u64, u32, u64)>,
    undecodable_prefix: HashMap<u16, u64>,
    lse_lr_dead: u64,
    lse_sp_base: u64,
}

/// True when every path from word `i` writes x30 before anything can read it, so a `bl` at the site is harmless.
/// Any word with 30 in a register field that is not a known write counts as a read. Bounded; unknown = not dead.
pub(crate) fn lr_dead_after(r: &Range, code: &[bool], site: usize) -> bool {
    let n = r.words.len();
    let end = r.addr + n as u64 * 4;
    let mut stack = vec![site + 1];
    let mut seen = std::collections::HashSet::new();
    let mut steps = 0;
    while let Some(mut at) = stack.pop() {
        loop {
            if at >= n || !code[at] {
                return false;
            }
            if !seen.insert(at) {
                break;
            }
            steps += 1;
            if steps > 512 {
                return false;
            }
            let w = r.words[at];
            // writes of x30 with no read
            if w & 0xfc00_0000 == 0x9400_0000 {
                break; // bl
            }
            if w & 0xffff_fc1f == 0xd63f_0000 && (w >> 5) & 31 != 30 {
                break; // blr Xn, n != 30
            }
            if w & 0xffff_f800 == 0xd63f_0800 && (w >> 5) & 31 != 30 && w & 31 != 30 {
                break; // blraa(z), blrab(z) (the a64 family with Rm in the low bits)
            }
            if w & 0xffff_f800 == 0xd73f_0800 && (w >> 5) & 31 != 30 && w & 31 != 30 {
                break;
            }
            // ldp x?, x30, [Xn...] / ldr x30, [Xn...]: x30 is only written when the base is not x30
            if w & 0xffc0_0000 == 0xa940_0000 || w & 0xffc0_0000 == 0xa8c0_0000 || w & 0xffc0_0000 == 0xa9c0_0000 {
                let (rt, rn, rt2) = (w & 31, (w >> 5) & 31, (w >> 10) & 31);
                if rn != 30 && (rt == 30 || rt2 == 30) {
                    break;
                }
                if rn == 30 {
                    return false;
                }
                at += 1;
                continue;
            }
            if w & 0xffc0_0000 == 0xf940_0000 && w & 31 == 30 && (w >> 5) & 31 != 30 {
                break; // ldr x30, [Xn, #imm]
            }
            if w & 0xffe0_0c00 == 0xf840_0400 && w & 31 == 30 && (w >> 5) & 31 != 30 {
                break; // ldr x30, [Xn], #imm
            }
            // hints do not touch x30 here: the PAC ones are NOP after lowering or on this CPU
            if a64::hint_imm(w).is_some() {
                at += 1;
                continue;
            }
            let (next, target) = a64::flow(w, r.addr + at as u64 * 4);
            let is_branch = target.is_some();
            if is_branch {
                if let Some(t) = target {
                    if t < r.addr || t >= end {
                        return false; // tail call out of the range: x30 goes to the callee
                    }
                    stack.push(((t - r.addr) / 4) as usize);
                }
                if !next {
                    break;
                }
                // conditional branches: the register fields do not matter for x30 unless cbz/tbz tests x30
                if w & 0x7e00_0000 == 0x3400_0000 || w & 0x7e00_0000 == 0x3600_0000 {
                    if w & 31 == 30 {
                        return false;
                    }
                }
                at += 1;
                continue;
            }
            if !next {
                // ret, br, brk, udf, hlt
                let trap = w & 0xffe0_001f == 0xd420_0000 || w & 0xffe0_001f == 0xd440_0000 || w & 0xffff_0000 == 0;
                if trap {
                    break;
                }
                return false;
            }
            if w & 31 == 30 || (w >> 5) & 31 == 30 || (w >> 10) & 31 == 30 || (w >> 16) & 31 == 30 {
                return false;
            }
            at += 1;
        }
    }
    true
}

/// Apple-only straight-line words (AMX and friends, 0x00200000-0x00203fff) do not stop the walk: LLVM has no decoder for them.
pub(crate) fn stops_walk(w: u32, invalid: &WordSet) -> bool {
    invalid.has(w) && w & 0xffff_c000 != 0x0020_0000
}

pub(crate) fn prove(r: &Range, starts: &[u64], invalid: &WordSet) -> Vec<bool> {
    let n = r.words.len();
    let mut code = vec![false; n];
    let end = r.addr + (n as u64) * 4;
    let lo = starts.partition_point(|&s| s < r.addr);
    let hi = starts.partition_point(|&s| s < end);
    let inside = &starts[lo..hi];
    if inside.is_empty() {
        if r.stub && r.words.iter().all(|&w| !stops_walk(w, invalid)) {
            code.iter_mut().for_each(|c| *c = true);
        } else if r.stub {
            // A stub island mapping starts with the subcache header. Its stubs have a fixed shape:
            // adrp, (add|ldr), [ldr], br/braa. Only that shape counts as code.
            let is_adrp = |w: u32| w & 0x9f00_0000 == 0x9000_0000;
            let is_mid = |w: u32| w & 0xff80_0000 == 0x9100_0000 || w & 0xffc0_0000 == 0xf940_0000;
            let is_jump = |w: u32| w & 0xffff_fc1f == 0xd61f_0000 || w & 0xffff_f800 == 0xd61f_0800 || w & 0xffff_f800 == 0xd71f_0800;
            for i in 0..n {
                if !is_adrp(r.words[i]) {
                    continue;
                }
                for len in [2usize, 3] {
                    if i + len < n && r.words[i + 1..i + len].iter().all(|&w| is_mid(w)) && is_jump(r.words[i + len]) {
                        code[i..=i + len].iter_mut().for_each(|c| *c = true);
                        break;
                    }
                }
            }
        }
        return code;
    }
    let mut stack = Vec::new();
    for (i, &s) in inside.iter().enumerate() {
        let a = ((s - r.addr) / 4) as usize;
        let b = inside.get(i + 1).map(|&e| ((e - r.addr) / 4) as usize).unwrap_or(n);
        if a >= n || s % 4 != 0 {
            continue;
        }
        if r.words[a..b.min(n)].iter().all(|&w| !stops_walk(w, invalid)) {
            code[a..b.min(n)].iter_mut().for_each(|c| *c = true);
            continue;
        }
        stack.push(a);
        while let Some(mut at) = stack.pop() {
            while at < n && !code[at] {
                let w = r.words[at];
                if stops_walk(w, invalid) {
                    break;
                }
                code[at] = true;
                let (next, target) = a64::flow(w, r.addr + at as u64 * 4);
                if let Some(t) = target {
                    if t >= r.addr && t < end {
                        stack.push(((t - r.addr) / 4) as usize);
                    }
                }
                if !next {
                    break;
                }
                at += 1;
            }
        }
        // Grade 2: a run the walk did not reach (a jump-table target, a dead epilogue), bounded by reached code or the
        // function bounds, with every word decodable. A run next to an undecodable word stays unproven.
        let stop = b.min(n);
        let mut i = a;
        while i < stop {
            if code[i] || stops_walk(r.words[i], invalid) {
                i += 1;
                continue;
            }
            let mut j = i;
            while j < stop && !code[j] && !stops_walk(r.words[j], invalid) {
                j += 1;
            }
            // Both ends touch proven code or the function bounds; a run right after an undecodable word may be more data.
            let after_code = i == a || code[i - 1];
            if after_code && (j == stop || code[j]) {
                code[i..j].iter_mut().for_each(|c| *c = true);
            }
            i = j;
        }
    }
    code
}

fn sysreg_allowed(text: &str) -> bool {
    // EL0 use that works on ARMv8.0 with the XNU SCTLR/CNTKCTL settings
    let t = text.to_ascii_uppercase();
    let m = t.split_whitespace().next().unwrap_or("");
    match m {
        "DMB" | "ISB" | "CLREX" => true,
        "DSB" => !t.contains("NXS"),
        "DC" => ["ZVA", "CVAC", "CIVAC", "CVAU"].iter().any(|x| t.contains(x)) && !t.contains("CVAP") && !t.contains("CVADP"),
        "IC" => t.contains("IVAU"),
        "MRS" | "MSR" => [
            "TPIDR_EL0", "TPIDRRO_EL0", "NZCV", "FPCR", "FPSR", "CTR_EL0", "DCZID_EL0", "CNTFRQ_EL0", "CNTVCT_EL0",
            "CNTPCT_EL0", "MIDR_EL1", "MPIDR_EL1",
        ]
        .iter()
        .any(|x| t.split(|c: char| c == ' ' || c == ',').any(|tok| tok == *x)),
        _ => false,
    }
}

fn mnemonic_of(text: &str) -> String {
    text.split_whitespace().next().unwrap_or("?").to_string()
}

/// Code ranges of every image of a cache and of the stub islands (executable mappings with no instruction section).
pub(crate) fn cache_units(cache: &Cache) -> Result<Vec<Unit<'_>>> {
    let mut units = Vec::new();
    let mut covered: Vec<(u64, u64)> = Vec::new();
    for (address, path) in &cache.images {
        let Ok(head) = cache.read(*address, 32) else { continue };
        let sizeofcmds = dsc::u32_at(head, 20)? as usize;
        let head = cache.read(*address, 32 + sizeofcmds)?;
        let macho = Macho::parse(head).with_context(|| format!("image {path}"))?;
        let mut ranges = Vec::new();
        let mut file = None;
        for s in macho.instruction_sections() {
            let Ok(bytes) = cache.read(s.addr, s.size as usize) else { continue };
            let Some(words) = word_bytes(bytes) else { continue };
            file = cache.locate(s.addr).map(|l| l.0);
            covered.push((s.addr, s.addr + s.size));
            ranges.push(Range { addr: s.addr, words, stub: s.flags & 0xff == 8 || s.name.contains("stubs"), section: s.name.clone() });
        }
        let want_syms = HOT.iter().any(|h| path == h);
        units.push(Unit {
            name: path.clone(),
            root: false,
            file,
            ranges,
            starts: dsc::image_function_starts(cache, &macho),
            symbols: if want_syms { dsc::image_symbols(cache, &macho) } else { Vec::new() },
        });
    }
    covered.sort();
    let mut merged: Vec<(u64, u64)> = Vec::new();
    for (a, b) in covered {
        match merged.last_mut() {
            Some(l) if a <= l.1 => l.1 = l.1.max(b),
            _ => merged.push((a, b)),
        }
    }
    for (start, size, file, fileoff) in cache.executable_regions() {
        let end = start + size;
        let lo = merged.partition_point(|m| m.1 <= start);
        // A mapping with instruction sections: the other __TEXT bytes are data sections and padding, not code.
        if merged.get(lo).is_some_and(|m| m.0 < end) {
            continue;
        }
        let off = fileoff as usize;
        if let Some(words) = cache.files[file].data().get(off..off + (size as usize & !3)).and_then(word_bytes) {
            let ranges = vec![Range { addr: start, words, stub: true, section: "<no section>".into() }];
            units.push(Unit {
                name: format!("<stub island>{}", cache.files[file].suffix),
                root: false,
                file: Some(file),
                ranges,
                starts: Vec::new(),
                symbols: Vec::new(),
            });
        }
    }
    Ok(units)
}

/// Code ranges of one thin Mach-O slice.
pub(crate) fn macho_unit<'a>(name: String, slice: &'a [u8], macho: &Macho) -> Unit<'a> {
    let mut ranges = Vec::new();
    for s in macho.instruction_sections() {
        let (a, b) = (s.fileoff as usize, s.fileoff as usize + s.size as usize);
        let Some(words) = slice.get(a..b).and_then(word_bytes) else { continue };
        ranges.push(Range { addr: s.addr, words, stub: s.flags & 0xff == 8 || s.name.contains("stubs"), section: s.name.clone() });
    }
    let starts = match (macho.function_starts, macho.segment("__LINKEDIT")) {
        (Some((o, l)), Some(_)) if l != 0 => slice
            .get(o as usize..o as usize + l as usize)
            .map(|b| dsc::decode_function_starts(b, macho.text_base()))
            .unwrap_or_default(),
        _ => Vec::new(),
    };
    Unit { name, root: true, file: None, ranges, starts, symbols: Vec::new() }
}

/// Words no decoder knows: they stop the code walk. Needs llvm-mc.
pub(crate) fn undecodable_words(units: &[Unit], tmp: &Path) -> Result<WordSet> {
    fs::create_dir_all(tmp)?;
    let seen = WordSet::new();
    units.par_iter().for_each(|u| {
        for r in &u.ranges {
            for &w in r.words {
                seen.insert(w);
            }
        }
    });
    let unique = seen.to_vec();
    drop(seen);
    let base = llvm_all(&unique, BASE, tmp, false)?;
    let newer: Vec<u32> = unique.iter().copied().zip(base).filter(|(_, d)| d.is_none()).map(|(w, _)| w).collect();
    let full_args = [format!("-mattr={FULL_ATTR}")];
    let full_ref: Vec<&str> = full_args.iter().map(|s| s.as_str()).collect();
    let full = llvm_all(&newer, &full_ref, tmp, false)?;
    let invalid = WordSet::new();
    for (w, d) in newer.iter().copied().zip(full) {
        if d.is_none() {
            invalid.insert(w);
        }
    }
    Ok(invalid)
}

pub fn run(cache_path: Option<&Path>, roots: &[PathBuf], outdir: &Path, sample: usize, all_slices: bool) -> Result<()> {
    fs::create_dir_all(outdir)?;
    let tmp = outdir.join("tmp");
    fs::create_dir_all(&tmp)?;
    let started = std::time::Instant::now();
    let cache = match cache_path {
        Some(p) => Some(Cache::open(p)?),
        None => None,
    };
    let mut units: Vec<Unit> = Vec::new();
    if let Some(cache) = &cache {
        units = cache_units(cache)?;
    }
    if let (Some(cache), Some(main)) = (&cache, cache_path) {
        let want: Vec<u64> = cache.images.iter().filter(|(_, p)| HOT.iter().any(|h| p == h)).map(|(a, _)| *a).collect();
        let names: HashMap<&str, u64> = cache.images.iter().map(|(a, p)| (p.as_str(), *a)).collect();
        match dsc::cache_local_symbols(main, cache, &want) {
            Ok(mut local) => {
                for u in units.iter_mut() {
                    if let Some(extra) = names.get(u.name.as_str()).and_then(|a| local.remove(a)) {
                        u.symbols.retain(|e| e.1 != "<redacted>");
                        u.symbols.extend(extra);
                        u.symbols.sort();
                    }
                }
            }
            Err(e) => eprintln!("no local symbols: {e}"),
        }
    }
    let cache_units = units.len();
    // Root Mach-O files
    let mut paths = Vec::new();
    for r in roots {
        walk(r, &mut paths)?;
    }
    paths.sort();
    if sample != 0 && paths.len() > sample {
        let step = paths.len() as f64 / sample as f64;
        paths = (0..sample).map(|i| paths[(i as f64 * step) as usize].clone()).collect();
    }
    let mut root_maps: Vec<(String, Map)> = Vec::new();
    for p in &paths {
        if let Ok(m) = Map::open(p) {
            root_maps.push((p.display().to_string(), m));
        }
    }
    let mut root_slices_skipped = 0u64;
    for (name, map) in &root_maps {
        let d = map.bytes();
        for (off, len) in dsc::macho_slices(d) {
            let slice = &d[off..off + len];
            let Ok(macho) = Macho::parse(slice) else { root_slices_skipped += 1; continue };
            if !all_slices && macho.cpusubtype & 0xff != 2 {
                root_slices_skipped += 1; // a plain arm64 slice is ARMv8.0 clean by target and runs without rewrite
                continue;
            }
            let short = name.rsplit("/root/").next().unwrap_or(name).to_string();
            units.push(macho_unit(short, slice, &macho));
        }
    }
    eprintln!("{} cache units, {} root arm64e slices ({} files, {} other slices skipped)", cache_units, units.len() - cache_units, root_maps.len(), root_slices_skipped);

    // Unique words
    let seen = WordSet::new();
    units.par_iter().for_each(|u| {
        for r in &u.ranges {
            for &w in r.words {
                seen.insert(w);
            }
        }
    });
    let unique = seen.to_vec();
    drop(seen);
    eprintln!("[{:?}] {} unique words", started.elapsed(), unique.len());

    // Base decode (Cortex-A73)
    let base = llvm_all(&unique, BASE, &tmp, false)?;
    let mut newer: Vec<u32> = Vec::new();
    let mut system: Vec<u32> = Vec::new();
    for (i, d) in base.iter().enumerate() {
        let w = unique[i];
        if d.is_none() {
            newer.push(w);
        } else if w & 0xffc0_0000 == 0xd500_0000 && a64::hint_imm(w).is_none() {
            system.push(w);
        }
    }
    drop(base);
    eprintln!("[{:?}] base decode: {} words invalid on Cortex-A73, {} system-space words", started.elapsed(), newer.len(), system.len());

    // Decode the rest with all features, then one feature at a time.
    let full_args = [format!("-mattr={FULL_ATTR}")];
    let full_ref: Vec<&str> = full_args.iter().map(|s| s.as_str()).collect();
    let full = llvm_all(&newer, &full_ref, &tmp, true)?;
    let invalid = WordSet::new();
    let mut decoded: Vec<(u32, Box<str>)> = Vec::new();
    for (w, d) in newer.iter().copied().zip(full) {
        match d {
            Some(t) => decoded.push((w, t)),
            None => invalid.insert(w),
        }
    }
    eprintln!("[{:?}] full decode: {} decoded, {} undecodable", started.elapsed(), decoded.len(), newer.len() - decoded.len());
    let mut feature_of: HashMap<u32, &'static str> = HashMap::new();
    let mut pending: Vec<u32> = decoded.iter().map(|d| d.0).collect();
    let args_of = |f: &str| vec![BASE[0].to_string(), format!("-mattr=+{f}")];
    for f in FEATURES {
        if pending.is_empty() {
            break;
        }
        let a = args_of(f);
        let r: Vec<&str> = a.iter().map(|s| s.as_str()).collect();
        let d = llvm_all(&pending, &r, &tmp, false)?;
        let mut left = Vec::new();
        for (w, v) in pending.iter().copied().zip(d) {
            if v.is_some() {
                feature_of.insert(w, f);
            } else {
                left.push(w);
            }
        }
        pending = left;
    }
    eprintln!("[{:?}] feature resolve: {} words have a named feature, {} only with the full set", started.elapsed(), feature_of.len(), pending.len());

    // System space with the full decoder: names for the EL0 check.
    let sysnames = llvm_all(&system, &full_ref, &tmp, true)?;
    // What a real A13 can run: LLVM's apple-a13.
    let a13_args: [&str; 1] = ["-mcpu=apple-a13"];
    let dwords: Vec<u32> = decoded.iter().map(|d| d.0).collect();
    let a13_new = llvm_all(&dwords, &a13_args, &tmp, true)?;
    let a13_sys = llvm_all(&system, &a13_args, &tmp, true)?;
    let mut a13_of: HashMap<u32, bool> = dwords
        .iter()
        .copied()
        .zip(a13_new.iter().map(|d| d.is_some()))
        .chain(system.iter().copied().zip(sysnames.iter().zip(a13_sys.iter()).map(|(f, a)| f.is_some() && f == a)))
        .collect();

    // LLVM prints the SME aliases for any CPU; A13 has no SME.
    for (w, d) in system.iter().zip(&sysnames) {
        if d.as_deref().is_some_and(|t| t.starts_with("smstart") || t.starts_with("smstop")) {
            a13_of.insert(*w, false);
        }
    }
    // Class table
    let mut classes: Vec<Class> = Vec::new();
    let mut class_ids: HashMap<(String, String, String, bool), u16> = HashMap::new();
    let mut class_of = |group: &str, feature: &str, mnemonic: &str, a13: bool| -> u16 {
        let key = (group.to_string(), feature.to_string(), mnemonic.to_string(), a13);
        *class_ids.entry(key).or_insert_with(|| {
            classes.push(Class { group: group.into(), feature: feature.into(), mnemonic: mnemonic.into(), a13 });
            (classes.len() - 1) as u16
        })
    };
    let mut word_class: HashMap<u32, u16> = HashMap::new();
    let mut check = String::new();
    let (mut lse_llvm, mut lse_hand_agree, mut pac_llvm, mut pac_hand_agree) = (0u64, 0u64, 0u64, 0u64);
    let mut word_text: HashMap<u32, String> = HashMap::new();
    for (w, text) in &decoded {
        let w = *w;
        let feature = feature_of.get(&w).copied().unwrap_or("other");
        let mn = mnemonic_of(text);
        let group = match feature {
            "lse" => {
                lse_llvm += 1;
                if a64::lse_decode(w).is_some() {
                    lse_hand_agree += 1;
                } else {
                    let _ = writeln!(check, "lse: llvm says {text} ({w:#010x}), hand decoder says no");
                }
                "lse"
            }
            "pauth" => {
                pac_llvm += 1;
                if a64::pac_lower(w).is_some() {
                    pac_hand_agree += 1;
                } else {
                    let _ = writeln!(check, "pauth: llvm says {text} ({w:#010x}), hand decoder says no");
                }
                "pac-nonhint"
            }
            "rcpc" => "rcpc-ldapr",
            "rcpc-immo" => "rcpc-imm",
            "fullfp16" => "fp16",
            f => f,
        };
        let id = class_of(group, feature, &mn, a13_of.get(&w).copied().unwrap_or(false));
        word_class.insert(w, id);
        word_text.insert(w, text.to_string());
    }
    // Reverse check of the hand decoders: a word they claim must be in the LLVM class.
    for &w in &newer {
        if a64::lse_decode(w).is_some() && feature_of.get(&w) != Some(&"lse") {
            let _ = writeln!(check, "lse: hand decoder claims {w:#010x}, llvm feature {:?}", feature_of.get(&w));
        }
        if a64::pac_lower(w).is_some() && feature_of.get(&w) != Some(&"pauth") {
            let _ = writeln!(check, "pauth: hand decoder claims {w:#010x}, llvm feature {:?}", feature_of.get(&w));
        }
    }
    // Hints: words of the hint space a newer architecture gives a meaning; NOP here.
    for &w in &unique {
        if let Some(imm) = a64::hint_imm(w) {
            if let Some((name, group)) = a64::newer_hint(imm) {
                let id = class_of(group, "hint", name, true);
                word_class.insert(w, id);
            }
        }
    }
    // System space not allowed at EL0 on v8.0
    let mut sysreg_lines = String::from("word\ttext\tallowed\n");
    for (w, d) in system.iter().copied().zip(sysnames) {
        let text = d.as_deref().unwrap_or("?").to_string();
        let allowed = sysreg_allowed(&text);
        let _ = writeln!(sysreg_lines, "{w:#010x}\t{text}\t{allowed}");
        if !allowed {
            let m = mnemonic_of(&text);
            let id = class_of("system", &m, &text, a13_of.get(&w).copied().unwrap_or(false));
            word_class.insert(w, id);
            word_text.insert(w, text);
        }
    }
    drop(class_of);
    fs::write(outdir.join("sysreg.tsv"), sysreg_lines)?;
    let flagged = WordSet::new();
    for &w in word_class.keys() {
        flagged.insert(w);
    }
    eprintln!("[{:?}] {} classes over {} flagged words; hand-decoder check: lse {}/{}, pauth {}/{}, disagreements {} lines",
        started.elapsed(), classes.len(), word_class.len(), lse_hand_agree, lse_llvm, pac_hand_agree, pac_llvm, check.lines().count());
    fs::write(outdir.join("decoder-check.txt"), &check)?;

    // Count
    let counts: Vec<UnitCount> = units
        .par_iter()
        .map(|u| {
            let mut c = UnitCount::default();
            let hot = HOT.iter().any(|h| u.name == *h);
            for r in &u.ranges {
                let code = prove(r, &u.starts, &invalid);
                for (i, &w) in r.words.iter().enumerate() {
                    c.words += 1;
                    if code[i] {
                        c.proven_words += 1;
                    }
                    if invalid.has(w) {
                        c.undecodable += 1;
                        *c.undecodable_prefix.entry((w >> 16) as u16).or_default() += 1;
                    }
                    if w & 0xffff_c000 == 0x0020_0000 {
                        *c.apple.entry(w).or_default() += 1;
                        if w & 0xffff_fc00 == 0x0020_1000 {
                            c.amx += 1;
                            if i > 0 && i + 1 < r.words.len() && !invalid.has(r.words[i - 1]) && !invalid.has(r.words[i + 1]) {
                                c.amx_proven += 1;
                            }
                        }
                    }
                    if flagged.has(w) {
                        let id = word_class[&w];
                        *c.linear.entry(id).or_default() += 1;
                        if code[i] {
                            *c.proven.entry(id).or_default() += 1;
                        }
                        if hot && code[i] && a64::lse_decode(w).is_none() {
                            let k = &classes[id as usize];
                            if k.a13 && matches!(k.group.as_str(), "fp16" | "fp16fml" | "complxnum" | "dotprod" | "jsconv" | "sha3" | "rcpc-imm") {
                                c.hot_sites.push((r.addr + i as u64 * 4, w, 1));
                            }
                        }
                        if a64::lse_decode(w).is_some() {
                            let e = c.lse_words.entry(w).or_default();
                            e.0 += 1;
                            if code[i] {
                                e.1 += 1;
                            }
                            if hot {
                                c.hot_sites.push((r.addr + i as u64 * 4, w, 0));
                            }
                            if code[i] {
                                if (w >> 5) & 31 == 31 {
                                    c.lse_sp_base += 1;
                                }
                                if lr_dead_after(r, &code, i) {
                                    c.lse_lr_dead += 1;
                                }
                            }
                        }
                    }
                }
                let _ = &r.section;
            }
            c
        })
        .collect();
    eprintln!("[{:?}] counted", started.elapsed());

    write_reports(outdir, cache.as_ref(), &units, &counts, &classes, &word_class, &word_text, cache_units, root_maps.len(), unique.len(), newer.len(), decoded.len())?;
    let _ = fs::remove_dir_all(&tmp);
    eprintln!("[{:?}] done: {}", started.elapsed(), outdir.display());
    Ok(())
}

/// Free r-x bytes per cache file: zero runs of 32 bytes or more in executable mappings that no section of any image owns,
/// and that are not Mach-O headers (nonzero). The trampolines can go there: any slot in a file reaches every site in it.
fn write_slack(outdir: &Path, cache: &Cache, units: &[Unit], counts: &[UnitCount], cache_units: usize) -> Result<()> {
    let mut sections: Vec<(u64, u64)> = Vec::new();
    for (address, _) in &cache.images {
        let Ok(head) = cache.read(*address, 32) else { continue };
        let Ok(size) = dsc::u32_at(head, 20) else { continue };
        let Ok(head) = cache.read(*address, 32 + size as usize) else { continue };
        let Ok(m) = Macho::parse(head) else { continue };
        // the load commands themselves stay
        sections.push((*address, *address + 32 + size as u64));
        for s in &m.sections {
            sections.push((s.addr, s.addr + s.size));
        }
    }
    sections.sort();
    let mut per: BTreeMap<usize, (u64, u64, u64, u64)> = BTreeMap::new();
    for (start, size, file, fileoff) in cache.executable_regions() {
        let d = cache.files[file].data();
        let Some(bytes) = d.get(fileoff as usize..(fileoff + size) as usize) else { continue };
        let end = start + size;
        let mut at = start;
        let mut count_gap = |a: u64, b: u64| {
            // 4-byte aligned zero runs in [a, b)
            let a = (a + 3) & !3;
            let mut i = a;
            let e = per.entry(file).or_default();
            while i + 4 <= b {
                let off = (i - start) as usize;
                if bytes[off..off + 4] == [0; 4] {
                    let mut j = i;
                    while j + 4 <= b && bytes[(j - start) as usize..(j - start) as usize + 4] == [0; 4] {
                        j += 4;
                    }
                    let run = j - i;
                    if run >= 32 {
                        e.0 += run;
                        e.1 += 1;
                        e.2 = e.2.max(run);
                        if run >= 64 {
                            e.3 += run & !15;
                        }
                    }
                    i = j;
                } else {
                    i += 4;
                }
            }
        };
        let lo = sections.partition_point(|m| m.1 <= start);
        for m in &sections[lo..] {
            if m.0 >= end {
                break;
            }
            if m.0 > at {
                count_gap(at, m.0);
            }
            at = at.max(m.1);
        }
        if end > at {
            count_gap(at, end);
        }
    }
    let mut lse: BTreeMap<usize, (u64, u64, u64, HashMap<u32, u64>)> = BTreeMap::new();
    for (u, c) in units.iter().zip(counts).take(cache_units) {
        if let Some(f) = u.file {
            let e = lse.entry(f).or_default();
            for (w, (n, p)) in &c.lse_words {
                e.0 += n;
                e.1 += p;
                *e.3.entry(*w).or_default() += n;
            }
            e.2 += c.lse_lr_dead;
        }
    }
    let mut s = String::from("file\tslack_bytes\tslack_slots\tlargest_slot\tusable_ge64\tlse_sites\tlse_proven\tlr_dead\tunique_words\tneed_bytes_60_16\n");
    let (mut tn, mut ts) = (0u64, 0u64);
    for (f, cf) in cache.files.iter().enumerate() {
        let (a, b, c, u) = per.get(&f).copied().unwrap_or_default();
        let empty = Default::default();
        let l = lse.get(&f).unwrap_or(&empty);
        let need = l.3.len() as u64 * 60 + l.0.saturating_sub(l.2) * 16;
        tn += need;
        ts += u;
        let _ = writeln!(s, "{}\t{a}\t{b}\t{c}\t{u}\t{}\t{}\t{}\t{}\t{need}", if cf.suffix.is_empty() { "main" } else { &cf.suffix }, l.0, l.1, l.2, l.3.len());
    }
    let _ = writeln!(s, "total\t\t\t\t{ts}\t\t\t\t\t{tn}");
    fs::write(outdir.join("slack.tsv"), s)?;
    Ok(())
}

pub(crate) fn walk(dir: &Path, out: &mut Vec<PathBuf>) -> Result<()> {
    for e in fs::read_dir(dir).with_context(|| format!("read {}", dir.display()))? {
        let e = e?;
        let t = e.file_type()?;
        if t.is_dir() {
            walk(&e.path(), out)?;
        } else if t.is_file() {
            out.push(e.path());
        }
    }
    Ok(())
}

fn op_key(op: LseOp) -> &'static str {
    op.name()
}

#[allow(clippy::too_many_arguments)]
fn write_reports(
    outdir: &Path,
    cache: Option<&Cache>,
    units: &[Unit],
    counts: &[UnitCount],
    classes: &[Class],
    word_class: &HashMap<u32, u16>,
    word_text: &HashMap<u32, String>,
    cache_units: usize,
    root_files: usize,
    unique: usize,
    newer: usize,
    decoded: usize,
) -> Result<()> {
    #[derive(Default, Clone)]
    struct Tot {
        linear_cache: u64,
        proven_cache: u64,
        linear_root: u64,
        proven_root: u64,
        images: u64,
    }
    let mut tot: Vec<Tot> = vec![Tot::default(); classes.len()];
    let (mut wc, mut pc, mut uc, mut wr, mut pr, mut ur) = (0u64, 0u64, 0u64, 0u64, 0u64, 0u64);
    for (i, c) in counts.iter().enumerate() {
        let root = i >= cache_units;
        if root {
            wr += c.words;
            pr += c.proven_words;
            ur += c.undecodable;
        } else {
            wc += c.words;
            pc += c.proven_words;
            uc += c.undecodable;
        }
        for (id, n) in &c.linear {
            let t = &mut tot[*id as usize];
            if root {
                t.linear_root += n
            } else {
                t.linear_cache += n
            }
            t.images += 1;
        }
        for (id, n) in &c.proven {
            let t = &mut tot[*id as usize];
            if root {
                t.proven_root += n
            } else {
                t.proven_cache += n
            }
        }
    }
    // Unique words per class
    let mut uniq = vec![0u64; classes.len()];
    for id in word_class.values() {
        uniq[*id as usize] += 1;
    }
    // classes.tsv
    let mut s = String::from("group\tfeature\tmnemonic\ta13\tcache_linear\tcache_proven\troot_linear\troot_proven\tunique_words\tunits\n");
    let mut order: Vec<usize> = (0..classes.len()).collect();
    order.sort_by_key(|&i| (classes[i].group.clone(), std::cmp::Reverse(tot[i].linear_cache)));
    for &i in &order {
        let (c, t) = (&classes[i], &tot[i]);
        let _ = writeln!(s, "{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}", c.group, c.feature, c.mnemonic, c.a13, t.linear_cache, t.proven_cache, t.linear_root, t.proven_root, uniq[i], t.images);
    }
    fs::write(outdir.join("classes.tsv"), &s)?;
    // images.tsv: every unit with a nonzero non-hint count, per group
    let mut groups: Vec<String> = classes.iter().map(|c| c.group.clone()).collect();
    groups.sort();
    groups.dedup();
    let gi: HashMap<&str, usize> = groups.iter().enumerate().map(|(i, g)| (g.as_str(), i)).collect();
    let mut s = format!("unit\twords\tproven\tundecodable\tamx\t{}\n", groups.join("\t"));
    let mut per_group = vec![(0u64, 0u64, 0u64, 0u64, 0u64); groups.len()];
    let mut a13_group = vec![(0u64, 0u64, 0u64); groups.len()];
    for (i, c) in counts.iter().enumerate() {
        for (id, n) in &c.proven {
            let k = &classes[*id as usize];
            if k.a13 {
                if i < cache_units {
                    a13_group[gi[k.group.as_str()]].0 += n;
                } else {
                    a13_group[gi[k.group.as_str()]].1 += n;
                }
            }
        }
        for (id, n) in &c.linear {
            let k = &classes[*id as usize];
            if k.a13 && i < cache_units {
                a13_group[gi[k.group.as_str()]].2 += n;
            }
        }
    }
    let mut hot_rows: BTreeMap<String, Vec<u64>> = BTreeMap::new();
    for (i, (u, c)) in units.iter().zip(counts).enumerate() {
        let mut row = vec![0u64; groups.len()];
        let mut row_proven = vec![0u64; groups.len()];
        for (id, n) in &c.linear {
            row[gi[classes[*id as usize].group.as_str()]] += n;
        }
        for (id, n) in &c.proven {
            row_proven[gi[classes[*id as usize].group.as_str()]] += n;
        }
        for (g, n) in row.iter().enumerate() {
            let e = &mut per_group[g];
            if i < cache_units {
                e.0 += n;
                e.1 += row_proven[g];
                if *n != 0 {
                    e.4 += 1
                }
            } else {
                e.2 += n;
                e.3 += row_proven[g];
            }
        }
        let cols: Vec<String> = row.iter().map(|n| n.to_string()).collect();
        let _ = writeln!(s, "{}\t{}\t{}\t{}\t{}\t{}", u.name, c.words, c.proven_words, c.undecodable, c.amx, cols.join("\t"));
        if HOT.iter().any(|h| u.name == *h) {
            hot_rows.insert(u.name.clone(), row);
        }
    }
    fs::write(outdir.join("images.tsv"), &s)?;
    // LSE forms
    let mut forms: BTreeMap<(LseOp, u32, bool, bool), (u64, u64, u64, u64)> = BTreeMap::new();
    let mut lse_by_size = [0u64; 5];
    for (i, c) in counts.iter().enumerate() {
        for (w, (n, p)) in &c.lse_words {
            let l = a64::lse_decode(*w).unwrap();
            let e = forms.entry((l.op, l.size, l.acquire, l.release)).or_default();
            if i < cache_units {
                e.0 += n;
                e.1 += p;
                lse_by_size[if l.op == LseOp::Casp { 4 } else { l.size as usize }] += n;
            } else {
                e.2 += n;
                e.3 += p;
            }
        }
    }
    let mut s = String::from("op\tsize\tacquire\trelease\tcache_linear\tcache_proven\troot_linear\troot_proven\n");
    for ((op, size, a, r), (l, p, rl, rp)) in &forms {
        let _ = writeln!(s, "{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}", op_key(*op), size, a, r, l, p, rl, rp);
    }
    fs::write(outdir.join("lse-forms.tsv"), &s)?;
    // Apple-only opcode space
    let mut apple: BTreeMap<u32, (u64, u64)> = BTreeMap::new();
    let mut apple_images: BTreeMap<u32, Vec<(u64, String)>> = BTreeMap::new();
    for (i, c) in counts.iter().enumerate() {
        for (w, n) in &c.apple {
            let e = apple.entry(*w).or_default();
            if i < cache_units {
                e.0 += n
            } else {
                e.1 += n
            }
            apple_images.entry(*w).or_default().push((*n, units[i].name.clone()));
        }
    }
    let mut s = String::from("word\tcache\troot\ttop_units\n");
    for (w, (n, r)) in &apple {
        let mut im = apple_images.remove(w).unwrap_or_default();
        im.sort_by_key(|e| std::cmp::Reverse(e.0));
        im.truncate(4);
        let list: Vec<String> = im.iter().map(|(n, p)| format!("{n} {p}")).collect();
        let _ = writeln!(s, "{w:#010x}\t{n}\t{r}\t{}", list.join("; "));
    }
    fs::write(outdir.join("apple-opcodes.tsv"), &s)?;
    // Root binaries: LSE sites and LR-dead sites
    let mut s = String::from("unit\tlse_sites\tlse_lr_dead\tlse_sp_base\tunique\n");
    for (u, c) in units.iter().zip(counts).skip(cache_units) {
        let n: u64 = c.lse_words.values().map(|v| v.0).sum();
        if n != 0 {
            let _ = writeln!(s, "{}\t{n}\t{}\t{}\t{}", u.name, c.lse_lr_dead, c.lse_sp_base, c.lse_words.len());
        }
    }
    fs::write(outdir.join("root-lse.tsv"), s)?;
    let (dead, sp): (u64, u64) = counts.iter().take(cache_units).fold((0, 0), |a, c| (a.0 + c.lse_lr_dead, a.1 + c.lse_sp_base));
    let (rdead, rsp): (u64, u64) = counts.iter().skip(cache_units).fold((0, 0), |a, c| (a.0 + c.lse_lr_dead, a.1 + c.lse_sp_base));
    let liveness = format!("- LSE proven sites where x30 is dead (bl to a shared trampoline is enough): cache {dead}, root {rdead}; with SP as base: cache {sp}, root {rsp}\n");
    // Undecodable prefix histogram
    let mut prefix: HashMap<u16, u64> = HashMap::new();
    for c in counts {
        for (p, n) in &c.undecodable_prefix {
            *prefix.entry(*p).or_default() += n;
        }
    }
    let mut pv: Vec<_> = prefix.into_iter().collect();
    pv.sort_by_key(|e| std::cmp::Reverse(e.1));
    let mut s = String::from("top16\tcount\n");
    for (p, n) in pv.iter().take(200) {
        let _ = writeln!(s, "{p:#06x}\t{n}");
    }
    fs::write(outdir.join("undecodable.tsv"), &s)?;

    // Hot sites with function names
    for (u, c) in units.iter().zip(counts) {
        if c.hot_sites.is_empty() {
            continue;
        }
        let mut lines = String::from("address\tword\ttext\tfunction\tkind\n");
        let mut per_fn: BTreeMap<String, u64> = BTreeMap::new();
        let mut per_fn_other: BTreeMap<String, u64> = BTreeMap::new();
        for (addr, w, kind) in &c.hot_sites {
            let fi = u.starts.partition_point(|&s| s <= *addr);
            let f = if fi > 0 { u.starts[fi - 1] } else { 0 };
            let name = match u.symbols.binary_search_by_key(&f, |e| e.0) {
                Ok(i) => u.symbols[i].1.clone(),
                Err(_) => format!("sub_{f:x}"),
            };
            let _ = writeln!(lines, "{addr:#x}\t{w:#010x}\t{}\t{name}\t{}", word_text.get(w).map(|s| s.as_str()).unwrap_or(""), if *kind == 0 { "lse" } else { "other" });
            if *kind == 0 {
                *per_fn.entry(name).or_default() += 1;
            } else {
                *per_fn_other.entry(name).or_default() += 1;
            }
        }
        let safe = u.name.rsplit('/').next().unwrap_or("x").replace(['+', ' '], "_");
        fs::write(outdir.join(format!("hot-{safe}.tsv")), lines)?;
        let mut v: Vec<_> = per_fn.into_iter().collect();
        v.sort_by_key(|e| std::cmp::Reverse(e.1));
        let mut lines = String::from("sites\tfunction\n");
        for (n, c) in v {
            let _ = writeln!(lines, "{c}\t{n}");
        }
        fs::write(outdir.join(format!("hotfn-{safe}.tsv")), lines)?;
        let mut v: Vec<_> = per_fn_other.into_iter().collect();
        v.sort_by_key(|e| std::cmp::Reverse(e.1));
        let mut lines = String::from("sites\tfunction\n");
        for (n, c) in v {
            let _ = writeln!(lines, "{c}\t{n}");
        }
        fs::write(outdir.join(format!("hotfn-other-{safe}.tsv")), lines)?;
    }

    // Layout and slide info
    let mut md_layout = String::new();
    if let Some(cache) = cache {
        write_slack(outdir, cache, units, counts, cache_units)?;
        let mut per_file: Vec<(u64, u64, HashMap<u32, u64>)> = vec![(0, 0, HashMap::new()); cache.files.len()];
        for (u, c) in units.iter().zip(counts).take(cache_units) {
            if let Some(f) = u.file {
                for (w, (n, _)) in &c.lse_words {
                    per_file[f].0 += n;
                    *per_file[f].2.entry(*w).or_default() += n;
                }
                per_file[f].1 += c.words * 4;
            }
        }
        let regions = cache.all_regions();
        let mut s = String::from("start\tend\tsize\tfile\tmaxprot\tgap_to_next\ttrailing_zero_bytes\tlse_sites_in_file\tlse_unique_in_file\n");
        for (i, (start, size, file, fileoff, maxprot)) in regions.iter().enumerate() {
            let end = start + size;
            let gap = regions.get(i + 1).map(|r| r.0.saturating_sub(end)).unwrap_or(0);
            let mut trailing = 0u64;
            if maxprot & dsc::VM_PROT_EXECUTE != 0 {
                let d = cache.files[*file].data();
                let a = *fileoff as usize;
                if let Some(b) = d.get(a..a + *size as usize) {
                    trailing = b.iter().rev().take_while(|&&x| x == 0).count() as u64;
                }
            }
            let f = &per_file[*file];
            let _ = writeln!(s, "{start:#x}\t{end:#x}\t{size}\t{}\t{maxprot}\t{gap}\t{trailing}\t{}\t{}", if cache.files[*file].suffix.is_empty() { "main" } else { &cache.files[*file].suffix }, f.0, f.2.len());
        }
        fs::write(outdir.join("layout.tsv"), s)?;
        let exec: u64 = cache.executable_regions().iter().map(|r| r.1).sum();
        let _ = writeln!(md_layout, "- shared region start {:#x}, size {:#x}, max slide {:#x}; files {}; images {}; executable mapping bytes {}", cache.shared_region_start, cache.shared_region_size, cache.max_slide, cache.files.len(), cache.images.len(), exec);
        // Slide info
        let mut total = dsc::SlideCounts::default();
        let mut s = String::from("file\tmapping\tflags\tpages\tpages_with_rebases\tplain\tplain_high8\tauth\tauth_ia\tauth_da\tauth_addr_div\tauth_zero_div\tpage_size\n");
        let results: Vec<String> = cache
            .files
            .par_iter()
            .flat_map_iter(|f| f.slid.iter().map(move |m| (f, m)))
            .filter(|(_, m)| m.slide_size != 0)
            // Older caches have other slide versions: not counted here.
            .filter(|(f, m)| dsc::u32_at(f.data(), m.slide_offset as usize).ok() == Some(5))
            .map(|(f, m)| {
                let c = dsc::walk_slide_v5(f, m, |_, _| {})?;
                let ps = dsc::u32_at(f.data(), m.slide_offset as usize + 4)?;
                Ok(format!("{}\t{:#x}\t{:#x}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}", if f.suffix.is_empty() { "main" } else { &f.suffix }, m.address, m.flags, c.pages, c.pages_with_rebases, c.plain, c.plain_high8, c.auth, c.auth_ia, c.auth_da, c.auth_addr_div, c.auth_zero_div, ps))
            })
            .collect::<Result<Vec<_>>>()?;
        for r in &results {
            let v: Vec<u64> = r.split('\t').skip(3).map(|x| x.parse().unwrap_or(0)).collect();
            total.pages += v[0];
            total.pages_with_rebases += v[1];
            total.plain += v[2];
            total.plain_high8 += v[3];
            total.auth += v[4];
            total.auth_ia += v[5];
            total.auth_da += v[6];
            total.auth_addr_div += v[7];
            total.auth_zero_div += v[8];
            let _ = writeln!(s, "{r}");
        }
        fs::write(outdir.join("slide.tsv"), s)?;
        let _ = writeln!(md_layout, "- slide info v5: {} mappings; pages {} ({} with rebases); plain rebases {} ({} with high8); **auth rebases {}** (IA {}, DA {}; addrDiv {}, zero diversity {})", results.len(), total.pages, total.pages_with_rebases, total.plain, total.plain_high8, total.auth, total.auth_ia, total.auth_da, total.auth_addr_div, total.auth_zero_div);
    }

    // census.md
    let mut md = String::new();
    let _ = writeln!(md, "# a64-census\n");
    let _ = writeln!(md, "Decoder: `llvm-mc` (`llvm-mc --version` of this host), base `{}`.\n", BASE[0]);
    let _ = writeln!(md, "- cache units {cache_units}; root Mach-O files {root_files}; root arm64e slices {}", units.len() - cache_units);
    let _ = writeln!(md, "- cache: words {wc} ({} MiB), proven {pc} ({:.2} %), undecodable {uc}", wc * 4 >> 20, pc as f64 * 100.0 / wc.max(1) as f64);
    let _ = writeln!(md, "- root: words {wr} ({} MiB), proven {pr} ({:.2} %), undecodable {ur}", wr * 4 >> 20, pr as f64 * 100.0 / wr.max(1) as f64);
    let _ = writeln!(md, "- unique words {unique}; invalid on Cortex-A73 {newer}; of those, decoded with all features {decoded}");
    md.push_str(&md_layout);
    md.push_str(&liveness);
    let _ = writeln!(md, "\n## Groups\n\n| group | cache linear | cache proven | cache proven, A13 can run | cache units | root linear | root proven | root proven, A13 can run |\n|---|---:|---:|---:|---:|---:|---:|---:|");
    for (g, name) in groups.iter().enumerate() {
        let e = per_group[g];
        let a = a13_group[g];
        let _ = writeln!(md, "| {name} | {} | {} | {} | {} | {} | {} | {} |", e.0, e.1, a.0, e.4, e.2, e.3, a.1);
    }
    let (amxc, amxr, amxpc): (u64, u64, u64) = counts.iter().enumerate().fold((0, 0, 0), |a, (i, c)| {
        if i < cache_units { (a.0 + c.amx, a.1, a.2 + c.amx_proven) } else { (a.0, a.1 + c.amx, a.2) }
    });
    let _ = writeln!(md, "| AMX word shape `(insn & 0xfffffc00) == 0x00201000` (undecodable in LLVM; 'proven' = both neighbour words decode) | {amxc} | {amxpc} | {amxpc} | | {amxr} | | |");
    let _ = writeln!(md, "\n## LSE in the cache by size (linear)\n\n| byte | half | word | double | CASP |\n|---:|---:|---:|---:|---:|\n| {} | {} | {} | {} | {} |", lse_by_size[0], lse_by_size[1], lse_by_size[2], lse_by_size[3], lse_by_size[4]);
    let _ = writeln!(md, "\n## Named images (linear counts by group)\n");
    let hdr: Vec<&str> = groups.iter().map(|g| g.as_str()).collect();
    let _ = writeln!(md, "| image | {} |", hdr.join(" | "));
    let _ = writeln!(md, "|---|{}", "---:|".repeat(groups.len()));
    for (name, row) in &hot_rows {
        let cols: Vec<String> = row.iter().map(|n| n.to_string()).collect();
        let _ = writeln!(md, "| {} | {} |", name.rsplit('/').next().unwrap_or(name), cols.join(" | "));
    }
    let _ = writeln!(md, "\nDetails: classes.tsv (per mnemonic), slack.tsv (free r-x bytes and trampoline need per file), root-lse.tsv, lse-forms.tsv, images.tsv (per image), layout.tsv, slide.tsv, apple-opcodes.tsv, sysreg.tsv, undecodable.tsv, hot-*.tsv.");
    fs::write(outdir.join("census.md"), &md)?;
    print!("{md}");
    Ok(())
}
