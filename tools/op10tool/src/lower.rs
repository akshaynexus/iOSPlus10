//! `op10tool a64-lower`: write a lowered copy of a dyld shared cache or Mach-O files for an ARMv8.0 CPU with no PAC, LSE,
//! RCpc (Mi A3). Never in place; deterministic; a word changes only when the code proof covers it and its old value matches.
//! `op10tool a64-verify`: independent check of the result.
//!
//! Rules:
//!   pac     non-hint PAC -> plain form, one word (rules of UniXNU-zeta scripts/zeta_userland_pauth.py)
//!   rcpc    LDAPR -> LDAR; LDAPUR/STLUR with offset 0 -> LDAR/STLR, one word
//!   sysreg  msr/mrs DIT -> NOP / movz 0; SB -> ISB, one word
//!   lse     LSE word -> `bl` to a shared trampoline where x30 is dead, else `b` to a per-site stub that saves x30.
//!           Trampolines go in r-x bytes that no section owns (zero runs) or in --dead-image __text. See a64.rs.
//!   slide   slide info v5 auth rebases -> plain rebases in the pointer words; the kernel then slides them with no PAC code
//! Also: corecrypto FIPS HMACs resealed (same contract as zeta rewrite-zeta-dyld-cache.py), code signatures rehashed.
//! Hint-space PAC stays: NOP on the CPU. Everything else above ARMv8.0 stays and is listed for kernel emulation.

use crate::a64::{self, enc, Rules};
use crate::census::{self, Range, Unit, WordSet};
use crate::dsc::{self, Cache, Macho, Map};
use anyhow::{anyhow, bail, Context, Result};
use hmac::{Hmac, Mac};
use rayon::prelude::*;
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashMap};
use std::fmt::Write as _;
use std::fs::{self, File, OpenOptions};
use std::io::{Seek, SeekFrom, Write as _};
use std::os::fd::AsRawFd;
use std::path::{Path, PathBuf};

const REACH: u64 = 127 << 20; // B and BL reach 128 MiB; keep 1 MiB of margin
const ZONE: u64 = 16 << 20;
const STUB_BYTES: u64 = 16;
const CSMAGIC_EMBEDDED: u32 = 0xfade_0cc0;
const CSMAGIC_CD: u32 = 0xfade_0c02;
const SIGNATURE_ALIGN: usize = 0x4000;
const HEADER_SIGNATURE_SIZE: usize = 0x30;
const FIPS_KEY: [u8; 32] = [0; 32];

#[derive(Clone, Copy)]
struct Edit {
    addr: u64,
    old: u32,
    new: u32,
}

#[derive(Clone, Copy)]
struct LseSite {
    addr: u64,
    word: u32,
    lr_dead: bool,
}

#[derive(Default)]
struct UnitPlan {
    edits: Vec<Edit>,
    sites: Vec<LseSite>,
    counts: BTreeMap<String, u64>,
}

fn plan_unit(u: &Unit, invalid: &WordSet, rules: &Rules) -> UnitPlan {
    let mut p = UnitPlan::default();
    for r in &u.ranges {
        let code = census::prove(r, &u.starts, invalid);
        scan_range(r, &code, rules, &mut p);
    }
    p
}

fn scan_range(r: &Range, code: &[bool], rules: &Rules, p: &mut UnitPlan) {
    for (i, &w) in r.words.iter().enumerate() {
        let addr = r.addr + i as u64 * 4;
        if let Some(o) = a64::one_word(w, rules) {
            match o {
                Ok((name, new)) => {
                    if code[i] {
                        p.edits.push(Edit { addr, old: w, new });
                        *p.counts.entry(format!("one-word {name}")).or_default() += 1;
                    } else {
                        *p.counts.entry(format!("left, not proven code: {name}")).or_default() += 1;
                    }
                }
                Err(why) => {
                    if code[i] {
                        *p.counts.entry(format!("left for the kernel: {why}")).or_default() += 1;
                    }
                }
            }
            continue;
        }
        if rules.lse {
            if let Some(l) = a64::lse_decode(w) {
                if !code[i] {
                    *p.counts.entry("left, not proven code: lse".into()).or_default() += 1;
                    continue;
                }
                if let Some(why) = a64::lse_refuses(&l) {
                    *p.counts.entry(format!("left for the kernel: lse {why}")).or_default() += 1;
                    continue;
                }
                p.sites.push(LseSite { addr, word: w, lr_dead: census::lr_dead_after(r, code, i) });
            }
        }
    }
}

/// Free slots: (address, length). Sorted by address, 16-byte aligned, at least 64 bytes.
fn zero_slots(bytes: &[u8], base: u64, taken: &[(u64, u64)], out: &mut Vec<(u64, u64)>) {
    let end = base + bytes.len() as u64;
    let lo = taken.partition_point(|m| m.1 <= base);
    let mut at = base;
    let mut gap = |a: u64, b: u64, out: &mut Vec<(u64, u64)>| {
        let mut i = (a + 15) & !15;
        while i + 16 <= b {
            let off = (i - base) as usize;
            if bytes[off..off + 16].iter().all(|&x| x == 0) {
                let mut j = i + 16;
                while j + 16 <= b && bytes[(j - base) as usize..(j - base) as usize + 16].iter().all(|&x| x == 0) {
                    j += 16;
                }
                if j - i >= 64 {
                    out.push((i, j - i));
                }
                i = j;
            } else {
                i += 16;
            }
        }
    };
    for m in &taken[lo..] {
        if m.0 >= end {
            break;
        }
        if m.0 > at {
            gap(at, m.0, out);
        }
        at = at.max(m.1);
    }
    if end > at {
        gap(at, end, out);
    }
}

struct Allocator {
    slots: Vec<(u64, u64)>,
    used: Vec<u64>,
    bytes: u64,
}
impl Allocator {
    fn new(mut slots: Vec<(u64, u64)>) -> Allocator {
        slots.sort();
        let used = vec![0; slots.len()];
        Allocator { slots, used, bytes: 0 }
    }
    /// Lowest free address in [lo, hi) with room for `size` bytes.
    fn alloc(&mut self, lo: u64, hi: u64, size: u64) -> Option<u64> {
        let first = self.slots.partition_point(|s| s.0 + s.1 <= lo);
        for i in first..self.slots.len() {
            let (start, len) = self.slots[i];
            if start >= hi {
                return None;
            }
            let at = (start + self.used[i]).max(lo);
            if at >= start + len || at + size > start + len || at + size > hi {
                continue;
            }
            self.used[i] = at + size - start;
            self.bytes += size;
            return Some(at);
        }
        None
    }
}

#[derive(Default)]
struct LsePlan {
    edits: Vec<Edit>,
    /// (address, word) of new code in free space
    code: Vec<(u64, u32)>,
    bl_sites: u64,
    stub_sites: u64,
    trampolines: u64,
    left_no_space: u64,
    left_sites: Vec<u64>,
    words: Vec<u32>,
    tramp_bytes: u64,
    stub_bytes: u64,
}

/// Place trampolines and stubs. Zones of 16 MiB: every slot in the window reaches every site in the zone.
fn plan_lse(mut sites: Vec<LseSite>, slots: Vec<(u64, u64)>) -> LsePlan {
    sites.sort_by_key(|s| s.addr);
    let mut alloc = Allocator::new(slots);
    let mut lp = LsePlan::default();
    let mut placed: HashMap<u32, Vec<u64>> = HashMap::new();
    let mut seen_words: Vec<u32> = sites.iter().map(|s| s.word).collect();
    seen_words.sort();
    seen_words.dedup();
    lp.words = seen_words;
    let mut i = 0;
    while i < sites.len() {
        let zone_start = sites[i].addr & !(ZONE - 1);
        let zone_end = zone_start + ZONE;
        let (lo, hi) = (zone_end.saturating_sub(REACH), zone_start + REACH);
        let mut j = i;
        while j < sites.len() && sites[j].addr < zone_end {
            let s = sites[j];
            j += 1;
            let site_edit = |target: u64, link: bool| -> u32 {
                let d = ((target as i64 - s.addr as i64) / 4) as i32;
                if link {
                    enc::bl_words(d)
                } else {
                    enc::b_words(d)
                }
            };
            // A trampoline already placed for this word that the whole zone reaches, else a new one.
            let tramp = |lp: &mut LsePlan, alloc: &mut Allocator, placed: &mut HashMap<u32, Vec<u64>>, near: Option<u64>| -> Option<u64> {
                let list = placed.entry(s.word).or_default();
                if let Some(&t) = list.iter().rev().find(|&&t| t >= lo && t < hi && near.is_none_or(|n| t.abs_diff(n) < REACH)) {
                    return Some(t);
                }
                let l = a64::lse_decode(s.word).unwrap();
                let body = a64::lse_trampoline(&l);
                let size = body.len() as u64 * 4;
                let (a, b) = match near {
                    Some(n) => (lo.max(n.saturating_sub(REACH)), hi.min(n + REACH)),
                    None => (lo, hi),
                };
                let t = alloc.alloc(a, b, size)?;
                for (k, w) in body.iter().enumerate() {
                    lp.code.push((t + k as u64 * 4, *w));
                }
                lp.trampolines += 1;
                lp.tramp_bytes += size;
                list.push(t);
                Some(t)
            };
            if s.lr_dead {
                match tramp(&mut lp, &mut alloc, &mut placed, None) {
                    Some(t) => {
                        lp.edits.push(Edit { addr: s.addr, old: s.word, new: site_edit(t, true) });
                        lp.bl_sites += 1;
                    }
                    None => {
                        lp.left_no_space += 1;
                        lp.left_sites.push(s.addr);
                    }
                }
            } else {
                let Some(stub) = alloc.alloc(lo, hi, STUB_BYTES) else {
                    lp.left_no_space += 1;
                    lp.left_sites.push(s.addr);
                    continue;
                };
                let Some(t) = tramp(&mut lp, &mut alloc, &mut placed, Some(stub)) else {
                    lp.left_no_space += 1;
                    lp.left_sites.push(s.addr);
                    continue;
                };
                let words = a64::lse_stub(((t as i64 - (stub as i64 + 4)) / 4) as i32, ((s.addr as i64 + 4 - (stub as i64 + 12)) / 4) as i32);
                for (k, w) in words.iter().enumerate() {
                    lp.code.push((stub + k as u64 * 4, *w));
                }
                lp.edits.push(Edit { addr: s.addr, old: s.word, new: site_edit(stub, false) });
                lp.stub_sites += 1;
                lp.stub_bytes += STUB_BYTES;
            }
        }
        i = j;
    }
    lp
}

/// Read-write file mapping of an output file.
struct RwMap {
    ptr: *mut u8,
    len: usize,
}
unsafe impl Send for RwMap {}
unsafe impl Sync for RwMap {}
impl RwMap {
    fn open(path: &Path) -> Result<RwMap> {
        let f = OpenOptions::new().read(true).write(true).open(path)?;
        let len = f.metadata()?.len() as usize;
        // SAFETY: shared writable mapping of a file this process just made and only it uses; bounds checked by slices.
        let ptr = unsafe {
            libc::mmap(std::ptr::null_mut(), len, libc::PROT_READ | libc::PROT_WRITE, libc::MAP_SHARED, f.as_raw_fd(), 0)
        };
        if ptr == libc::MAP_FAILED {
            bail!("mmap {}", path.display());
        }
        Ok(RwMap { ptr: ptr as *mut u8, len })
    }
    fn bytes(&mut self) -> &mut [u8] {
        // SAFETY: the mapping made in open(), exclusive by &mut self.
        unsafe { std::slice::from_raw_parts_mut(self.ptr, self.len) }
    }
}
impl Drop for RwMap {
    fn drop(&mut self) {
        // SAFETY: the mapping of open().
        unsafe {
            libc::msync(self.ptr as *mut libc::c_void, self.len, libc::MS_SYNC);
            libc::munmap(self.ptr as *mut libc::c_void, self.len);
        }
    }
}

fn hex(b: &[u8]) -> String {
    b.iter().fold(String::new(), |mut s, x| {
        let _ = write!(s, "{x:02x}");
        s
    })
}

fn be32(b: &[u8], at: usize) -> Result<u32> {
    let s = b.get(at..at + 4).ok_or_else(|| anyhow!("signature read at {at:#x} out of range"))?;
    Ok(u32::from_be_bytes(s.try_into().unwrap()))
}

/// (offset, length) of each CodeDirectory blob of an embedded signature at `sig`.
fn code_directories(d: &[u8], sig: usize) -> Result<Vec<(usize, usize)>> {
    if be32(d, sig)? != CSMAGIC_EMBEDDED {
        bail!("no embedded signature at {sig:#x}");
    }
    let count = be32(d, sig + 8)? as usize;
    let mut out = Vec::new();
    for slot in 0..count {
        let at = be32(d, sig + 12 + 8 * slot + 4)? as usize;
        if be32(d, sig + at)? == CSMAGIC_CD {
            out.push((sig + at, be32(d, sig + at + 4)? as usize));
        }
    }
    if out.is_empty() {
        bail!("no CodeDirectory");
    }
    Ok(out)
}

fn hash_page(hash_type: u8, page: &[u8]) -> Vec<u8> {
    match hash_type {
        1 => sha1_smol::Sha1::from(page).digest().bytes().to_vec(),
        _ => Sha256::digest(page).to_vec(),
    }
}

/// Recompute every code slot of every CodeDirectory. `base` = start of the thin slice in `d`. Returns the cdhash (SHA-256 CD).
fn rehash_in_place(d: &mut [u8], base: usize, sig: usize) -> Result<String> {
    let dirs = code_directories(&d[base..], sig)?;
    let mut cdhash = String::new();
    for (cd, length) in dirs {
        let cd = base + cd;
        let hash_offset = be32(d, cd + 16)? as usize;
        let slots = be32(d, cd + 28)? as usize;
        let limit = be32(d, cd + 32)? as usize;
        let (hash_size, hash_type, page_shift) = (d[cd + 36] as usize, d[cd + 37], d[cd + 39]);
        if page_shift == 0 || hash_type == 0 || hash_type > 4 {
            bail!("CodeDirectory with page shift {page_shift}, hash type {hash_type}");
        }
        let page = 1usize << page_shift;
        let code = &d[base..base + limit];
        let hashes: Vec<Vec<u8>> = (0..slots)
            .into_par_iter()
            .map(|i| {
                let a = i * page;
                let b = ((i + 1) * page).min(limit);
                let mut h = hash_page(hash_type, &code[a.min(limit)..b]);
                h.truncate(hash_size);
                h
            })
            .collect();
        for (i, h) in hashes.iter().enumerate() {
            let at = cd + hash_offset + hash_size * i;
            d[at..at + hash_size].copy_from_slice(h);
        }
        let digest = hash_page(hash_type, &d[cd..cd + length]);
        if hash_type == 2 || cdhash.is_empty() {
            cdhash = hex(&digest[..20]);
        }
    }
    Ok(cdhash)
}

/// New embedded signature with `page_shift` pages, CodeDirectory header, identifier and special slots kept. Same shape as
/// zeta rewrite-zeta-dyld-cache.py rebuilt_signature. Returns (blob, cdhash).
fn rebuilt_signature(code: &[u8], sig: &[u8], page_shift: u32) -> Result<(Vec<u8>, String)> {
    if be32(sig, 0)? != CSMAGIC_EMBEDDED {
        bail!("no embedded signature");
    }
    let count = be32(sig, 8)? as usize;
    let mut blobs: Vec<(u32, Vec<u8>)> = Vec::new();
    let mut cdhash = None;
    for slot in 0..count {
        let kind = be32(sig, 12 + 8 * slot)?;
        let at = be32(sig, 16 + 8 * slot)? as usize;
        let magic = be32(sig, at)?;
        let len = be32(sig, at + 4)? as usize;
        let blob = sig.get(at..at + len).ok_or_else(|| anyhow!("blob out of range"))?;
        if magic == CSMAGIC_CD {
            if cdhash.is_some() {
                bail!("two CodeDirectories in a cache file");
            }
            let hash_offset = be32(blob, 16)? as usize;
            let limit = be32(blob, 32)? as usize;
            if (blob[36], blob[37]) != (32, 2) || limit != code.len() {
                bail!("CodeDirectory is not SHA-256 over the whole file");
            }
            let page = 1usize << page_shift;
            let slots = limit.div_ceil(page);
            let mut header = blob[..hash_offset].to_vec();
            header[4..8].copy_from_slice(&((hash_offset + 32 * slots) as u32).to_be_bytes());
            header[28..32].copy_from_slice(&(slots as u32).to_be_bytes());
            header[39] = page_shift as u8;
            let hashes: Vec<[u8; 32]> = (0..slots)
                .into_par_iter()
                .map(|i| Sha256::digest(&code[i * page..((i + 1) * page).min(limit)]).into())
                .collect();
            let mut out = header;
            for h in hashes {
                out.extend_from_slice(&h);
            }
            cdhash = Some(hex(&Sha256::digest(&out)[..20]));
            blobs.push((kind, out));
        } else {
            blobs.push((kind, blob.to_vec()));
        }
    }
    let mut offset = 12 + 8 * count;
    let mut index = Vec::new();
    for (kind, blob) in &blobs {
        index.extend_from_slice(&kind.to_be_bytes());
        index.extend_from_slice(&(offset as u32).to_be_bytes());
        offset += blob.len();
    }
    let mut out = Vec::with_capacity(offset);
    out.extend_from_slice(&CSMAGIC_EMBEDDED.to_be_bytes());
    out.extend_from_slice(&(offset as u32).to_be_bytes());
    out.extend_from_slice(&(count as u32).to_be_bytes());
    out.extend_from_slice(&index);
    for (_, blob) in &blobs {
        out.extend_from_slice(blob);
    }
    Ok((out, cdhash.ok_or_else(|| anyhow!("no CodeDirectory"))?))
}

/// Length rebuilt_signature will give, before the header it hashes is final.
fn rebuilt_length(sig: &[u8], page_shift: u32, limit: usize) -> Result<usize> {
    let count = be32(sig, 8)? as usize;
    let mut total = 12 + 8 * count;
    for slot in 0..count {
        let at = be32(sig, 16 + 8 * slot)? as usize;
        let mut len = be32(sig, at + 4)? as usize;
        if be32(sig, at)? == CSMAGIC_CD {
            len = be32(sig, at + 16)? as usize + 32 * limit.div_ceil(1usize << page_shift);
        }
        total += len;
    }
    Ok(total)
}

fn hmac_sha256(data: &[u8]) -> [u8; 32] {
    let mut m = <Hmac<Sha256> as Mac>::new_from_slice(&FIPS_KEY).unwrap();
    m.update(data);
    m.finalize().into_bytes().into()
}

/// corecrypto FIPS POST HMAC fields, only where the original field proves the contract on the original code:
/// (file index, field offset, text offset, text size).
fn fips_seals(cache: &Cache) -> Result<Vec<(usize, usize, usize, usize, String)>> {
    let mut out = Vec::new();
    for (address, path) in &cache.images {
        let head = cache.read(*address, 32)?;
        let head = cache.read(*address, 32 + dsc::u32_at(head, 20)? as usize)?;
        let m = Macho::parse(head)?;
        let Some(field) = m.sections.iter().find(|s| s.name == "__fips_hmacs") else { continue };
        if field.size != 32 {
            continue;
        }
        let Some(text) = m.sections.iter().find(|s| s.name == "__text" && (s.segment == "__TEXT" || s.segment == "__TEXT_EXEC")) else { continue };
        if text.fileoff as u64 != text.addr - *address {
            continue;
        }
        let (Some((tf, to, room)), Some((ff, fo, _))) = (cache.locate(text.addr), cache.locate(field.addr)) else { continue };
        if room < text.size || tf != ff {
            continue;
        }
        let d = cache.files[tf].data();
        let code = &d[to..to + text.size as usize];
        if hmac_sha256(code)[..] != d[fo..fo + 32] {
            continue;
        }
        out.push((tf, fo, to, text.size as usize, path.clone()));
    }
    Ok(out)
}

#[derive(Default)]
struct Totals {
    counts: BTreeMap<String, u64>,
}
impl Totals {
    fn add(&mut self, m: &BTreeMap<String, u64>) {
        for (k, v) in m {
            *self.counts.entry(k.clone()).or_default() += v;
        }
    }
}

fn lse_summary(s: &mut String, lp: &LsePlan, slot_total: u64) {
    let _ = writeln!(s, "| LSE sites: bl to a shared trampoline | {} |", lp.bl_sites);
    let _ = writeln!(s, "| LSE sites: b to a stub that saves x30 | {} |", lp.stub_sites);
    let _ = writeln!(s, "| LSE sites: no free space in reach (left for the kernel) | {} |", lp.left_no_space);
    let _ = writeln!(s, "| trampolines placed / unique LSE words | {} / {} |", lp.trampolines, lp.words.len());
    let _ = writeln!(s, "| bytes used: trampolines + stubs | {} + {} |", lp.tramp_bytes, lp.stub_bytes);
    let _ = writeln!(s, "| free r-x bytes offered (zero runs of 64 bytes or more outside sections, plus dead images) | {slot_total} |");
}

pub fn run(cache_path: Option<&Path>, machos: &[PathBuf], outdir: &Path, rules: &str, page_shift: u32, dead: &[String], plan_only: bool) -> Result<()> {
    let rules = Rules::parse(rules).map_err(|e| anyhow!(e))?;
    if !plan_only {
        if outdir.exists() && fs::read_dir(outdir)?.next().is_some() {
            bail!("{} exists and is not empty: the tool never writes over old output", outdir.display());
        }
        fs::create_dir_all(outdir)?;
    } else {
        fs::create_dir_all(outdir)?;
    }
    let tmp = outdir.join("tmp");
    let mut report = String::from("# a64-lower report\n\n");
    let _ = writeln!(report, "Rules: {rules:?}. Page shift: {page_shift} (0 = keep). Dead images: {dead:?}.\n");
    if let Some(c) = cache_path {
        lower_cache(c, outdir, &tmp, &rules, page_shift, dead, plan_only, &mut report)?;
    }
    if !machos.is_empty() {
        lower_machos(machos, outdir, &tmp, &rules, plan_only, &mut report)?;
    }
    let _ = fs::remove_dir_all(&tmp);
    fs::write(outdir.join("lower-report.md"), &report)?;
    print!("{report}");
    Ok(())
}

#[allow(clippy::too_many_arguments)]
/// A dead image can still be a dependent of a daemon: dyld then maps it and runs its load-time code. Trampolines in its __text
/// turn that code into a stray `add sp, sp, #176` (docs/laurel_sprout/ios26-entry.md). So a dead image must have no such code.
fn dead_image_runs_code(m: &Macho) -> Option<String> {
    m.sections.iter().find_map(|s| match s.flags & 0xff {
        0x09 | 0x15 | 0x16 if s.size != 0 => Some(format!("section {} has {} bytes of initializers", s.name, s.size)),
        _ if (s.name == "__objc_nlclslist" || s.name == "__objc_nlcatlist") && s.size != 0 => Some(format!("section {} has +load code", s.name)),
        _ => None,
    })
}

fn lower_cache(main: &Path, outdir: &Path, tmp: &Path, rules: &Rules, page_shift: u32, dead: &[String], plan_only: bool, report: &mut String) -> Result<()> {
    let started = std::time::Instant::now();
    let cache = Cache::open(main)?;
    let units = census::cache_units(&cache)?;
    eprintln!("[{:?}] {} units", started.elapsed(), units.len());
    let invalid = census::undecodable_words(&units, tmp)?;
    eprintln!("[{:?}] decoded", started.elapsed());
    let is_dead = |u: &Unit| dead.iter().any(|d| u.name.contains(d.as_str()));
    let plans: Vec<UnitPlan> = units.par_iter().filter(|u| !is_dead(u)).map(|u| plan_unit(u, &invalid, rules)).collect();
    let mut totals = Totals::default();
    let mut edits = Vec::new();
    let mut sites = Vec::new();
    for p in plans {
        totals.add(&p.counts);
        edits.extend(p.edits);
        sites.extend(p.sites);
    }
    drop(invalid);
    eprintln!("[{:?}] planned {} one-word edits, {} LSE sites", started.elapsed(), edits.len(), sites.len());

    // Free space
    let mut taken: Vec<(u64, u64)> = Vec::new();
    let mut dead_text: Vec<(u64, u64)> = Vec::new();
    for (address, path) in &cache.images {
        let head = cache.read(*address, 32)?;
        let size = dsc::u32_at(head, 20)? as u64;
        let m = Macho::parse(cache.read(*address, 32 + size as usize)?)?;
        taken.push((*address, *address + 32 + size));
        let d = dead.iter().any(|x| path.contains(x.as_str()));
        if d {
            if let Some(why) = dead_image_runs_code(&m) {
                bail!("--dead-image {path}: {why}: dyld runs it at load, and its __text would hold trampolines (docs/laurel_sprout/ios26-entry.md)");
            }
        }
        for s in &m.sections {
            taken.push((s.addr, s.addr + s.size));
            if d && s.flags & dsc::SECTION_INSTRUCTIONS != 0 && s.size >= 64 && s.name == "__text" {
                dead_text.push((s.addr, s.size));
            }
        }
    }
    // The headers are in the r-x mappings and hold long zero runs. Code written there breaks dyld (docs/laurel_sprout/ios26-dyld.md).
    taken.extend(cache.reserved_ranges()?);
    taken.sort();
    let mut slots = dead_text.clone();
    for (start, size, file, fileoff) in cache.executable_regions() {
        let d = cache.files[file].data();
        if let Some(b) = d.get(fileoff as usize..(fileoff + size) as usize) {
            zero_slots(b, start, &taken, &mut slots);
        }
    }
    let slot_total: u64 = slots.iter().map(|s| s.1).sum();
    let lp = plan_lse(sites, slots);
    if plan_only {
        // Image placement and sites with no space, to choose --dead-image
        let mut t = String::from("address\tfile\ttext_bytes\timage\n");
        for (address, path) in &cache.images {
            let head = cache.read(*address, 32)?;
            let m = Macho::parse(cache.read(*address, 32 + dsc::u32_at(head, 20)? as usize)?)?;
            let text: u64 = m.instruction_sections().filter(|s| s.name == "__text").map(|s| s.size).sum();
            let f = cache.locate(*address).map(|l| cache.files[l.0].suffix.clone()).unwrap_or_default();
            let _ = writeln!(t, "{address:#x}\t{f}\t{text}\t{path}");
        }
        fs::write(outdir.join("images-layout.tsv"), t)?;
        let mut t = String::from("address\n");
        for a in &lp.left_sites {
            let _ = writeln!(t, "{a:#x}");
        }
        fs::write(outdir.join("left-sites.txt"), t)?;
    }
    eprintln!("[{:?}] LSE plan: {} bl, {} stub, {} no space, {} trampolines, {} + {} bytes", started.elapsed(), lp.bl_sites, lp.stub_sites, lp.left_no_space, lp.trampolines, lp.tramp_bytes, lp.stub_bytes);
    let mut s = String::new();
    let _ = writeln!(s, "## Cache `{}`\n\n| What | Count |\n|---|---:|", main.display());
    for (k, v) in &totals.counts {
        let _ = writeln!(s, "| {k} | {v} |");
    }
    lse_summary(&mut s, &lp, slot_total);
    // Slide counts
    let mut auth_entries = 0u64;
    for f in &cache.files {
        for m in f.slid.iter().filter(|m| m.slide_size != 0) {
            auth_entries += dsc::walk_slide_v5(f, m, |_, _| {})?.auth;
        }
    }
    let _ = writeln!(s, "| slide info v5 auth rebases {} | {auth_entries} |", if rules.slide { "rewritten to plain" } else { "left (rule off)" });
    report.push_str(&s);
    let mut wlist = String::new();
    for w in &lp.words {
        let _ = writeln!(wlist, "{w:#010x}");
    }
    fs::write(outdir.join("lse-words.txt"), wlist)?;
    if plan_only {
        return Ok(());
    }

    // Copy, skipping the unmapped .symbols file
    let mut out_paths = Vec::new();
    for f in &cache.files {
        let name = f.path.file_name().ok_or_else(|| anyhow!("no file name"))?;
        let target = outdir.join(name);
        fs::copy(&f.path, &target).with_context(|| format!("copy to {}", target.display()))?;
        out_paths.push(target);
    }
    eprintln!("[{:?}] copied", started.elapsed());
    let mut maps = out_paths.iter().map(|p| RwMap::open(p)).collect::<Result<Vec<_>>>()?;
    let mut changed = vec![false; cache.files.len()];
    // Apply: old value checked first
    let locate = |addr: u64| -> Result<(usize, usize)> {
        let (f, off, _) = cache.locate(addr).ok_or_else(|| anyhow!("{addr:#x} not mapped"))?;
        Ok((f, off))
    };
    for e in edits.iter().chain(lp.edits.iter()) {
        let (f, off) = locate(e.addr)?;
        let d = maps[f].bytes();
        let old = u32::from_le_bytes(d[off..off + 4].try_into().unwrap());
        if old != e.old {
            bail!("{:#x}: expected {:#x}, found {:#x}", e.addr, e.old, old);
        }
        d[off..off + 4].copy_from_slice(&e.new.to_le_bytes());
        changed[f] = true;
    }
    let in_dead = |addr: u64| dead_text.iter().any(|t| addr >= t.0 && addr < t.0 + t.1);
    for (addr, w) in &lp.code {
        let (f, off) = locate(*addr)?;
        let d = maps[f].bytes();
        let old = u32::from_le_bytes(d[off..off + 4].try_into().unwrap());
        if old != 0 && !in_dead(*addr) {
            bail!("trampoline at {addr:#x} lands on nonzero word {old:#x}");
        }
        d[off..off + 4].copy_from_slice(&w.to_le_bytes());
        changed[f] = true;
    }
    eprintln!("[{:?}] code written", started.elapsed());
    // Slide
    if rules.slide {
        for (i, f) in cache.files.iter().enumerate() {
            let mut writes = Vec::new();
            for m in f.slid.iter().filter(|m| m.slide_size != 0) {
                dsc::walk_slide_v5(f, m, |at, e| {
                    if e.auth() {
                        writes.push((at, e.as_plain()));
                    }
                })?;
            }
            if !writes.is_empty() {
                let d = maps[i].bytes();
                for (at, v) in writes {
                    d[at..at + 8].copy_from_slice(&v.to_le_bytes());
                }
                changed[i] = true;
            }
        }
        eprintln!("[{:?}] slide info rewritten", started.elapsed());
    }
    // FIPS seals
    let seals = fips_seals(&cache)?;
    let mut seal_lines = String::new();
    for (f, field, text, size, path) in &seals {
        let d = maps[*f].bytes();
        let mac = hmac_sha256(&d[*text..*text + *size]);
        d[*field..*field + 32].copy_from_slice(&mac);
        changed[*f] = true;
        let _ = writeln!(seal_lines, "| FIPS HMAC resealed | {path} |");
    }
    report.push_str(&seal_lines);
    drop(maps);
    // Sign
    let mut cd = String::from("file\torig_cdhash\tnew_cdhash\tsha256\tsize\n");
    for (i, f) in cache.files.iter().enumerate() {
        let path = &out_paths[i];
        if f.sig_size == 0 {
            continue;
        }
        let orig = code_directories(f.data(), f.sig_offset as usize)?;
        let (ocd, olen) = orig[0];
        let orig_cdhash = hex(&Sha256::digest(&f.data()[ocd..ocd + olen])[..20]);
        let new_cdhash = if page_shift != 0 {
            let sig = f.data()[f.sig_offset as usize..(f.sig_offset + f.sig_size) as usize].to_vec();
            let limit = f.sig_offset as usize;
            let length = rebuilt_length(&sig, page_shift, limit)?;
            let new_size = length.div_ceil(SIGNATURE_ALIGN) * SIGNATURE_ALIGN;
            let mut file = OpenOptions::new().read(true).write(true).open(path)?;
            {
                let mut m = RwMap::open(path)?;
                let d = m.bytes();
                d[HEADER_SIGNATURE_SIZE..HEADER_SIGNATURE_SIZE + 8].copy_from_slice(&(new_size as u64).to_le_bytes());
                let code = &d[..limit];
                let (blob, hash) = rebuilt_signature(code, &sig, page_shift)?;
                if blob.len() != length {
                    bail!("{}: signature length changed", path.display());
                }
                drop(m);
                file.set_len(limit as u64)?;
                file.seek(SeekFrom::Start(limit as u64))?;
                file.write_all(&blob)?;
                file.set_len((limit + new_size) as u64)?;
                hash
            }
        } else if changed[i] {
            let mut m = RwMap::open(path)?;
            rehash_in_place(m.bytes(), 0, f.sig_offset as usize)?
        } else {
            orig_cdhash.clone()
        };
        let map = Map::open(path)?;
        let sha: [u8; 32] = sha256_par(map.bytes());
        let _ = writeln!(cd, "{}\t{orig_cdhash}\t{new_cdhash}\t{}\t{}", path.file_name().unwrap().to_string_lossy(), hex(&sha), map.bytes().len());
    }
    fs::write(outdir.join("cdhashes.tsv"), cd)?;
    eprintln!("[{:?}] signed", started.elapsed());
    Ok(())
}

/// Plain SHA-256 of a file's bytes.
fn sha256_par(d: &[u8]) -> [u8; 32] {
    Sha256::digest(d).into()
}

fn lower_machos(paths: &[PathBuf], outdir: &Path, tmp: &Path, rules: &Rules, plan_only: bool, report: &mut String) -> Result<()> {
    let mut files: Vec<(PathBuf, PathBuf)> = Vec::new(); // (source, relative)
    for p in paths {
        if p.is_dir() {
            let mut list = Vec::new();
            census::walk(p, &mut list)?;
            list.sort();
            for f in list {
                let rel = f.strip_prefix(p)?.to_path_buf();
                files.push((f, rel));
            }
        } else {
            let name = p.file_name().ok_or_else(|| anyhow!("no file name in {}", p.display()))?;
            files.push((p.clone(), PathBuf::from(name)));
        }
    }
    let maps = files.iter().map(|(f, _)| Map::open(f)).collect::<Result<Vec<_>>>()?;
    struct Slice<'a> {
        file: usize,
        off: usize,
        macho: Macho,
        unit: Unit<'a>,
    }
    let mut slices = Vec::new();
    for (i, m) in maps.iter().enumerate() {
        let d = m.bytes();
        let all = dsc::macho_slices(d);
        let plain_too = all.iter().any(|(o, l)| Macho::parse(&d[*o..*o + *l]).is_ok_and(|x| x.cpusubtype & 0xff != 2));
        if plain_too {
            continue; // a fat file with a plain arm64 slice: the kernel takes that slice; the arm64e one stays unused
        }
        for (off, len) in all {
            let s = &d[off..off + len];
            let Ok(macho) = Macho::parse(s) else { continue };
            if macho.cpusubtype & 0xff != 2 {
                continue;
            }
            let unit = census::macho_unit(files[i].1.display().to_string(), s, &macho);
            slices.push(Slice { file: i, off, macho, unit });
        }
    }
    let units: Vec<&Unit> = slices.iter().map(|s| &s.unit).collect();
    let invalid = {
        let owned: Vec<Unit> = units.iter().map(|u| Unit { name: u.name.clone(), root: true, file: None, ranges: u.ranges.clone(), starts: Vec::new(), symbols: Vec::new() }).collect();
        census::undecodable_words(&owned, tmp)?
    };
    // Plan per slice
    struct Done {
        file: usize,
        off: usize,
        edits: Vec<(usize, u32, u32)>,
        code: Vec<(usize, u32)>,
        counts: BTreeMap<String, u64>,
        lp_bl: u64,
        lp_stub: u64,
        lp_left: u64,
        lp_bytes: u64,
        slot_total: u64,
        words: Vec<u32>,
    }
    let done: Vec<Done> = slices
        .par_iter()
        .map(|sl| {
            let d = maps[sl.file].bytes();
            let s = &d[sl.off..];
            let plan = plan_unit(&sl.unit, &invalid, rules);
            let text = sl.macho.segment("__TEXT");
            let mut slots = Vec::new();
            if let Some(t) = text {
                let mut taken: Vec<(u64, u64)> = vec![(t.vmaddr, t.vmaddr + 32 + sl.macho.sizeofcmds as u64)];
                for x in &sl.macho.sections {
                    taken.push((x.addr, x.addr + x.size));
                }
                taken.sort();
                if let Some(b) = s.get(t.fileoff as usize..(t.fileoff + t.filesize) as usize) {
                    zero_slots(b, t.vmaddr, &taken, &mut slots);
                }
            }
            let slot_total: u64 = slots.iter().map(|x| x.1).sum();
            let lp = plan_lse(plan.sites, slots);
            let map_off = |addr: u64| -> Option<usize> {
                sl.macho.segments.iter().find(|g| addr >= g.vmaddr && addr < g.vmaddr + g.vmsize).map(|g| (addr - g.vmaddr + g.fileoff) as usize)
            };
            let edits = plan.edits.iter().chain(lp.edits.iter()).filter_map(|e| Some((map_off(e.addr)?, e.old, e.new))).collect();
            let code = lp.code.iter().filter_map(|(a, w)| Some((map_off(*a)?, *w))).collect();
            Done {
                file: sl.file,
                off: sl.off,
                edits,
                code,
                counts: plan.counts,
                lp_bl: lp.bl_sites,
                lp_stub: lp.stub_sites,
                lp_left: lp.left_no_space,
                lp_bytes: lp.tramp_bytes + lp.stub_bytes,
                slot_total,
                words: lp.words,
            }
        })
        .collect();
    // Totals
    let mut totals = Totals::default();
    let (mut bl, mut stub, mut left, mut bytes, mut slot_bytes) = (0u64, 0u64, 0u64, 0u64, 0u64);
    let mut left_binaries = 0u64;
    let mut table = String::from("file\tone_word_edits\tlse_bl\tlse_stub\tlse_left_no_space\ttramp_bytes\tfree_bytes\n");
    let mut words: Vec<u32> = Vec::new();
    for x in &done {
        totals.add(&x.counts);
        bl += x.lp_bl;
        stub += x.lp_stub;
        left += x.lp_left;
        bytes += x.lp_bytes;
        slot_bytes += x.slot_total;
        if x.lp_left != 0 {
            left_binaries += 1;
        }
        words.extend_from_slice(&x.words);
        let _ = writeln!(table, "{}\t{}\t{}\t{}\t{}\t{}\t{}", files[x.file].1.display(), x.edits.len(), x.lp_bl, x.lp_stub, x.lp_left, x.lp_bytes, x.slot_total);
    }
    fs::write(outdir.join("macho-lowered.tsv"), table)?;
    let mut s = String::new();
    let _ = writeln!(s, "\n## Mach-O files\n\nFiles {}; arm64e slices lowered {}.\n\n| What | Count |\n|---|---:|", files.len(), done.len());
    for (k, v) in &totals.counts {
        let _ = writeln!(s, "| {k} | {v} |");
    }
    let _ = writeln!(s, "| LSE sites: bl / stub | {bl} / {stub} |");
    let _ = writeln!(s, "| LSE sites left, no free space in the file's __TEXT (for the kernel) | {left} in {left_binaries} files |");
    let _ = writeln!(s, "| trampoline + stub bytes / free __TEXT bytes | {bytes} / {slot_bytes} |");
    report.push_str(&s);
    if plan_only {
        return Ok(());
    }
    let root = outdir.join("macho");
    // Copy + apply
    let by_file: BTreeMap<usize, Vec<&Done>> = done.iter().fold(BTreeMap::new(), |mut m, d| {
        m.entry(d.file).or_default().push(d);
        m
    });
    files.par_iter().enumerate().try_for_each(|(i, (src, rel))| -> Result<()> {
        let target = root.join(rel);
        if let Some(p) = target.parent() {
            fs::create_dir_all(p)?;
        }
        fs::copy(src, &target)?;
        let Some(list) = by_file.get(&i) else { return Ok(()) };
        let mut m = RwMap::open(&target)?;
        let d = m.bytes();
        for x in list {
            for (off, old, new) in &x.edits {
                let at = x.off + off;
                let cur = u32::from_le_bytes(d[at..at + 4].try_into().unwrap());
                if cur != *old {
                    bail!("{}: {off:#x}: expected {old:#x}, found {cur:#x}", rel.display());
                }
                d[at..at + 4].copy_from_slice(&new.to_le_bytes());
            }
            for (off, w) in &x.code {
                let at = x.off + off;
                let cur = u32::from_le_bytes(d[at..at + 4].try_into().unwrap());
                if cur != 0 {
                    bail!("{}: trampoline at {off:#x} lands on nonzero word {cur:#x}", rel.display());
                }
                d[at..at + 4].copy_from_slice(&w.to_le_bytes());
            }
            // CPU_SUBTYPE_ARM64_ALL: the header, and the fat entry if this is a fat file
            d[x.off + 8..x.off + 12].copy_from_slice(&0u32.to_le_bytes());
            if x.off != 0 {
                let n = u32::from_be_bytes(d[4..8].try_into().unwrap()) as usize;
                for e in 0..n {
                    let a = 8 + e * 20;
                    if u32::from_be_bytes(d[a + 8..a + 12].try_into().unwrap()) as usize == x.off {
                        d[a + 4..a + 8].copy_from_slice(&0u32.to_be_bytes());
                    }
                }
            }
            let s = &d[x.off..];
            let m = Macho::parse(s)?;
            if let Some((sig, _)) = m.code_signature {
                rehash_in_place(d, x.off, sig as usize)?;
            }
        }
        Ok(())
    })?;
    Ok(())
}

/// a64-verify: read both copies and check every difference. Independent of the planner: it decodes the old word and the new
/// word again, walks branches to trampolines, decodes the new code with llvm-mc for cortex-a73, verifies signatures, and
/// compares each slide chain.
pub fn verify(orig: &Path, lowered: &Path, dead: &[String], macho_orig: Option<&Path>) -> Result<()> {
    let name = orig.file_name().ok_or_else(|| anyhow!("no file name"))?;
    let new_main = if lowered.is_dir() { lowered.join(name) } else { lowered.to_path_buf() };
    let a = Cache::open(orig)?;
    let b = Cache::open(&new_main)?;
    if a.files.len() != b.files.len() {
        bail!("file count {} != {}", a.files.len(), b.files.len());
    }
    let mut problems = String::new();
    let mut counts: BTreeMap<String, u64> = BTreeMap::new();
    let mut new_code: Vec<u32> = Vec::new();
    // Instruction sections
    let mut sect: Vec<(u64, u64)> = Vec::new();
    let mut dead_text: Vec<(u64, u64)> = Vec::new();
    for (address, path) in &a.images {
        let head = a.read(*address, 32)?;
        let m = Macho::parse(a.read(*address, 32 + dsc::u32_at(head, 20)? as usize)?)?;
        let d = dead.iter().any(|x| path.contains(x.as_str()));
        if d {
            if let Some(why) = dead_image_runs_code(&m) {
                let _ = writeln!(problems, "dead image {path}: {why}");
            }
        }
        for s in m.instruction_sections() {
            if d && s.name == "__text" {
                dead_text.push((s.addr, s.addr + s.size));
            } else {
                sect.push((s.addr, s.addr + s.size));
            }
        }
    }
    sect.sort();
    dead_text.sort();
    let rules = Rules::parse("all").map_err(|e| anyhow!(e))?;
    let reserved = a.reserved_ranges()?;
    // A resealed FIPS field must hold the HMAC of the new code.
    let seals = fips_seals(&a)?;
    let seal_fields: Vec<(usize, usize)> = seals.iter().map(|s| (s.0, s.1)).collect();
    for (f, field, text, size, path) in &seals {
        let d = b.files[*f].data();
        if hmac_sha256(&d[*text..*text + *size])[..] != d[*field..*field + 32] {
            let _ = writeln!(problems, "{path}: FIPS HMAC does not match the new code");
        } else {
            *counts.entry("FIPS HMAC matches the new code".into()).or_default() += 1;
        }
    }
    for (start, size, file, fileoff) in a.executable_regions() {
        let ad = a.files[file].data();
        let bd = b.files[file].data();
        let (x, y) = (
            ad.get(fileoff as usize..(fileoff + size) as usize).ok_or_else(|| anyhow!("orig region out of range"))?,
            bd.get(fileoff as usize..(fileoff + size) as usize).ok_or_else(|| anyhow!("new region out of range"))?,
        );
        let xw = census::word_bytes(x).ok_or_else(|| anyhow!("unaligned region"))?;
        let yw = census::word_bytes(y).ok_or_else(|| anyhow!("unaligned region"))?;
        let mut targets: Vec<(u64, u64)> = Vec::new();
        for i in 0..xw.len() {
            if xw[i] == yw[i] {
                continue;
            }
            let addr = start + i as u64 * 4;
            let in_section = {
                let k = sect.partition_point(|s| s.1 <= addr);
                sect.get(k).is_some_and(|s| s.0 <= addr)
            };
            let (old, new) = (xw[i], yw[i]);
            if seal_fields.iter().any(|(f, at)| *f == file && (*at..*at + 32).contains(&(fileoff as usize + i * 4))) {
                *counts.entry("FIPS HMAC field words".into()).or_default() += 1;
                continue;
            }
            // The cache header's codeSignatureSize changes with --page-shift.
            if i * 4 == HEADER_SIGNATURE_SIZE || i * 4 == HEADER_SIGNATURE_SIZE + 4 {
                if fileoff == 0 {
                    *counts.entry("header words: codeSignatureSize".into()).or_default() += 1;
                    continue;
                }
            }
            if reserved.iter().any(|r| r.0 <= addr && addr < r.1) {
                let _ = writeln!(problems, "{addr:#x}: cache header or table changed: {old:#x} -> {new:#x}");
                continue;
            }
            if !in_section {
                let k = dead_text.partition_point(|s| s.1 <= addr);
                let in_dead = dead_text.get(k).is_some_and(|s| s.0 <= addr);
                if old != 0 && !in_dead {
                    // Stub islands have no sections: their stubs get the one-word rules.
                    match a64::one_word(old, &rules) {
                        Some(Ok((n, w))) if w == new => {
                            *counts.entry(format!("one-word {n} (stub island)")).or_default() += 1;
                        }
                        _ => {
                            let _ = writeln!(problems, "{addr:#x}: outside sections, old word {old:#x} is not zero and has no rule");
                        }
                    }
                    continue;
                }
                new_code.push(new);
                *counts.entry("new code words in free space".into()).or_default() += 1;
                continue;
            }
            if let Some(Ok((n, w))) = a64::one_word(old, &rules) {
                if w == new {
                    *counts.entry(format!("one-word {n}")).or_default() += 1;
                } else {
                    let _ = writeln!(problems, "{addr:#x}: {old:#x} -> {new:#x}, expected {w:#x}");
                }
                continue;
            }
            if let Some(l) = a64::lse_decode(old) {
                let is_b = new & 0xfc00_0000 == 0x1400_0000;
                let is_bl = new & 0xfc00_0000 == 0x9400_0000;
                let imm = (((new & 0x3ff_ffff) as i64) << 38) >> 38;
                let t = (addr as i64 + imm * 4) as u64;
                if is_b || is_bl {
                    if a64::lse_refuses(&l).is_some() {
                        let _ = writeln!(problems, "{addr:#x}: refused form was rewritten");
                    }
                    targets.push((addr, t));
                    *counts.entry(if is_bl { "lse -> bl".to_string() } else { "lse -> b".to_string() }).or_default() += 1;
                } else {
                    let _ = writeln!(problems, "{addr:#x}: lse {old:#x} -> {new:#x} is no branch");
                }
                continue;
            }
            let _ = writeln!(problems, "{addr:#x}: {old:#x} -> {new:#x}: change with no rule");
        }
        // Branch targets: each lands on a stub or a trampoline head in the new copy
        for (site, t) in &targets {
            let Ok(w) = b.read(*t, 4) else {
                let _ = writeln!(problems, "{site:#x}: target {t:#x} not mapped");
                continue;
            };
            let w = u32::from_le_bytes(w.try_into().unwrap());
            if w != 0xf817_0ffe && w != enc::sub_sp(a64::TRAMP_FRAME) {
                let _ = writeln!(problems, "{site:#x}: target {t:#x} word {w:#x} is no stub or trampoline head");
            }
        }
    }
    // New code on the phone's CPU
    new_code.sort();
    new_code.dedup();
    let tmp = lowered.join("tmp-verify");
    fs::create_dir_all(&tmp)?;
    let d = census::llvm_all(&new_code, census::BASE, &tmp, false)?;
    let bad = new_code.iter().zip(&d).filter(|(_, v)| v.is_none()).count();
    let _ = fs::remove_dir_all(&tmp);
    let _ = writeln!(problems, "{}", if bad == 0 { "" } else { "new code has words cortex-a73 cannot decode" });
    counts.insert("new code: unique words / invalid on cortex-a73".into(), new_code.len() as u64);
    counts.insert("new code: invalid on cortex-a73".into(), bad as u64);
    // Slide chains
    let (mut same, mut auth_left) = (0u64, 0u64);
    for (fa, fb) in a.files.iter().zip(&b.files) {
        for (m, n) in fa.slid.iter().zip(&fb.slid).filter(|(m, _)| m.slide_size != 0) {
            let mut orig_entries = Vec::new();
            dsc::walk_slide_v5(fa, m, |at, e| orig_entries.push((at, e)))?;
            let mut k = 0usize;
            dsc::walk_slide_v5(fb, n, |at, e| {
                if let Some((oa, oe)) = orig_entries.get(k) {
                    if *oa != at || oe.runtime_offset() != e.runtime_offset() || oe.next() != e.next() {
                        let _ = writeln!(problems, "slide chain differs at {at:#x}");
                    } else {
                        same += 1;
                    }
                }
                if e.auth() {
                    auth_left += 1;
                }
                k += 1;
            })?;
            if k != orig_entries.len() {
                let _ = writeln!(problems, "slide chain length differs: {k} != {}", orig_entries.len());
            }
        }
    }
    counts.insert("slide entries with same target and chain".into(), same);
    counts.insert("slide auth entries left".into(), auth_left);
    // Signatures
    let mut sig_bad = 0u64;
    let mut sig_ok = 0u64;
    for f in &b.files {
        if f.sig_size == 0 {
            continue;
        }
        let d = f.data();
        for (cd, _) in code_directories(d, f.sig_offset as usize)? {
            let hash_offset = be32(d, cd + 16)? as usize;
            let slots = be32(d, cd + 28)? as usize;
            let limit = be32(d, cd + 32)? as usize;
            let (hs, ht, ps) = (d[cd + 36] as usize, d[cd + 37], d[cd + 39]);
            let page = 1usize << ps;
            let bad: u64 = (0..slots)
                .into_par_iter()
                .map(|i| {
                    let mut h = hash_page(ht, &d[(i * page).min(limit)..((i + 1) * page).min(limit)]);
                    h.truncate(hs);
                    (h[..] != d[cd + hash_offset + hs * i..cd + hash_offset + hs * (i + 1)]) as u64
                })
                .sum();
            sig_bad += bad;
            sig_ok += slots as u64 - bad;
        }
    }
    counts.insert("signature pages that match".into(), sig_ok);
    counts.insert("signature pages that do not match".into(), sig_bad);
    if sig_bad != 0 {
        let _ = writeln!(problems, "{sig_bad} signature pages do not match");
    }
    if auth_left != 0 {
        let _ = writeln!(problems, "{auth_left} auth rebases left");
    }
    let failed = preflight_cache(&b, &mut problems);
    counts.insert("dyld preflight: files that pass".into(), (b.files.len() - failed) as u64);
    counts.insert("dyld preflight: files that fail".into(), failed as u64);
    if let Some(mo) = macho_orig {
        verify_machos(mo, &lowered.join("macho"), &mut counts, &mut problems)?;
    }
    let problems: String = problems.lines().filter(|l| !l.is_empty()).take(50).map(|l| format!("{l}\n")).collect();
    let mut out = String::from("# a64-verify\n\n| Check | Count |\n|---|---:|\n");
    for (k, v) in &counts {
        let _ = writeln!(out, "| {k} | {v} |");
    }
    let _ = writeln!(out, "\nProblems: {}\n{problems}", if problems.is_empty() { "none" } else { "see below" });
    fs::write(lowered.join("verify-report.md"), &out)?;
    print!("{out}");
    if !problems.is_empty() {
        bail!("verification failed");
    }
    let _ = File::open(lowered)?;
    Ok(())
}

const DYLD_MAGIC: &[u8; 16] = b"dyld_v1  arm64e\0";
const CS_MAX_BLOB_SIZE: u64 = 40 << 20; // xnu bsd/kern/kern_descrip.c
const VM_PROT_ZF: u32 = 0x10;

/// What dyld (23F84, `preflightCacheFile`, 0x7e288) and the kernel's `F_ADDFILESIGS_RETURN` and map path check on one cache file.
/// None if it passes. dyld keeps the reason for the main file only: a subcache that fails here gives
/// `dyld cache '(null)' not loaded: (null)`, with no map call.
fn preflight_file(d: &[u8], f: &dsc::CacheFile, is_main: bool, platform: u32) -> Result<Option<String>> {
    let fail = |m: String| Ok(Some(m));
    let len = d.len() as u64;
    if len < 0x4000 {
        return fail("shared cache file pread() failed: under 16 KiB".into());
    }
    if &d[..16] != DYLD_MAGIC {
        return fail("shared cache file has wrong magic".into());
    }
    let map_off = dsc::u32_at(d, 0x10)?;
    let count = f.mappings.len();
    if map_off >= 0xe0 && dsc::u32_at(d, 0xd8)? != platform && (dsc::u32_at(d, 0x170)? == 0 || dsc::u32_at(d, 0x170)? != platform) {
        return fail(format!("shared cache file is for a different platform: {}", dsc::u32_at(d, 0xd8)?));
    }
    if d[0xdd] & 2 != 0 {
        return fail("shared cache file is for a simulator".into());
    }
    if !(1..=8).contains(&count) {
        return fail(format!("shared cache file mappings are invalid: {count}"));
    }
    let first = f.mappings[0];
    let last = f.mappings[count - 1];
    if first.fileoff != 0 {
        return fail("shared cache text file offset is invalid".into());
    }
    if f.sig_offset + f.sig_size != len {
        return fail(format!("shared cache code signature size is invalid: {:#x} + {:#x} != {len:#x}", f.sig_offset, f.sig_size));
    }
    if count >= 2 && last.maxprot != 1 {
        return fail(format!("shared cache linkedit permissions are invalid: {}", last.maxprot));
    }
    if first.maxprot | if count >= 2 { 4 } else { 0 } != 5 {
        return fail(format!("shared cache text permissions are invalid: {}", first.maxprot));
    }
    let mut file_end = 0;
    for w in f.mappings.windows(2) {
        file_end += w[0].size;
        if w[0].address + w[0].size > w[1].address || file_end != w[1].fileoff {
            return fail("shared cache mappings overlap".into());
        }
    }
    let Some(cd) = code_directories(d, f.sig_offset as usize)?.first().map(|c| c.0) else {
        return fail("code signature registration for shared cache failed: no CodeDirectory".into());
    };
    if f.sig_size > CS_MAX_BLOB_SIZE {
        return fail(format!("code signature registration for shared cache failed: blob of {:#x} bytes (E2BIG)", f.sig_size));
    }
    let (code_limit, hash_size, hash_type, shift) = (be32(d, cd + 32)? as u64, d[cd + 36], d[cd + 37], d[cd + 39]);
    if shift != 12 && shift != 14 {
        return fail(format!("code signature registration for shared cache failed: page shift {shift}"));
    }
    if !matches!((hash_type, hash_size), (1, 20) | (2, 32) | (3, 20) | (4, 48)) {
        return fail(format!("code signature registration for shared cache failed: hash {hash_type} size {hash_size}"));
    }
    let page = 1u64 << shift;
    let signed_end = code_limit.div_ceil(page) * page;
    if signed_end < f.sig_offset {
        return fail("code signature does not cover entire shared cache file".into());
    }
    for m in &f.mappings {
        if m.initprot & VM_PROT_ZF == 0 && m.fileoff + m.size > signed_end {
            return fail(format!("mapping at file offset {:#x}, {:#x} bytes, is not code-signed", m.fileoff, m.size));
        }
    }
    let (sub_off, sub_count) = (dsc::u32_at(d, 0x188)? as u64, dsc::u32_at(d, 0x18c)?);
    if sub_count > 0x7f {
        return fail(format!("shared cache file subcache count exceeds limit: {sub_count:#x}"));
    }
    if !is_main && sub_count != 0 {
        return fail(format!("no shared cache subcache indices: count {sub_count}"));
    }
    if map_off >= 0x1c9 && sub_off + 0x1c00 > len {
        return fail(format!("shared cache file pread() failed, could not read subcache entries: offset {sub_off:#x}"));
    }
    if count < 2 && f.slid.iter().any(|m| m.slide_size != 0) {
        return fail("slide info with no linkedit mapping (dyld stops on a bad optional)".into());
    }
    Ok(None)
}

/// Each file of a cache through `preflight_file`. Problem lines go to `problems`. Returns the count of files that fail.
fn preflight_cache(cache: &Cache, problems: &mut String) -> usize {
    let platform = cache.files.first().and_then(|f| dsc::u32_at(f.data(), 0xd8).ok()).unwrap_or(0);
    let mut failed = 0;
    for (i, f) in cache.files.iter().enumerate() {
        let r = preflight_file(f.data(), f, i == 0, platform).unwrap_or_else(|e| Some(e.to_string()));
        if let Some(m) = r {
            failed += 1;
            let _ = writeln!(problems, "{}: {m}", f.path.display());
        }
    }
    failed
}

/// a64-preflight: the checks of dyld and the kernel on a cache, before any boot. Every failure is printed.
pub fn preflight(main: &Path) -> Result<()> {
    let cache = Cache::open(main)?;
    let mut problems = String::new();
    let failed = preflight_cache(&cache, &mut problems);
    print!("{problems}");
    println!("dyld preflight: {} of {} files pass", cache.files.len() - failed, cache.files.len());
    if failed != 0 {
        bail!("{failed} cache files fail");
    }
    Ok(())
}

/// Every changed word of every lowered Mach-O has a rule; subtype is ARM64_ALL; new words decode on cortex-a73; signatures match.
fn verify_machos(orig: &Path, new_root: &Path, counts: &mut BTreeMap<String, u64>, problems: &mut String) -> Result<()> {
    let mut list = Vec::new();
    census::walk(orig, &mut list)?;
    list.sort();
    let rules = Rules::parse("all").map_err(|e| anyhow!(e))?;
    #[derive(Default)]
    struct R {
        c: BTreeMap<String, u64>,
        new_code: Vec<u32>,
        p: String,
    }
    let parts: Vec<R> = list
        .par_iter()
        .map(|f| -> Result<R> {
            let mut r = R::default();
            let rel = f.strip_prefix(orig)?;
            let (ma, mb) = (Map::open(f)?, Map::open(&new_root.join(rel))?);
            let (x, y) = (ma.bytes(), mb.bytes());
            if x.len() != y.len() {
                let _ = writeln!(r.p, "{}: size differs", rel.display());
                return Ok(r);
            }
            if x == y {
                *r.c.entry("mach-o files unchanged".into()).or_default() += 1;
                return Ok(r);
            }
            *r.c.entry("mach-o files changed".into()).or_default() += 1;
            for (off, len) in dsc::macho_slices(x) {
                let (sx, sy) = (&x[off..off + len], &y[off..off + len]);
                let Ok(m) = Macho::parse(sx) else { continue };
                if m.cpusubtype & 0xff != 2 || sx == sy {
                    continue;
                }
                if dsc::u32_at(sy, 8)? != 0 {
                    let _ = writeln!(r.p, "{}: subtype not ARM64_ALL", rel.display());
                }
                let mut in_sections: Vec<(usize, usize)> = m.instruction_sections().map(|s| (s.fileoff as usize, s.fileoff as usize + s.size as usize)).collect();
                in_sections.sort();
                let limit = m.code_signature.map(|c| c.0 as usize).unwrap_or(len);
                let text = m.segment("__TEXT").map(|t| (t.fileoff + t.filesize) as usize).unwrap_or(0);
                let mut at = 0usize;
                while at + 4 <= limit {
                    let (a, b) = (dsc::u32_at(sx, at)?, dsc::u32_at(sy, at)?);
                    if a != b && at != 8 {
                        let k = in_sections.partition_point(|s| s.1 <= at);
                        if in_sections.get(k).is_some_and(|s| s.0 <= at) {
                            if let Some(Ok((n, w))) = a64::one_word(a, &rules) {
                                if w == b {
                                    *r.c.entry(format!("mach-o one-word {n}")).or_default() += 1;
                                } else {
                                    let _ = writeln!(r.p, "{}+{at:#x}: {a:#x} -> {b:#x}, expected {w:#x}", rel.display());
                                }
                            } else if a64::lse_decode(a).is_some() && (b & 0xfc00_0000 == 0x1400_0000 || b & 0xfc00_0000 == 0x9400_0000) {
                                *r.c.entry("mach-o lse -> branch".into()).or_default() += 1;
                            } else {
                                let _ = writeln!(r.p, "{}+{at:#x}: {a:#x} -> {b:#x}: no rule", rel.display());
                            }
                        } else if a == 0 && at < text {
                            r.new_code.push(b);
                            *r.c.entry("mach-o new code words".into()).or_default() += 1;
                        } else {
                            let _ = writeln!(r.p, "{}+{at:#x}: {a:#x} -> {b:#x} outside code", rel.display());
                        }
                    }
                    at += 4;
                }
                if let Some((sig, _)) = m.code_signature {
                    for (cd, _) in code_directories(sy, sig as usize)? {
                        let hash_offset = be32(sy, cd + 16)? as usize;
                        let slots = be32(sy, cd + 28)? as usize;
                        let lim = be32(sy, cd + 32)? as usize;
                        let (hs, ht, ps) = (sy[cd + 36] as usize, sy[cd + 37], sy[cd + 39]);
                        let page = 1usize << ps;
                        for i in 0..slots {
                            let mut h = hash_page(ht, &sy[(i * page).min(lim)..((i + 1) * page).min(lim)]);
                            h.truncate(hs);
                            let key = if h[..] == sy[cd + hash_offset + hs * i..cd + hash_offset + hs * (i + 1)] { "mach-o signature pages that match" } else { "mach-o signature pages that do not match" };
                            *r.c.entry(key.into()).or_default() += 1;
                        }
                        *r.c.entry(format!("mach-o CodeDirectory page shift {ps}")).or_default() += 1;
                    }
                }
            }
            Ok(r)
        })
        .collect::<Result<Vec<_>>>()?;
    let mut new_code = Vec::new();
    for r in parts {
        for (k, v) in r.c {
            *counts.entry(k).or_default() += v;
        }
        new_code.extend(r.new_code);
        problems.push_str(&r.p);
    }
    new_code.sort();
    new_code.dedup();
    let tmp = new_root.join("../tmp-verify-macho");
    fs::create_dir_all(&tmp)?;
    let d = census::llvm_all(&new_code, census::BASE, &tmp, false)?;
    let bad = new_code.iter().zip(&d).filter(|(_, v)| v.is_none()).count();
    let _ = fs::remove_dir_all(&tmp);
    counts.insert("mach-o new code: invalid on cortex-a73".into(), bad as u64);
    if bad != 0 {
        let _ = writeln!(problems, "mach-o new code has {bad} words cortex-a73 cannot decode");
    }
    if counts.get("mach-o signature pages that do not match").copied().unwrap_or(0) != 0 {
        let _ = writeln!(problems, "mach-o signature pages do not match");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn align(v: usize, a: usize) -> usize {
        v.div_ceil(a) * a
    }

    /// A thin arm64e Mach-O with one __text of `code`, free zero bytes after it, function starts and an ad-hoc signature.
    fn synth_macho(code: &[u32], starts: &[u64]) -> Vec<u8> {
        let text_off = 0x400usize;
        let text_size = code.len() * 4;
        let le_off = 0x4000usize;
        let mut linkedit = Vec::new();
        // function starts: uleb deltas from __TEXT base
        let mut last = 0x1_0000_0000u64;
        for s in starts {
            let mut d = s - last;
            last = *s;
            loop {
                let b = (d & 0x7f) as u8;
                d >>= 7;
                linkedit.push(if d == 0 { b } else { b | 0x80 });
                if d == 0 {
                    break;
                }
            }
        }
        linkedit.push(0);
        linkedit.resize(align(linkedit.len(), 16), 0);
        let (fs_off, fs_size) = (le_off, linkedit.len());
        let sig_off = le_off + linkedit.len();
        // CodeDirectory: version 0x20100, one identifier byte, 4 KiB pages
        let pages = sig_off.div_ceil(4096);
        let cd_header = 44usize;
        let ident_off = cd_header;
        let hash_off = ident_off + 2;
        let cd_len = hash_off + pages * 32;
        let sig_len = 20 + cd_len;
        let mut f = vec![0u8; sig_off + sig_len];
        // header
        f[0..4].copy_from_slice(&0xfeed_facfu32.to_le_bytes());
        f[4..8].copy_from_slice(&0x0100_000cu32.to_le_bytes());
        f[8..12].copy_from_slice(&0x8000_0002u32.to_le_bytes());
        f[12..16].copy_from_slice(&2u32.to_le_bytes());
        let mut lc = Vec::new();
        let seg = |lc: &mut Vec<u8>, name: &str, vm: u64, vmsize: u64, off: u64, fsize: u64, sects: &[(&str, u64, u64, u32)]| {
            let start = lc.len();
            lc.extend_from_slice(&dsc::LC_SEGMENT_64.to_le_bytes());
            lc.extend_from_slice(&((72 + 80 * sects.len()) as u32).to_le_bytes());
            let mut n = [0u8; 16];
            n[..name.len()].copy_from_slice(name.as_bytes());
            lc.extend_from_slice(&n);
            for v in [vm, vmsize, off, fsize] {
                lc.extend_from_slice(&v.to_le_bytes());
            }
            for v in [5u32, 5, sects.len() as u32, 0] {
                lc.extend_from_slice(&v.to_le_bytes());
            }
            for (sn, addr, size, fo) in sects {
                let mut a = [0u8; 16];
                a[..sn.len()].copy_from_slice(sn.as_bytes());
                lc.extend_from_slice(&a);
                let mut b = [0u8; 16];
                b[..name.len()].copy_from_slice(name.as_bytes());
                lc.extend_from_slice(&b);
                lc.extend_from_slice(&addr.to_le_bytes());
                lc.extend_from_slice(&size.to_le_bytes());
                for v in [*fo, 2, 0, 0, dsc::SECTION_INSTRUCTIONS, 0, 0, 0] {
                    lc.extend_from_slice(&v.to_le_bytes());
                }
            }
            assert_eq!(lc.len() - start, 72 + 80 * sects.len());
        };
        seg(&mut lc, "__TEXT", 0x1_0000_0000, 0x4000, 0, 0x4000, &[("__text", 0x1_0000_0000 + text_off as u64, text_size as u64, text_off as u32)]);
        seg(&mut lc, "__LINKEDIT", 0x1_0000_4000, 0x4000, le_off as u64, (linkedit.len() + sig_len) as u64, &[]);
        for (cmd, a, b) in [(dsc::LC_FUNCTION_STARTS, fs_off as u32, fs_size as u32), (dsc::LC_CODE_SIGNATURE, sig_off as u32, sig_len as u32)] {
            lc.extend_from_slice(&cmd.to_le_bytes());
            lc.extend_from_slice(&16u32.to_le_bytes());
            lc.extend_from_slice(&a.to_le_bytes());
            lc.extend_from_slice(&b.to_le_bytes());
        }
        f[16..20].copy_from_slice(&4u32.to_le_bytes());
        f[20..24].copy_from_slice(&(lc.len() as u32).to_le_bytes());
        f[32..32 + lc.len()].copy_from_slice(&lc);
        for (i, w) in code.iter().enumerate() {
            f[text_off + i * 4..text_off + i * 4 + 4].copy_from_slice(&w.to_le_bytes());
        }
        f[le_off..le_off + linkedit.len()].copy_from_slice(&linkedit);
        // signature
        let s = sig_off;
        f[s..s + 4].copy_from_slice(&CSMAGIC_EMBEDDED.to_be_bytes());
        f[s + 4..s + 8].copy_from_slice(&(sig_len as u32).to_be_bytes());
        f[s + 8..s + 12].copy_from_slice(&1u32.to_be_bytes());
        f[s + 16..s + 20].copy_from_slice(&20u32.to_be_bytes());
        let c = s + 20;
        f[c..c + 4].copy_from_slice(&CSMAGIC_CD.to_be_bytes());
        f[c + 4..c + 8].copy_from_slice(&(cd_len as u32).to_be_bytes());
        f[c + 8..c + 12].copy_from_slice(&0x20100u32.to_be_bytes());
        f[c + 16..c + 20].copy_from_slice(&(hash_off as u32).to_be_bytes());
        f[c + 20..c + 24].copy_from_slice(&(ident_off as u32).to_be_bytes());
        f[c + 28..c + 32].copy_from_slice(&(pages as u32).to_be_bytes());
        f[c + 32..c + 36].copy_from_slice(&(sig_off as u32).to_be_bytes());
        f[c + 36] = 32;
        f[c + 37] = 2;
        f[c + 39] = 12;
        f[c + ident_off] = b'x';
        f
    }

    #[test]
    fn plain_slide_keeps_offset_and_next() {
        let e = dsc::SlideV5 { raw: 1 << 63 | 0x7ff << 52 | 1 << 51 | 1 << 50 | 0xabcd << 34 | 0x1234_5678 };
        assert!(e.auth());
        let p = dsc::SlideV5 { raw: e.as_plain() };
        assert!(!p.auth());
        assert_eq!((p.runtime_offset(), p.next(), p.high8()), (e.runtime_offset(), e.next(), 0));
    }

    #[test]
    fn slots_skip_sections_and_nonzero() {
        let mut b = vec![0u8; 4096];
        b[100] = 1; // a nonzero byte splits the run
        let mut out = Vec::new();
        zero_slots(&b, 0x1000, &[(0x1000 + 512, 0x1000 + 1024)], &mut out);
        assert!(out.iter().all(|s| s.1 >= 64 && s.0 % 16 == 0));
        assert!(out.iter().all(|s| !(s.0 < 0x1000 + 1024 && s.0 + s.1 > 0x1000 + 512)));
        assert!(out.iter().all(|s| !(s.0 <= 0x1000 + 100 && s.0 + s.1 > 0x1000 + 100)));
    }

    /// One cache file: header, one r-x mapping, an ad-hoc signature at the end. `subs` subcache suffixes in the main file.
    fn synth_cache_file(address: u64, subs: &[&str]) -> Vec<u8> {
        const CODE: usize = 0x8000;
        let put32 = |b: &mut Vec<u8>, at: usize, v: u32| b[at..at + 4].copy_from_slice(&v.to_le_bytes());
        let put64 = |b: &mut Vec<u8>, at: usize, v: u64| b[at..at + 8].copy_from_slice(&v.to_le_bytes());
        let mut sig = Vec::new();
        for v in [CSMAGIC_EMBEDDED, 0x38, 1, 0, 0x14] {
            sig.extend_from_slice(&v.to_be_bytes());
        }
        for v in [CSMAGIC_CD, 0x24, 0x20400, 2, 0, 0, 0, 0, CODE as u32] {
            sig.extend_from_slice(&v.to_be_bytes());
        }
        sig.extend_from_slice(&[32, 2, 0, 12]);
        let sig_off = CODE;
        let mut b = vec![0u8; CODE + 0x4000];
        b[..16].copy_from_slice(DYLD_MAGIC);
        put32(&mut b, 0x10, 0x228);
        put32(&mut b, 0x14, 1);
        put64(&mut b, 0x28, sig_off as u64);
        put64(&mut b, 0x30, 0x4000);
        put32(&mut b, 0xd8, 2);
        put32(&mut b, 0x138, 0x260);
        put32(&mut b, 0x13c, 1);
        put64(&mut b, 0x228, address);
        put64(&mut b, 0x230, CODE as u64);
        put32(&mut b, 0x240, 5);
        put32(&mut b, 0x244, 5);
        put64(&mut b, 0x260, address);
        put64(&mut b, 0x268, CODE as u64);
        put32(&mut b, 0x290, 5);
        put32(&mut b, 0x294, 5);
        put32(&mut b, 0x1c0, 0x400); // no images
        if !subs.is_empty() {
            put32(&mut b, 0x188, 0x1000);
            put32(&mut b, 0x18c, subs.len() as u32);
            for (i, s) in subs.iter().enumerate() {
                let e = 0x1000 + 56 * i;
                put64(&mut b, e + 16, (i as u64 + 1) * 0x8000);
                b[e + 24..e + 24 + s.len()].copy_from_slice(s.as_bytes());
            }
        }
        b[sig_off..sig_off + sig.len()].copy_from_slice(&sig);
        b
    }

    #[test]
    fn lower_keeps_cache_headers_and_preflight_finds_code_there() {
        let dir = std::env::temp_dir().join(format!("op10-preflight-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let (main, sub) = (dir.join("c"), dir.join("c.01"));
        fs::write(&main, synth_cache_file(0x1_8000_0000, &[".01"])).unwrap();
        let mut bad = synth_cache_file(0x1_8000_8000, &[]);
        fs::write(&sub, &bad).unwrap();
        let cache = Cache::open(&main).unwrap();
        let mut problems = String::new();
        assert_eq!(preflight_cache(&cache, &mut problems), 0, "{problems}");
        // No image in the main file: all of its mapping stays. The subcache keeps only its header and tables.
        let r = cache.reserved_ranges().unwrap();
        assert_eq!(r, vec![(0x1_8000_0000, 0x1_8000_8000), (0x1_8000_8000, 0x1_8000_8000 + 0x298)]);
        let mut taken = r.clone();
        taken.sort();
        let mut slots = Vec::new();
        zero_slots(cache.files[1].data().get(..0x8000).unwrap(), 0x1_8000_8000, &taken, &mut slots);
        assert!(!slots.is_empty());
        assert!(slots.iter().all(|s| s.0 >= 0x1_8000_8000 + 0x298), "{slots:x?}");
        drop(cache);
        // The first-boot failure: a stub on header offset 0x188. dyld drops this message for a subcache.
        bad[0x188..0x18c].copy_from_slice(&0xf849_07feu32.to_le_bytes());
        bad[0x18c..0x190].copy_from_slice(&0x1400_41d7u32.to_le_bytes());
        fs::write(&sub, &bad).unwrap();
        let cache = Cache::open(&main).unwrap();
        let mut problems = String::new();
        assert_eq!(preflight_cache(&cache, &mut problems), 1);
        assert!(problems.contains("subcache count exceeds limit"), "{problems}");
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn dead_image_with_load_time_code_is_refused() {
        let sect = |name: &str, flags: u32, size: u64| dsc::Section { segment: "__TEXT".into(), name: name.into(), addr: 0x1000, size, fileoff: 0, flags, reserved2: 0 };
        let image = |sections| Macho { sections, ..Macho::default() };
        // ANECompiler 23F84: two offsets in __init_offsets, type 0x16. Trampolines over them were the crash of every daemon that loads it.
        let ane = image(vec![sect("__text", dsc::SECTION_INSTRUCTIONS, 0x143b4e4), sect("__init_offsets", 0x16, 8)]);
        assert!(dead_image_runs_code(&ane).unwrap().contains("__init_offsets"));
        assert!(dead_image_runs_code(&image(vec![sect("__mod_init_func", 0x09, 8)])).is_some());
        assert!(dead_image_runs_code(&image(vec![sect("__objc_nlclslist", 0, 8)])).is_some());
        // VisualGeneration 23F84: Swift and ObjC metadata, classes are lazy.
        let vg = image(vec![sect("__text", dsc::SECTION_INSTRUCTIONS, 0x29b970), sect("__objc_classlist", 0x1000_0000, 0x240), sect("__init_offsets", 0x16, 0)]);
        assert_eq!(dead_image_runs_code(&vg), None);
    }

    #[test]
    fn plan_respects_reach() {
        // casal w0, w1, [x2], a dead-x30 site; slot too far away, then one in reach
        let site = LseSite { addr: 0x2_0000_0000, word: 0x88e0_fc41, lr_dead: true };
        let far = plan_lse(vec![site], vec![(0x3_0000_0000, 4096)]);
        assert_eq!((far.bl_sites, far.left_no_space), (0, 1));
        let near = plan_lse(vec![site], vec![(0x2_0100_0000, 4096)]);
        assert_eq!((near.bl_sites, near.left_no_space, near.trampolines), (1, 0, 1));
        let e = near.edits[0];
        assert_eq!(e.new & 0xfc00_0000, 0x9400_0000);
        assert_eq!(e.addr as i64 + (((e.new & 0x3ff_ffff) as i64) << 38 >> 38) * 4, 0x2_0100_0000);
        // a site with live x30 gets a stub and a b
        let live = plan_lse(vec![LseSite { lr_dead: false, ..site }], vec![(0x2_0100_0000, 4096)]);
        assert_eq!((live.stub_sites, live.edits[0].new & 0xfc00_0000), (1, 0x1400_0000));
        assert!(live.code.iter().any(|c| c.1 == 0xf817_0ffe), "the stub is there");
    }

    /// Whole path on a synthetic file: needs llvm-mc on PATH.
    #[test]
    fn synthetic_macho_end_to_end() {
        if std::process::Command::new("llvm-mc").arg("--version").output().is_err() {
            eprintln!("skip: no llvm-mc");
            return;
        }
        let tmp = std::env::temp_dir().join(format!("a64-lower-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&tmp);
        fs::create_dir_all(tmp.join("in")).unwrap();
        let base = 0x1_0000_0400u64;
        let code = [
            0xd503_237fu32, // 0 pacibsp: stays, NOP here
            0xa9bf_7bfd,    // 1 stp x29, x30, [sp, #-16]!
            0x88e0_fc41,    // 2 casal w0, w1, [x2]: x30 saved, bl
            0xb8bf_c020,    // 3 ldapr w0, [x1] -> ldar
            0xd73f_0a11,    // 4 blraa x16, x17 -> blr x16
            0xa8c1_7bfd,    // 5 ldp x29, x30, [sp], #16
            0xd65f_0fff,    // 6 retab -> ret
            0xf8e0_0041,    // 7 ldaddal x0, x1, [x2]: leaf, x30 live, stub
            0xd65f_03c0,    // 8 ret
            0xd503_415f,    // 9 msr DIT, #1 -> NOP
            0xd65f_03c0,    // 10 ret
            0xffff_ffff,    // 11 data in code (undecodable): function 3 stops
            0x88e0_fc41,    // 12 LSE-shaped word in the same data island: must stay
        ];
        let file = synth_macho(&code, &[base, base + 7 * 4, base + 9 * 4]);
        let input = tmp.join("in/bin");
        fs::write(&input, &file).unwrap();
        let out = tmp.join("out");
        run(None, &[input.clone()], &out, "all", 0, &[], false).unwrap();
        let got = fs::read(out.join("macho/bin")).unwrap();
        let w = |i: usize| u32::from_le_bytes(got[0x400 + i * 4..0x400 + i * 4 + 4].try_into().unwrap());
        assert_eq!(w(0), 0xd503_237f);
        assert_eq!(w(2) & 0xfc00_0000, 0x9400_0000, "casal -> bl");
        assert_eq!(w(3), 0x88df_fc20, "ldapr -> ldar");
        assert_eq!(w(4), 0xd63f_0200, "blraa -> blr");
        assert_eq!(w(6), a64::RET, "retab -> ret");
        assert_eq!(w(7) & 0xfc00_0000, 0x1400_0000, "live x30 -> b to the stub");
        assert_eq!(w(9), a64::NOP, "msr DIT -> NOP");
        assert_eq!(w(12), 0x88e0_fc41, "not proven: stays");
        assert_eq!(u32::from_le_bytes(got[8..12].try_into().unwrap()), 0, "subtype ARM64_ALL");
        // Independent check, and the same bytes on a second run
        let mut counts = BTreeMap::new();
        let mut problems = String::new();
        verify_machos(&tmp.join("in"), &out.join("macho"), &mut counts, &mut problems).unwrap();
        assert_eq!(problems, "", "{counts:?}");
        assert_eq!(counts.get("mach-o signature pages that do not match"), None);
        let out2 = tmp.join("out2");
        run(None, &[input], &out2, "all", 0, &[], false).unwrap();
        assert_eq!(got, fs::read(out2.join("macho/bin")).unwrap());
        let _ = fs::remove_dir_all(&tmp);
    }
}
