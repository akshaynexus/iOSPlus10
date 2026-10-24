//! Unpack a Qualcomm uefi.img (firmware volumes, gzip/LZMA GUID-defined sections).
//! OUTDIR/<FILE_GUID>/: name.txt, type.txt, pe32.efi / te.efi / depex.bin / raw.bin (first of each
//! kind), file.bin (raw FFS files); OUTDIR/index.tsv (guid, type, name, sections), sorted by name.
//! The same GUID found in several volumes is merged; the first section of each kind wins.

use anyhow::Result;
use flate2::read::GzDecoder;
use std::collections::HashMap;
use std::fs;
use std::io::Read;
use std::path::Path;

const GZIP_GUID: [u8; 16] = guid_le(0x1d301fe9, 0xbe79, 0x4353, [0x91, 0xc2, 0xd2, 0x3b, 0xc9, 0x59, 0xae, 0x0c]);
const LZMA_GUID: [u8; 16] = guid_le(0xee4e5898, 0x3914, 0x4259, [0x9d, 0x6e, 0xdc, 0x7b, 0xd7, 0x94, 0x03, 0xcf]);

const fn guid_le(a: u32, b: u16, c: u16, d: [u8; 8]) -> [u8; 16] {
    let a = a.to_le_bytes(); let b = b.to_le_bytes(); let c = c.to_le_bytes();
    [a[0], a[1], a[2], a[3], b[0], b[1], c[0], c[1], d[0], d[1], d[2], d[3], d[4], d[5], d[6], d[7]]
}

fn guid_str(g: &[u8]) -> String {
    format!("{:08X}-{:04X}-{:04X}-{:02X}{:02X}-{:02X}{:02X}{:02X}{:02X}{:02X}{:02X}",
        u32::from_le_bytes(g[0..4].try_into().unwrap()), u16::from_le_bytes([g[4], g[5]]),
        u16::from_le_bytes([g[6], g[7]]), g[8], g[9], g[10], g[11], g[12], g[13], g[14], g[15])
}

#[derive(Default)]
struct Rec { ftype: u8, name: Option<String>, secs: Vec<(&'static str, Vec<u8>)> }
impl Rec {
    fn set(&mut self, k: &'static str, v: &[u8]) {
        if !self.secs.iter().any(|(n, _)| *n == k) { self.secs.push((k, v.to_vec())) }
    }
}

#[derive(Default)]
struct Unpacker { order: Vec<String>, files: HashMap<String, Rec> }

fn sections(buf: &[u8]) -> Vec<(u8, &[u8])> {
    let mut out = Vec::new();
    let mut i = 0usize;
    while i + 4 <= buf.len() {
        let mut size = u32::from_le_bytes([buf[i], buf[i + 1], buf[i + 2], 0]) as usize;
        let typ = buf[i + 3];
        let mut hdr = 4;
        if size == 0xffffff {
            if i + 8 > buf.len() { break; }
            size = u32::from_le_bytes(buf[i + 4..i + 8].try_into().unwrap()) as usize;
            hdr = 8;
        }
        if size < hdr || i + size > buf.len() { break; }
        out.push((typ, &buf[i + hdr..i + size]));
        i = (i + size + 3) & !3;
    }
    out
}

impl Unpacker {
    fn walk_sections(&mut self, buf: &[u8], guid: &str) {
        for (typ, body) in sections(buf) {
            match typ {
                0x15 => {
                    let rec = self.files.get_mut(guid).unwrap();
                    if rec.name.is_none() {
                        let u: Vec<u16> = body.chunks_exact(2).map(|c| u16::from_le_bytes([c[0], c[1]])).collect();
                        rec.name = Some(String::from_utf16_lossy(&u).trim_end_matches('\0').to_string());
                    }
                }
                0x10 => self.files.get_mut(guid).unwrap().set("pe32.efi", body),
                0x12 => self.files.get_mut(guid).unwrap().set("te.efi", body),
                0x13 => self.files.get_mut(guid).unwrap().set("depex.bin", body),
                0x19 => self.files.get_mut(guid).unwrap().set("raw.bin", body),
                0x17 => self.walk_fv(body),
                0x02 if body.len() >= 20 => {
                    let off = u16::from_le_bytes([body[16], body[17]]) as isize - 4;
                    let data = if off > 0 { &body[off as usize..] } else { &body[20..] };
                    let mut dec = Vec::new();
                    if body[..16] == GZIP_GUID {
                        if GzDecoder::new(data).read_to_end(&mut dec).is_ok() { self.walk_sections(&dec, guid) }
                    } else if body[..16] == LZMA_GUID {
                        if lzma_rs::lzma_decompress(&mut std::io::Cursor::new(data), &mut dec).is_ok() { self.walk_sections(&dec, guid) }
                    }
                }
                0x01 if body.len() >= 5 && body[4] == 0 => self.walk_sections(&body[5..], guid),
                _ => {}
            }
        }
    }

    fn walk_fv(&mut self, fv: &[u8]) {
        if fv.len() < 56 || &fv[40..44] != b"_FVH" { return; }
        let flen = u64::from_le_bytes(fv[32..40].try_into().unwrap()) as usize;
        let mut i = u16::from_le_bytes([fv[48], fv[49]]) as usize;
        let ext = u16::from_le_bytes([fv[52], fv[53]]) as usize;
        if ext != 0 && ext + 20 <= fv.len() {
            i = ext + u32::from_le_bytes(fv[ext + 16..ext + 20].try_into().unwrap()) as usize;
        }
        let end = flen.min(fv.len());
        while i + 24 <= end {
            i = (i + 7) & !7;
            if i + 24 > fv.len() || fv[i..i + 24].iter().all(|&b| b == 0xff) { break; }
            let guid = guid_str(&fv[i..i + 16]);
            let (ftype, attr) = (fv[i + 18], fv[i + 19]);
            let (mut size, mut hdr) = (u32::from_le_bytes([fv[i + 20], fv[i + 21], fv[i + 22], 0]) as usize, 24);
            if attr & 1 != 0 {
                size = u64::from_le_bytes(fv[i + 24..i + 32].try_into().unwrap()) as usize;
                hdr = 32;
            }
            if size < hdr { break; }
            let body = &fv[(i + hdr).min(fv.len())..(i + size).min(fv.len())];
            if ftype != 0xf0 {
                if !self.files.contains_key(&guid) {
                    self.order.push(guid.clone());
                    self.files.insert(guid.clone(), Rec { ftype, ..Default::default() });
                }
                if (0x02..=0x0f).contains(&ftype) {
                    self.walk_sections(body, &guid);
                } else {
                    self.files.get_mut(&guid).unwrap().set("file.bin", body);
                }
            }
            i += size;
        }
    }
}

pub fn run(image: &Path, outdir: &Path) -> Result<()> {
    let data = fs::read(image)?;
    let mut u = Unpacker::default();
    let mut i = 0;
    while let Some(p) = data[i..].windows(4).position(|w| w == b"_FVH") {
        let at = i + p;
        if at >= 40 { u.walk_fv(&data[at - 40..]); }
        i = at + 4;
    }
    fs::create_dir_all(outdir)?;
    let mut order = u.order.clone();
    order.sort_by(|a, b| {
        let na = u.files[a].name.clone().unwrap_or_else(|| "~".into());
        let nb = u.files[b].name.clone().unwrap_or_else(|| "~".into());
        na.cmp(&nb)
    });
    let mut idx = String::new();
    let (mut named, mut code) = (0, 0);
    for g in &order {
        let r = &u.files[g];
        let d = outdir.join(g);
        fs::create_dir_all(&d)?;
        fs::write(d.join("type.txt"), format!("{:#04x}\n", r.ftype))?;
        if let Some(n) = &r.name { fs::write(d.join("name.txt"), format!("{n}\n"))?; named += 1; }
        for (k, v) in &r.secs { fs::write(d.join(k), v)?; }
        if r.secs.iter().any(|(k, _)| *k == "pe32.efi" || *k == "te.efi") { code += 1; }
        let secs: Vec<&str> = r.secs.iter().map(|(k, _)| *k).collect();
        idx += &format!("{g}\t{:#04x}\t{}\t{}\n", r.ftype, r.name.as_deref().unwrap_or(""), secs.join(","));
    }
    fs::write(outdir.join("index.tsv"), idx)?;
    println!("{} files, {named} named, {code} with code -> {}", order.len(), outdir.display());
    Ok(())
}
