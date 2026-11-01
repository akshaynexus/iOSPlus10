//! `op10tool a64-abi`: trace user-client and sandbox calls of named images in a dyld shared cache, statically.
//! Finds every `bl`/`b` to IOConnectCall*Method and __mac_syscall (direct, through __stubs/__auth_stubs, or a stub island)
//! and reads the selector and the counts that are immediates just before the call. Dumps symbols and C strings of the
//! images for the SPI comparison. Output: abi-calls.tsv, syms-<image>.txt, cstr-<image>.txt. Reads only.

use crate::census;
use crate::dsc::{self, Cache, Macho};
use anyhow::Result;
use std::collections::{BTreeMap, HashMap};
use std::fmt::Write as _;
use std::fs;
use std::path::Path;

const CLIENTS: &[&str] = &[
    "IOSurface.framework/IOSurface",
    "IOSurfaceAccelerator.framework/IOSurfaceAccelerator",
    "IOMobileFramebuffer.framework/IOMobileFramebuffer",
    "libaks",
    "AppleKeyStore",
    "MobileKeyBag.framework/MobileKeyBag",
    "libsystem_sandbox",
    "libsandbox",
    "IOAccelerator.framework/IOAccelerator",
    "IOGPU.framework/IOGPU",
    "OpenGLES.framework/OpenGLES",
    "OpenGLES.framework/GLEngine.bundle/GLEngine",
    "OpenGLES.framework/libGFXShared",
    "OpenGLES.framework/libGLImage",
    "OpenGLES.framework/libCoreFSCache",
    "OpenGLES.framework/libCoreVMClient",
    "QuartzCore.framework/QuartzCore",
    "CoreDisplay",
];
const APIS: &[&str] = &[
    "_IOConnectCallMethod",
    "_IOConnectCallAsyncMethod",
    "_IOConnectCallStructMethod",
    "_IOConnectCallAsyncStructMethod",
    "_IOConnectCallScalarMethod",
    "_IOConnectCallAsyncScalarMethod",
    "_IOConnectMapMemory64",
    "_IOServiceOpen",
    "___mac_syscall",
    "___sandbox_ms",
    "___sandbox_msp",
    "___sandbox_me",
    "___sandbox_mm",
    "_mach_absolute_time_never",
];

fn decode_bitmask(w: u32) -> Option<u64> {
    let (n, immr, imms) = ((w >> 22) & 1, (w >> 16) & 63, (w >> 10) & 63);
    let x = n << 6 | (!imms & 63);
    if x == 0 {
        return None;
    }
    let len = 31 - x.leading_zeros();
    let size = 1u32 << len;
    let levels = size - 1;
    let (s, r) = (imms & levels, immr & levels);
    if s == levels {
        return None;
    }
    let mut pat: u64 = if s + 1 == 64 { !0 } else { (1u64 << (s + 1)) - 1 };
    if r != 0 {
        pat = ((pat >> r) | (pat << (size - r))) & if size == 64 { !0 } else { (1u64 << size) - 1 };
    }
    let mut out = 0u64;
    let mut i = 0;
    while i < 64 {
        out |= pat << i;
        i += size;
    }
    Some(if w >> 31 == 0 { out & 0xffff_ffff } else { out })
}

/// Immediate in register `reg` at word index `at`, looking back. Follows one `mov Wd, Wn`.
fn imm_before(words: &[u32], at: usize, mut reg: u32, floor: usize) -> Option<u64> {
    let mut i = at;
    let mut steps = 0;
    while i > floor && steps < 64 {
        i -= 1;
        steps += 1;
        let w = words[i];
        // block end: stop
        let (next, target) = crate::a64::flow(w, 0);
        if !next && target.is_none() {
            return None;
        }
        if w & 0xfc00_0000 == 0x9400_0000 || w & 0xffff_fc00 == 0xd63f_0000 || w & 0xffff_f800 == 0xd73f_0800 {
            // a call: the argument registers before it are not ours (x0-x18 are caller saved)
            return None;
        }
        let rd = w & 31;
        if rd != reg {
            continue;
        }
        if w & 0x7f80_0000 == 0x5280_0000 {
            return Some((((w >> 5) & 0xffff) as u64) << (((w >> 21) & 3) * 16));
        }
        if w & 0x7f80_0000 == 0x1280_0000 {
            let v = !((((w >> 5) & 0xffff) as u64) << (((w >> 21) & 3) * 16));
            return Some(if w >> 31 == 0 { v & 0xffff_ffff } else { v });
        }
        if w & 0x7f80_03e0 == 0x3200_03e0 {
            return decode_bitmask(w);
        }
        if w & 0x7fe0_ffe0 == 0x2a00_03e0 {
            let m = (w >> 16) & 31;
            if m == 31 {
                return Some(0);
            }
            reg = m;
            continue;
        }
        return None; // written by something else
    }
    None
}

fn pointer_value(cache: &Cache, addr: u64) -> Option<u64> {
    let raw = u64::from_le_bytes(cache.read(addr, 8).ok()?.try_into().ok()?);
    for v in [raw & 0xff_ffff_ffff, cache.shared_region_start + (raw & 0x3_ffff_ffff), cache.shared_region_start + (raw & 0xffff_ffff), raw & 0x7ff_ffff_ffff] {
        if cache.locate(v).is_some() {
            return Some(v);
        }
    }
    None
}

/// Target of a stub at `addr`, by shape: adrp x16/x17 + (ldr | add + ldr) + br/braa; or adrp + add + br.
fn stub_target(cache: &Cache, addr: u64) -> Option<u64> {
    let b = cache.read(addr, 16).ok()?;
    let w: Vec<u32> = b.chunks_exact(4).map(|c| u32::from_le_bytes(c.try_into().unwrap())).collect();
    if w[0] & 0x9f00_0000 != 0x9000_0000 {
        return None;
    }
    let immlo = ((w[0] >> 29) & 3) as i64;
    let immhi = (((w[0] >> 5) & 0x7ffff) as i64) << 45 >> 45;
    let page = (addr as i64 & !0xfff) + ((immhi << 2 | immlo) << 12);
    let is_jump = |x: u32| x & 0xffff_fc1f == 0xd61f_0000 || x & 0xffff_f800 == 0xd61f_0800 || x & 0xffff_f800 == 0xd71f_0800;
    // adrp, ldr, br
    if w[1] & 0xffc0_0000 == 0xf940_0000 && is_jump(w[2]) {
        let off = (((w[1] >> 10) & 0xfff) * 8) as i64;
        return pointer_value(cache, (page + off) as u64);
    }
    // adrp, add, br
    if w[1] & 0xff80_0000 == 0x9100_0000 && is_jump(w[2]) {
        let off = ((w[1] >> 10) & 0xfff) as i64;
        return Some((page + off) as u64);
    }
    // adrp, add, ldr, braa
    if w[1] & 0xff80_0000 == 0x9100_0000 && w[2] & 0xffc0_0000 == 0xf940_0000 && is_jump(w[3]) {
        let off = ((w[1] >> 10) & 0xfff) as i64 + (((w[2] >> 10) & 0xfff) * 8) as i64;
        return pointer_value(cache, (page + off) as u64);
    }
    None
}

pub fn run(main: &Path, outdir: &Path) -> Result<()> {
    fs::create_dir_all(outdir)?;
    let cache = Cache::open(main)?;
    let wanted: Vec<u64> = cache.images.iter().filter(|(_, p)| CLIENTS.iter().any(|c| p.contains(c))).map(|(a, _)| *a).collect();
    let mut local = dsc::cache_local_symbols(main, &cache, &wanted).unwrap_or_default();
    // Targets
    let mut targets: HashMap<u64, &'static str> = HashMap::new();
    for (address, path) in &cache.images {
        if !(path.contains("IOKit.framework") || path.contains("libsystem_kernel") || path.contains("libsystem_sandbox")) {
            continue;
        }
        let head = cache.read(*address, 32)?;
        let head = cache.read(*address, 32 + dsc::u32_at(head, 20)? as usize)?;
        let m = Macho::parse(head)?;
        for (a, n) in dsc::image_symbols(&cache, &m) {
            if let Some(api) = APIS.iter().find(|x| **x == n) {
                targets.insert(a, api);
            }
        }
    }
    let mut lines = String::from("image\tfunction\tapi\tselector\tinput_scalars\tinput_struct_or_output\tsite\n");
    let mut summary: BTreeMap<(String, String), u64> = BTreeMap::new();
    let units = census::cache_units(&cache)?;
    for u in &units {
        if !CLIENTS.iter().any(|c| u.name.contains(c)) {
            continue;
        }
        let image = cache.images.iter().find(|(_, p)| *p == u.name);
        let Some((img_addr, _)) = image else { continue };
        let short = u.name.rsplit('/').next().unwrap_or(&u.name).to_string();
        let mut syms: Vec<(u64, String)> = local.remove(img_addr).unwrap_or_default();
        let head = cache.read(*img_addr, 32)?;
        let head = cache.read(*img_addr, 32 + dsc::u32_at(head, 20)? as usize)?;
        let m = Macho::parse(head)?;
        syms.extend(dsc::image_symbols(&cache, &m));
        syms.retain(|e| e.1 != "<redacted>");
        syms.sort();
        syms.dedup();
        // symbol and string dumps
        let mut t = String::new();
        let mut names: Vec<&str> = syms.iter().map(|e| e.1.as_str()).collect();
        names.sort();
        names.dedup();
        for n in names {
            let _ = writeln!(t, "{n}");
        }
        fs::write(outdir.join(format!("syms-{short}.txt")), t)?;
        let mut t = String::new();
        for s in m.sections.iter().filter(|s| s.name == "__cstring" || s.name == "__oslogstring") {
            if let Ok(b) = cache.read(s.addr, s.size as usize) {
                for part in b.split(|&c| c == 0) {
                    if part.len() >= 4 && part.iter().all(|&c| (0x20..0x7f).contains(&c)) {
                        let _ = writeln!(t, "{}", String::from_utf8_lossy(part));
                    }
                }
            }
        }
        fs::write(outdir.join(format!("cstr-{short}.txt")), t)?;
        for r in &u.ranges {
            let n = r.words.len();
            let starts: Vec<usize> = u.starts.iter().filter(|&&a| a >= r.addr && a < r.addr + n as u64 * 4).map(|&a| ((a - r.addr) / 4) as usize).collect();
            for (i, &w) in r.words.iter().enumerate() {
                if w & 0x7c00_0000 != 0x1400_0000 {
                    continue; // not b or bl
                }
                let imm = (((w & 0x3ff_ffff) as i64) << 38) >> 38;
                let pc = r.addr + i as u64 * 4;
                let t = (pc as i64 + imm * 4) as u64;
                let api = targets.get(&t).copied().or_else(|| stub_target(&cache, t).and_then(|x| targets.get(&x).copied()));
                let Some(api) = api else { continue };
                let f = starts.partition_point(|&s| s <= i);
                let floor = if f > 0 { starts[f - 1] } else { 0 };
                let fname = syms.partition_point(|e| e.0 <= pc);
                let func = if fname > 0 { syms[fname - 1].1.clone() } else { format!("{pc:#x}") };
                let is_sandbox = api.contains("sandbox") || api.contains("mac_syscall");
                let sel = imm_before(r.words, i, 1, floor);
                let (a3, a5) = if api.contains("Struct") { (imm_before(r.words, i, 3, floor), None) } else { (imm_before(r.words, i, 3, floor), imm_before(r.words, i, 5, floor)) };
                let show = |v: Option<u64>| v.map(|x| x.to_string()).unwrap_or_else(|| "?".into());
                let _ = writeln!(lines, "{short}\t{func}\t{api}\t{}\t{}\t{}\t{pc:#x}", show(sel), show(a3), show(a5));
                if !is_sandbox || sel.is_some() {
                    *summary.entry((short.clone(), format!("{api} {}", show(sel)))).or_default() += 1;
                }
            }
        }
    }
    fs::write(outdir.join("abi-calls.tsv"), lines)?;
    let mut t = String::from("image\tapi+selector\tcall_sites\n");
    for ((i, k), n) in &summary {
        let _ = writeln!(t, "{i}\t{k}\t{n}");
    }
    fs::write(outdir.join("abi-summary.tsv"), t)?;
    println!("{} API addresses, {} summary rows; {}", targets.len(), summary.len(), outdir.display());
    Ok(())
}

/// `a64-dis`: disassemble one function of a cache image (llvm-mc), with symbol names on branch targets; or list the callers
/// of a symbol inside the image. For ABI reading only.
pub fn dis(main: &Path, image: &str, symbol: &str, xref: bool, count: usize, tmp: &Path) -> Result<()> {
    fs::create_dir_all(tmp)?;
    let cache = Cache::open(main)?;
    let (addr, path) = cache.images.iter().find(|(_, p)| p.contains(image)).ok_or_else(|| anyhow::anyhow!("no image {image}"))?;
    let head = cache.read(*addr, 32)?;
    let head = cache.read(*addr, 32 + dsc::u32_at(head, 20)? as usize)?;
    let m = Macho::parse(head)?;
    let mut syms = dsc::cache_local_symbols(main, &cache, &[*addr]).unwrap_or_default().remove(addr).unwrap_or_default();
    syms.extend(dsc::image_symbols(&cache, &m));
    syms.retain(|e| e.1 != "<redacted>");
    syms.sort();
    let name_of = |a: u64| syms.iter().find(|e| e.0 == a).map(|e| e.1.as_str());
    let wanted: Vec<u64> = syms.iter().filter(|e| e.1 == symbol || e.1.contains(symbol)).map(|e| e.0).collect();
    println!("{path}: {} symbols match {symbol}", wanted.len());
    if xref {
        for s in m.instruction_sections() {
            let Some(words) = census::word_bytes(cache.read(s.addr, s.size as usize)?) else { continue };
            for (i, &w) in words.iter().enumerate() {
                // adrp + add: a reference to the symbol's address
                if w & 0x9f00_0000 == 0x9000_0000 && i + 1 < words.len() {
                    let n = words[i + 1];
                    if n & 0xff80_0000 == 0x9100_0000 && (n >> 5) & 31 == w & 31 {
                        let pc = s.addr + i as u64 * 4;
                        let immlo = ((w >> 29) & 3) as i64;
                        let immhi = (((w >> 5) & 0x7ffff) as i64) << 45 >> 45;
                        let t = ((pc as i64 & !0xfff) + ((immhi << 2 | immlo) << 12)) as u64 + ((n >> 10) & 0xfff) as u64;
                        if wanted.contains(&t) {
                            let k = syms.partition_point(|e| e.0 <= pc);
                            println!("{pc:#x} adr -> {} in {}", name_of(t).unwrap_or("?"), if k > 0 { syms[k - 1].1.as_str() } else { "?" });
                        }
                    }
                }
                if w & 0x7c00_0000 != 0x1400_0000 {
                    continue;
                }
                let imm = (((w & 0x3ff_ffff) as i64) << 38) >> 38;
                let pc = s.addr + i as u64 * 4;
                let t = (pc as i64 + imm * 4) as u64;
                let t2 = stub_target(&cache, t).unwrap_or(t);
                if wanted.contains(&t) || wanted.contains(&t2) {
                    let k = syms.partition_point(|e| e.0 <= pc);
                    let f = if k > 0 { syms[k - 1].1.as_str() } else { "?" };
                    println!("{pc:#x} {} -> {} in {f}", if w >> 31 != 0 { "bl" } else { "b" }, name_of(t).or(name_of(t2)).unwrap_or("?"));
                }
            }
        }
        return Ok(());
    }
    for start in wanted.iter().take(3) {
        let next = syms.iter().find(|e| e.0 > *start).map(|e| e.0).unwrap_or(*start + 4096);
        let n = (((next - *start) / 4) as usize).min(count);
        let Some(words) = census::word_bytes(cache.read(*start, n * 4)?) else { continue };
        let dec = census::llvm_all(words, &["-mcpu=apple-a13"], tmp, true)?;
        println!("{}:", name_of(*start).unwrap_or("?"));
        for (i, (w, d)) in words.iter().zip(dec).enumerate() {
            let pc = *start + i as u64 * 4;
            let mut note = String::new();
            if w & 0x7c00_0000 == 0x1400_0000 {
                let imm = (((w & 0x3ff_ffff) as i64) << 38) >> 38;
                let t = (pc as i64 + imm * 4) as u64;
                let t2 = stub_target(&cache, t).unwrap_or(t);
                note = format!("  ; {:#x} {}", t2, name_of(t).or(name_of(t2)).unwrap_or(""));
            }
            println!("{pc:#x} {w:08x} {}{note}", d.as_deref().unwrap_or("?"));
        }
    }
    let _ = fs::remove_dir_all(tmp);
    Ok(())
}
