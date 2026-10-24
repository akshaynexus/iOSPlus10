//! Port byte patches from one UEFI driver build to another (r0q S22 -> negroni NE2211).
//! Masked aarch64 context match (from slop uefi/negroni/portpatch2.py), plus:
//! - patched b/bl re-aimed at the function matching the r0q destination's code (masked search),
//!   with the old "same distance" rule only as a reported fallback;
//! - --skip OFF for a known-missing patch run; --byte OFF=OLD:NEW for a checked data patch.

use anyhow::{anyhow, Result};
use std::path::Path;

fn w(b: &[u8], i: usize) -> u32 { u32::from_le_bytes(b[i..i + 4].try_into().unwrap()) }

fn mask(x: u32) -> u32 {
    if x & 0x7c00_0000 == 0x1400_0000 { return x & 0xfc00_0000; }   // b / bl
    if x & 0xff00_0010 == 0x5400_0000 { return x & 0xff00_001f; }   // b.cond
    if x & 0x7e00_0000 == 0x3400_0000 { return x & 0xff00_001f; }   // cbz/cbnz
    if x & 0x7e00_0000 == 0x3600_0000 { return x & 0xfff8_001f; }   // tbz/tbnz
    if x & 0x1f00_0000 == 0x1000_0000 { return x & 0x9f00_001f; }   // adr/adrp
    if x & 0x3b00_0000 == 0x1800_0000 { return x & 0xff00_001f; }   // ldr literal
    if x & 0xffc0_0000 == 0x9100_0000 { return x & 0xffc0_03ff; }   // add imm
    if x & 0x3b40_0000 == 0x3940_0000 { return x & 0xffc0_03ff; }   // ldr/str unsigned imm
    x
}

fn mwords(b: &[u8], a: isize, n: usize) -> Option<Vec<u32>> {
    if a < 0 || a as usize + 4 * n > b.len() { return None; }
    Some((0..n).map(|k| mask(w(b, a as usize + 4 * k))).collect())
}

fn find_unique(tw: &[u32], pat: &[u32]) -> Option<usize> {
    let mut hit = None;
    for k in 0..tw.len().saturating_sub(pat.len()) {
        if tw[k] == pat[0] && tw[k..k + pat.len()] == *pat {
            if hit.is_some() { return None; }
            hit = Some(k);
        }
    }
    hit
}

fn unique_match(src: &[u8], at: usize, before: usize, after: usize, tw: &[u32]) -> Option<usize> {
    let pat = mwords(src, at as isize - 4 * before as isize, before + after)?;
    find_unique(tw, &pat).map(|k| (k + before) * 4)
}

pub fn run(orig: &Path, patched: &Path, target: &Path, out: &Path, skip: &[usize], bytes: &[String]) -> Result<bool> {
    let o = std::fs::read(orig)?;
    let p = std::fs::read(patched)?;
    let mut t = std::fs::read(target)?;
    let tw: Vec<u32> = (0..t.len().saturating_sub(3)).step_by(4).map(|k| mask(w(&t, k))).collect();
    let mut runs: Vec<(usize, usize)> = Vec::new();
    for i in (0..o.len().saturating_sub(3)).step_by(4) {
        if o[i..i + 4] != p[i..i + 4] {
            match runs.last_mut() { Some(r) if r.1 == i => r.1 = i + 4, _ => runs.push((i, i + 4)) }
        }
    }
    let mut ok = true;
    for (ra, rb) in runs {
        if skip.contains(&ra) { println!("  run {ra:#x}+{}: skipped (--skip)", rb - ra); continue; }
        let mut found = None;
        let mut used = 0;
        for ctx in [12usize, 10, 8, 6, 5, 4] {
            if let Some(pat) = mwords(&o, ra as isize - 4 * ctx as isize, ctx + (rb - ra) / 4 + ctx) {
                if let Some(k) = find_unique(&tw, &pat) { found = Some((k + ctx) * 4); used = ctx; break; }
            }
        }
        let Some(found) = found else { println!("  run {ra:#x}+{}: NO MATCH", rb - ra); ok = false; continue };
        for k in (0..rb - ra).step_by(4) {
            let (mut nw, ow) = (w(&p, ra + k), w(&o, ra + k));
            if nw & 0x7c00_0000 == 0x1400_0000 && nw != ow {
                let off = (((nw & 0x3ff_ffff) ^ 0x200_0000) as i64) - 0x200_0000;
                let dest = (ra + k) as i64 + off * 4;
                let mut nd = None;
                for c in [8usize, 6, 4] {
                    nd = unique_match(&o, dest as usize, 0, c, &tw).or_else(|| unique_match(&o, dest as usize, c, c, &tw));
                    if nd.is_some() { break; }
                }
                let how = if nd.is_some() { "by code match" } else { "SAME-DISTANCE FALLBACK (check by hand)" };
                let nd = nd.map(|x| x as i64).unwrap_or((found + k) as i64 + off * 4);
                nw = (nw & 0xfc00_0000) | ((((nd - (found + k) as i64) / 4) as u32) & 0x3ff_ffff);
                println!("    branch at {:#x} -> {:#x} ({how}; r0q dest {:#x})", found + k, nd, dest);
            }
            t[found + k..found + k + 4].copy_from_slice(&nw.to_le_bytes());
        }
        let words: Vec<String> = (0..rb - ra).step_by(4).map(|k| format!("{:08x}", w(&t, found + k))).collect();
        println!("  run {ra:#x}+{} -> {found:#x} ctx {used}: {}", rb - ra, words.join(" "));
    }
    for spec in bytes {
        let (off, vals) = spec.split_once('=').ok_or_else(|| anyhow!("--byte OFF=OLD:NEW"))?;
        let (old, new) = vals.split_once(':').ok_or_else(|| anyhow!("--byte OFF=OLD:NEW"))?;
        let off = usize::from_str_radix(off.trim_start_matches("0x"), 16)?;
        let (old, new) = (u8::from_str_radix(old, 16)?, u8::from_str_radix(new, 16)?);
        if t[off] != old {
            println!("  byte {off:#x}: is {:#04x}, expected {old:#04x}: NOT PATCHED", t[off]);
            ok = false;
            continue;
        }
        t[off] = new;
        println!("  byte {off:#x}: {old:#04x} -> {new:#04x}");
    }
    std::fs::write(out, &t)?;
    Ok(ok)
}
