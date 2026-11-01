//! Mi A3 dual boot (docs/laurel_sprout/dual-boot.md): a FIEMAP result -> a validated extent table for XNU (ADT /chosen laurel-dualboot),
//! and the root image -> a frame stream for the phone helper. The table format and every rule are the same as
//! tools/laurel-dualboot/laurel_dualboot.h, which XNU and the helper compile; scripts/laurel/test-dualboot.sh checks one against the other.
//! A wrong table corrupts Android's data, so this code refuses instead of fixing.

use crate::img2simg;
use anyhow::{bail, ensure, Context, Result};
use std::fs::File;
use std::io::{BufReader, BufWriter, Read, Seek, SeekFrom, Write};
use std::path::Path;

const B: u64 = 4096;
const HEADER: usize = 64;
const EXTENT: usize = 24;
pub const MAX_EXTENTS: usize = 4096;
pub const RESERVED_BLOCKS: u64 = 256;
pub const MIN_PART_BLOCK: u64 = 512;
const VERSION: u32 = 1;
const MAGIC: &[u8; 8] = b"LDBTABL1";
const FRAME_MAGIC: &[u8; 8] = b"LDBFRAME";
const FRAME_BLOCKS: u64 = 256;
const FRAME_FLAG_ZERO: u32 = 1;
/// The console log thread takes the end of the BSD disk (sweet_ufs.c SWEET_LOG_BLOCKS): 4 MiB + 4 KiB.
const LOG_BLOCKS: u64 = (4 << 20) / B + 1;

// FIEMAP flags (linux/fiemap.h). Allowed: LAST, DATA_ENCRYPTED (fscrypt: the bytes in the file are not ours to read through the file, the
// raw blocks are), MERGED. Refused: UNKNOWN, DELALLOC, ENCODED, NOT_ALIGNED, DATA_INLINE, DATA_TAIL, UNWRITTEN (no real block), SHARED.
const FIEMAP_ALLOWED: u32 = 0x1 | 0x80 | 0x1000;

pub const HASH_INIT: u64 = 0xcbf29ce484222325;
pub fn hash_add(mut h: u64, data: &[u8]) -> u64 {
    for b in data {
        h = (h ^ *b as u64).wrapping_mul(0x100000001b3);
    }
    h
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Extent {
    pub area_block: u64,
    pub part_block: u64,
    pub blocks: u64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Table {
    pub part_first: u64,
    pub part_blocks: u64,
    pub area_blocks: u64,
    pub table_id: u64,
    pub extents: Vec<Extent>,
}

/// One line of `ldbhelper map`: `extent LOGICAL PHYSICAL LENGTH FLAGS`.
#[derive(Clone, Copy, Debug)]
pub struct Fiemap {
    pub logical: u64,
    pub physical: u64,
    pub length: u64,
    pub flags: u32,
}

pub fn parse_fiemap(text: &str) -> Result<(Vec<Fiemap>, Option<u64>)> {
    let mut out = Vec::new();
    let mut failures = None;
    for (n, line) in text.lines().enumerate() {
        let w: Vec<&str> = line.split_whitespace().collect();
        match w.as_slice() {
            ["extent", l, p, len, f] => out.push(Fiemap {
                logical: l.parse().with_context(|| format!("line {}", n + 1))?,
                physical: p.parse().with_context(|| format!("line {}", n + 1))?,
                length: len.parse().with_context(|| format!("line {}", n + 1))?,
                flags: f.parse().with_context(|| format!("line {}", n + 1))?,
            }),
            ["pin-failures", v] => failures = Some(v.parse().with_context(|| format!("line {}", n + 1))?),
            [] => {}
            _ => bail!("line {}: not an ldbhelper map line: {line}", n + 1),
        }
    }
    Ok((out, failures))
}

/// The rules of laurel_dualboot.h ldb_table_check. None = good.
pub fn check_rules(t: &Table) -> Option<String> {
    if t.part_first == 0 || t.part_blocks == 0 || t.part_first.checked_add(t.part_blocks).is_none() {
        return Some("table has no valid partition".into());
    }
    if t.extents.is_empty() || t.extents.len() > MAX_EXTENTS {
        return Some(format!("{} extents: the limit is 1 to {MAX_EXTENTS} (allocate again on a less used /data)", t.extents.len()));
    }
    if t.area_blocks <= RESERVED_BLOCKS || t.area_blocks > t.part_blocks {
        return Some("area size out of range".into());
    }
    let mut next = 0u64;
    let mut by_part: Vec<&Extent> = t.extents.iter().collect();
    for e in &t.extents {
        if e.blocks == 0 || e.area_block != next {
            return Some(format!("area is not contiguous from block 0 (extent at area block {})", e.area_block));
        }
        match e.part_block.checked_add(e.blocks) {
            Some(end) if e.part_block >= MIN_PART_BLOCK && end <= t.part_blocks => {}
            _ => return Some(format!("extent outside userdata: partition blocks {} + {}", e.part_block, e.blocks)),
        }
        next += e.blocks;
    }
    if next != t.area_blocks {
        return Some(format!("extents give {next} blocks, the area has {}", t.area_blocks));
    }
    by_part.sort_by_key(|e| e.part_block);
    for w in by_part.windows(2) {
        if w[0].part_block + w[0].blocks > w[1].part_block {
            return Some(format!("two extents overlap on the partition at block {}", w[1].part_block));
        }
    }
    None
}

/// FIEMAP -> table. `part_first`, `part_blocks`: userdata in device blocks. FIEMAP's physical is relative to the filesystem device, which
/// starts at userdata block 0 (dual-boot.sh checks dm-default-key's offset 0 before it calls this).
pub fn table_from_fiemap(fm: &[Fiemap], part_first: u64, part_blocks: u64, table_id: u64) -> Result<Table> {
    let mut extents: Vec<Extent> = Vec::new();
    let mut next = 0u64;
    ensure!(!fm.is_empty(), "no extents: the file has no blocks");
    for e in fm {
        ensure!(e.flags & !FIEMAP_ALLOWED == 0, "extent at file offset {}: flags {:#x}: not a plain allocated block", e.logical, e.flags);
        ensure!(e.logical % B == 0 && e.physical % B == 0 && e.length % B == 0 && e.length != 0,
            "extent at file offset {}: not aligned to 4096 bytes (physical {}, length {})", e.logical, e.physical, e.length);
        ensure!(e.logical == next, "hole in the file at offset {next}: the next extent starts at {}", e.logical);
        next = e.logical.checked_add(e.length).context("file offset overflow")?;
        let (a, p, n) = (e.logical / B, e.physical / B, e.length / B);
        match extents.last_mut() {
            Some(l) if l.part_block + l.blocks == p => l.blocks += n,
            _ => extents.push(Extent { area_block: a, part_block: p, blocks: n }),
        }
    }
    let t = Table { part_first, part_blocks, area_blocks: next / B, table_id, extents };
    if let Some(why) = check_rules(&t) {
        bail!("{why}");
    }
    Ok(t)
}

pub fn to_blob(t: &Table) -> Vec<u8> {
    let mut b = Vec::with_capacity(HEADER + t.extents.len() * EXTENT);
    b.extend_from_slice(MAGIC);
    for v in [VERSION, B as u32, t.extents.len() as u32, RESERVED_BLOCKS as u32] {
        b.extend_from_slice(&v.to_le_bytes());
    }
    for v in [t.part_first, t.part_blocks, t.area_blocks, t.table_id, 0] {
        b.extend_from_slice(&v.to_le_bytes());
    }
    for e in &t.extents {
        for v in [e.area_block, e.part_block, e.blocks] {
            b.extend_from_slice(&v.to_le_bytes());
        }
    }
    let h = hash_add(HASH_INIT, &b);
    b[56..64].copy_from_slice(&h.to_le_bytes());
    b
}

fn le32(b: &[u8], o: usize) -> u32 { u32::from_le_bytes(b[o..o + 4].try_into().unwrap()) }
fn le64(b: &[u8], o: usize) -> u64 { u64::from_le_bytes(b[o..o + 8].try_into().unwrap()) }

pub fn from_blob(b: &[u8]) -> Result<Table> {
    ensure!(b.len() >= HEADER && &b[..8] == MAGIC, "no table magic");
    ensure!(le32(b, 8) == VERSION && le32(b, 12) == B as u32 && le32(b, 20) == RESERVED_BLOCKS as u32, "version, block size or reserved size is not this tool's");
    let count = le32(b, 16) as usize;
    ensure!(count <= MAX_EXTENTS && b.len() == HEADER + count * EXTENT, "table length does not match its extent count");
    let mut z = b.to_vec();
    z[56..64].fill(0);
    ensure!(hash_add(HASH_INIT, &z) == le64(b, 56), "table hash wrong");
    let t = Table {
        part_first: le64(b, 24),
        part_blocks: le64(b, 32),
        area_blocks: le64(b, 40),
        table_id: le64(b, 48),
        extents: (0..count).map(|i| {
            let o = HEADER + i * EXTENT;
            Extent { area_block: le64(b, o), part_block: le64(b, o + 8), blocks: le64(b, o + 16) }
        }).collect(),
    };
    if let Some(why) = check_rules(&t) {
        bail!("{why}");
    }
    Ok(t)
}

fn random_id() -> Result<u64> {
    let mut b = [0u8; 8];
    File::open("/dev/urandom")?.read_exact(&mut b)?;
    Ok(u64::from_le_bytes(b))
}

pub fn make(fiemap: &Path, part_first: u64, part_blocks: u64, id: Option<u64>, out: &Path) -> Result<()> {
    let text = std::fs::read_to_string(fiemap).with_context(|| fiemap.display().to_string())?;
    let (fm, failures) = parse_fiemap(&text)?;
    let t = table_from_fiemap(&fm, part_first, part_blocks, match id { Some(i) => i, None => random_id()? })?;
    std::fs::write(out, to_blob(&t))?;
    summary(&t);
    if let Some(f) = failures {
        println!("pin failures {f}");
    }
    Ok(())
}

fn summary(t: &Table) {
    let smallest = t.extents.iter().map(|e| e.blocks).min().unwrap_or(0);
    println!("table ok: {} extents, area {} MiB ({} blocks), root disk {} MiB, userdata LBA {} + {} blocks, id {:016x}, smallest extent {} KiB",
        t.extents.len(), t.area_blocks >> 8, t.area_blocks, (t.area_blocks - RESERVED_BLOCKS) >> 8,
        t.part_first, t.part_blocks, t.table_id, smallest * 4);
}

pub fn check(path: &Path) -> Result<()> {
    summary(&from_blob(&std::fs::read(path)?)?);
    Ok(())
}

pub fn show(path: &Path) -> Result<()> {
    let t = from_blob(&std::fs::read(path)?)?;
    summary(&t);
    for e in &t.extents {
        println!("area {:>10} -> part {:>10} (LBA {:>10}), {} blocks", e.area_block, e.part_block, t.part_first + e.part_block, e.blocks);
    }
    Ok(())
}

/// Bytes of the HFS+ volume this area can hold.
pub fn usable_bytes(t: &Table) -> u64 {
    (t.area_blocks - RESERVED_BLOCKS).saturating_sub(LOG_BLOCKS) * B
}

fn frame_header(area_block: u64, blocks: u32, flags: u32, hash: u64) -> [u8; 32] {
    let mut h = [0u8; 32];
    h[..8].copy_from_slice(FRAME_MAGIC);
    h[8..16].copy_from_slice(&area_block.to_le_bytes());
    h[16..20].copy_from_slice(&blocks.to_le_bytes());
    h[20..24].copy_from_slice(&flags.to_le_bytes());
    h[24..32].copy_from_slice(&hash.to_le_bytes());
    h
}

/// Which image blocks must reach the phone, as (first block, block count, read from the file?). The same classes as img2simg: file data is
/// sent; a hole in a block the HFS+ bitmap marks as in use is zero file data and must be written as zeros (the 2026-10-27 lesson); other holes stay.
pub fn plan(f: &mut File, size: u64) -> Result<Vec<(u64, u64, bool)>> {
    let data = img2simg::data_ranges(f, size);
    let alloc = img2simg::hfs_allocated(f)?;
    let is_alloc = |b: u64| alloc.as_ref().is_some_and(|(map, total)| b < *total && map.get((b / 8) as usize).is_some_and(|x| x & (0x80 >> (b % 8)) != 0));
    let blocks = size.div_ceil(B);
    let mut out: Vec<(u64, u64, bool)> = Vec::new();
    let mut push = |b: u64, n: u64, d: bool| {
        if n == 0 { return; }
        match out.last_mut() {
            Some((s, c, k)) if *k == d && *s + *c == b => *c += n,
            _ => out.push((b, n, d)),
        }
    };
    let mut at = 0u64;
    for (s, e) in data.iter().map(|(s, e)| (s / B, e.div_ceil(B))) {
        for b in at..s { if is_alloc(b) { push(b, 1, false); } }
        push(s, e - s, true);
        at = e;
    }
    for b in at..blocks { if is_alloc(b) { push(b, 1, false); } }
    Ok(out)
}

/// The image as frames on stdout (or `--null`): for `adb exec-in ldbhelper write`. `--index FILE`: the frame headers, for `ldbhelper verify`.
pub fn stream(table: &Path, image: &Path, index: Option<&Path>, null: bool) -> Result<()> {
    let t = from_blob(&std::fs::read(table)?)?;
    let mut f = File::open(image).with_context(|| image.display().to_string())?;
    let size = f.metadata()?.len();
    ensure!(size % B == 0, "image size {size} is not a multiple of 4096");
    let usable = usable_bytes(&t);
    ensure!(size <= usable, "image {size} bytes, the area holds {usable} bytes (area minus header and console log): allocate a bigger file or build the root smaller (SIZE=)");
    let mut h = [0u8; 512];
    f.seek(SeekFrom::Start(1024))?;
    f.read_exact(&mut h)?;
    ensure!(&h[..2] == b"HX" || &h[..2] == b"H+", "image has no HFS+ volume header");
    let vol = u32::from_be_bytes(h[40..44].try_into().unwrap()) as u64 * u32::from_be_bytes(h[44..48].try_into().unwrap()) as u64;
    ensure!(vol <= usable, "HFS+ volume {vol} bytes, the area holds {usable} bytes");
    let ranges = plan(&mut f, size)?;
    let mut rd = BufReader::with_capacity(4 << 20, f);
    let stdout = std::io::stdout();
    let mut w = BufWriter::with_capacity(4 << 20, stdout.lock());
    let mut idx = index.map(File::create).transpose()?.map(BufWriter::new);
    let mut buf = vec![0u8; (FRAME_BLOCKS * B) as usize];
    let zero_hash = {
        let mut z = vec![HASH_INIT; FRAME_BLOCKS as usize + 1];
        for i in 1..=FRAME_BLOCKS as usize { z[i] = hash_add(z[i - 1], &[0u8; B as usize]); }
        z
    };
    let (mut frames, mut blocks_sent) = (0u64, 0u64);
    for (start, count, is_data) in ranges {
        let mut b = start;
        let end = start + count;
        if is_data { rd.seek(SeekFrom::Start(start * B))?; }
        while b < end {
            let n = (end - b).min(FRAME_BLOCKS);
            let area = b + RESERVED_BLOCKS;
            let hdr;
            if is_data {
                rd.read_exact(&mut buf[..(n * B) as usize])?;
                hdr = frame_header(area, n as u32, 0, hash_add(HASH_INIT, &buf[..(n * B) as usize]));
                if !null { w.write_all(&hdr)?; w.write_all(&buf[..(n * B) as usize])?; }
            } else {
                hdr = frame_header(area, n as u32, FRAME_FLAG_ZERO, zero_hash[n as usize]);
                if !null { w.write_all(&hdr)?; }
            }
            if let Some(i) = idx.as_mut() { i.write_all(&hdr)?; }
            frames += 1;
            blocks_sent += n;
            b += n;
        }
    }
    let end = frame_header(0, 0, 0, 0);
    if !null { w.write_all(&end)?; }
    w.flush()?;
    if let Some(i) = idx.as_mut() { i.write_all(&end)?; i.flush()?; }
    eprintln!("stream: {frames} frames, {} MiB of {} MiB image", blocks_sent >> 8, size >> 20);
    Ok(())
}

/// Size of the area to allocate. donor = decrypted image bytes when known, else the encrypted size; expand = root bytes per donor byte, measured
/// on the iOS 16 root; var = margin for /private/var and updates in place; the header and the console log come on top.
pub fn size_plan(donor: &[u64], expand: f64, var_gib: u64) -> (u64, u64, u64) {
    let total: u64 = donor.iter().sum();
    let root = (total as f64 * expand).ceil() as u64;
    let hfs = root + (var_gib << 30);
    // whole GiB: the f2fs allocation unit is 2 MiB, but the HFS+ volume size is a build parameter given in GiB
    let hfs_gib = hfs.div_ceil(1 << 30);
    let area = (hfs_gib << 30) + (RESERVED_BLOCKS + LOG_BLOCKS) * B;
    (root, hfs_gib, area.div_ceil(2 << 20) * (2 << 20))
}

/// The largest HFS+ volume in an area of this many GiB: the area without the 1 MiB header blocks and the console log. The table is not in the area: it is in the ADT.
pub fn volume_in_area(area_gib: u64) -> u64 {
    ((area_gib << 30) / B - RESERVED_BLOCKS - LOG_BLOCKS) * B
}

pub fn size(donor: &[u64], expand: f64, var_gib: u64, area_gib: Option<u64>) -> Result<()> {
    ensure!(!donor.is_empty() && expand >= 1.0, "give --donor-bytes and an --expand of at least 1");
    let (root, hfs_gib, area) = size_plan(donor, expand, var_gib);
    if let Some(a) = area_gib {
        let v = volume_in_area(a);
        println!("area {a} GiB = {} bytes: {RESERVED_BLOCKS} header blocks, {LOG_BLOCKS} log blocks -> HFS+ volume {v} bytes (SIZE={v})", a << 30);
        println!("root files about {:.1} GiB ({} donor images x {expand}); /private/var gets the rest of the volume, about {:.1} GiB [I]", root as f64 / (1u64 << 30) as f64, donor.len(), (v.saturating_sub(root)) as f64 / (1u64 << 30) as f64);
        ensure!(v >= root + (var_gib << 30), "{a} GiB does not hold the root and {var_gib} GiB for /private/var");
        return Ok(());
    }
    println!("root files about {:.1} GiB ({} donor images x {expand}), + {var_gib} GiB for /private/var -> HFS+ volume SIZE={hfs_gib}G", root as f64 / (1u64 << 30) as f64, donor.len());
    println!("area bytes {area} ({:.2} GiB): volume + 1 MiB header + 4 MiB console log, whole f2fs segments", area as f64 / (1u64 << 30) as f64);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    const PF: u64 = 0x1000;
    const PB: u64 = 28_000_000;

    fn fm(l: u64, p: u64, n: u64) -> Fiemap { Fiemap { logical: l * B, physical: p * B, length: n * B, flags: 0 } }
    fn good() -> Vec<Fiemap> { vec![fm(0, 1000, 500), fm(500, 5000, 300), fm(800, 2000, 200)] }

    #[test]
    fn makes_a_table_and_merges_neighbours() {
        let t = table_from_fiemap(&good(), PF, PB, 7).unwrap();
        assert_eq!(t.extents.len(), 3);
        assert_eq!(t.area_blocks, 1000);
        let m = table_from_fiemap(&[fm(0, 1000, 512), fm(512, 1512, 512)], PF, PB, 7).unwrap();
        assert_eq!(m.extents, vec![Extent { area_block: 0, part_block: 1000, blocks: 1024 }]);
    }
    #[test]
    fn blob_round_trip() {
        let t = table_from_fiemap(&good(), PF, PB, 0xabc).unwrap();
        let b = to_blob(&t);
        assert_eq!(b.len(), HEADER + 3 * EXTENT);
        assert_eq!(from_blob(&b).unwrap(), t);
    }
    #[test]
    fn blob_damage_is_refused() {
        let b = to_blob(&table_from_fiemap(&good(), PF, PB, 1).unwrap());
        for i in 0..b.len() {
            let mut c = b.clone();
            c[i] ^= 0x40;
            assert!(from_blob(&c).is_err(), "byte {i}");
        }
        assert!(from_blob(&b[..b.len() - 1]).is_err());
        assert!(from_blob(&[]).is_err());
    }
    #[test]
    fn refuses_overlap() {
        let e = table_from_fiemap(&[fm(0, 1000, 500), fm(500, 1400, 500)], PF, PB, 1).unwrap_err().to_string();
        assert!(e.contains("overlap"), "{e}");
        let e = table_from_fiemap(&[fm(0, 2000, 500), fm(500, 1000, 1001)], PF, PB, 1).unwrap_err().to_string();
        assert!(e.contains("overlap"), "{e}");
    }
    #[test]
    fn refuses_misalignment() {
        for f in [Fiemap { logical: 0, physical: 4097, length: 8192, flags: 0 },
                  Fiemap { logical: 0, physical: 4096 * 1000, length: 8191, flags: 0 },
                  Fiemap { logical: 512, physical: 4096 * 1000, length: 8192, flags: 0 }] {
            let e = table_from_fiemap(&[f], PF, PB, 1).unwrap_err().to_string();
            assert!(e.contains("aligned"), "{e}");
        }
    }
    #[test]
    fn refuses_outside_userdata() {
        assert!(table_from_fiemap(&[fm(0, PB - 100, 1000)], PF, PB, 1).unwrap_err().to_string().contains("outside"));
        assert!(table_from_fiemap(&[fm(0, PB, 1000)], PF, PB, 1).unwrap_err().to_string().contains("outside"));
        // f2fs metadata at the start of the partition
        assert!(table_from_fiemap(&[fm(0, 511, 1000)], PF, PB, 1).unwrap_err().to_string().contains("outside"));
        // u64 wrap
        let e = table_from_fiemap(&[Fiemap { logical: 0, physical: (u64::MAX / B) * B, length: 4096 * 1000, flags: 0 }], PF, PB, 1).unwrap_err().to_string();
        assert!(e.contains("outside"), "{e}");
    }
    #[test]
    fn refuses_holes_and_flags_and_too_small() {
        assert!(table_from_fiemap(&[fm(0, 1000, 500), fm(501, 3000, 500)], PF, PB, 1).unwrap_err().to_string().contains("hole"));
        assert!(table_from_fiemap(&[fm(1, 1000, 500)], PF, PB, 1).unwrap_err().to_string().contains("hole"));
        assert!(table_from_fiemap(&[], PF, PB, 1).is_err());
        for flags in [0x2u32, 0x4, 0x8, 0x100, 0x200, 0x400, 0x800, 0x2000] {
            let mut e = fm(0, 1000, 1000);
            e.flags = flags;
            assert!(table_from_fiemap(&[e], PF, PB, 1).unwrap_err().to_string().contains("flags"), "{flags:#x}");
        }
        assert!(table_from_fiemap(&[fm(0, 1000, RESERVED_BLOCKS)], PF, PB, 1).unwrap_err().to_string().contains("area size"));
    }
    #[test]
    fn refuses_too_many_extents() {
        let many: Vec<Fiemap> = (0..=MAX_EXTENTS as u64).map(|i| fm(i * 2, 1000 + i * 4, 2)).collect();
        assert!(table_from_fiemap(&many, PF, PB, 1).unwrap_err().to_string().contains("limit"));
        let ok: Vec<Fiemap> = (0..MAX_EXTENTS as u64).map(|i| fm(i * 2, 1000 + i * 4, 2)).collect();
        let t = table_from_fiemap(&ok, PF, PB, 1).unwrap();
        assert_eq!(from_blob(&to_blob(&t)).unwrap(), t);
    }
    #[test]
    fn parses_helper_output() {
        let (f, p) = parse_fiemap("pin-failures 3\nextent 0 4096000 8192 1\n\n").unwrap();
        assert_eq!(p, Some(3));
        assert_eq!(f.len(), 1);
        assert_eq!(f[0].flags, 1);
        assert!(parse_fiemap("garbage line\n").is_err());
        assert!(parse_fiemap("extent 0 x 8192 1\n").is_err());
    }
    #[test]
    fn size_plan_ios26_donor() {
        // owner's donor, iPhone12,1 23F84, decrypted sizes on disk 2026-11-02 (OS, SystemOS, AppOS); 1.68 x as measured on the iOS 16 root; 8 GiB margin
        let (_root, hfs, area) = size_plan(&[8409579520, 5221908480, 14680064], 1.68, 8);
        assert_eq!(hfs, 30);
        assert_eq!(area % (2 << 20), 0);
        assert!(area >= (30 << 30) + (256 + 1025) * 4096);
        assert!(area < (31 << 30));
        // bigger margin, bigger area: the parameter works
        assert!(size_plan(&[1 << 30], 1.5, 16).1 > size_plan(&[1 << 30], 1.5, 8).1);
    }
    #[test]
    fn owner_area_32_gib() {
        // owner decision: 32 GiB; 256 header + 1025 log blocks of 4096 bytes come off
        assert_eq!(volume_in_area(32), (32u64 << 30) - (256 + 1025) * 4096);
        assert_eq!(volume_in_area(32), 34354491392);
        assert_eq!(volume_in_area(32) % 4096, 0);
    }
    #[test]
    fn usable_excludes_header_and_log() {
        let t = table_from_fiemap(&[fm(0, 1000, 100_000)], PF, PB, 1).unwrap();
        assert_eq!(usable_bytes(&t), (100_000 - 256 - 1025) * 4096);
    }
}
