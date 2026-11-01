//! Mi A3 dual boot: the one GPT change on LUN 0 (docs/laurel_sprout/dual-boot.md).
//!
//! `userdata` shrinks to 70 % of its blocks, keeping start, type GUID, unique GUID and attributes. A new last entry `iosroot` takes the rest, from a 2 MiB
//! boundary up to the last usable block. Every other byte of the table stays. Input: dumps of the first and last 1 MiB of /dev/block/sda, in the format
//! of the backup (gpt-sda-head.bin, gpt-sda-tail.bin): 256 blocks each. Everything here works on files and needs no phone. No GPT bytes are in git: the
//! test on the real layout reads the backup folder.
//!
//! The plan is a file for `ldbhelper gpt-write`: which blocks change, their bytes before and after, in the order that keeps a valid table at each moment.
use anyhow::{bail, ensure, Context, Result};
use sha2::{Digest, Sha256};
use std::fs;
use std::path::Path;

pub const BLOCK: u64 = 4096;
const SLOTS: usize = 32;
const ESZ: usize = 128;
const DUMP_BLOCKS: u64 = 256;
pub const DISK_BLOCKS: u64 = 30119936;
const ALT_LBA: u64 = DISK_BLOCKS - 1;
const FIRST_USABLE: u64 = 6;
const LAST_USABLE: u64 = 30119930;
const BACKUP_ENTRIES_LBA: u64 = 30119931;
const USERDATA_FIRST: u64 = 1831432;
const METADATA: (u64, u64) = (1827336, 1831431);
/// the partition's first two blocks hold the two f2fs superblock copies
const SB_BLOCKS: u32 = 2;
const ALIGN: u64 = 512; // 2 MiB in blocks
pub const SHARE_PERCENT: u64 = 70;
const NAMES: [&str; 15] = [
    "ssd", "persist", "misc", "keystore", "frp", "product_a", "product_b", "odm_a", "odm_b", "oem", "minidump", "system_a", "system_b", "metadata", "userdata",
];
/// Apple HFS+ type GUID, as it lies on disk (48465300-0000-11AA-AA11-00306543ECAC). No Android tool looks at it.
const IOSROOT_TYPE: [u8; 16] = [0x00, 0x53, 0x46, 0x48, 0x00, 0x00, 0xAA, 0x11, 0xAA, 0x11, 0x00, 0x30, 0x65, 0x43, 0xEC, 0xAC];
const LOG_BLOCKS: u64 = 1025; // console log at the end of the partition: bsd/dev/sweet_ufs.c SWEET_LOG_BLOCKS

const KIND_REPLACE: u32 = 1;
const KIND_ZERO: u32 = 2;

#[derive(Clone, Copy, PartialEq, Debug)]
pub struct Layout {
    pub userdata_last: u64,
    pub iosroot_first: u64,
    pub iosroot_last: u64,
}

impl Layout {
    pub fn new() -> Layout {
        let blocks = LAST_USABLE - USERDATA_FIRST + 1;
        let keep = blocks * SHARE_PERCENT / 100;
        let iosroot_first = (USERDATA_FIRST + keep).div_ceil(ALIGN) * ALIGN;
        Layout { userdata_last: iosroot_first - 1, iosroot_first, iosroot_last: LAST_USABLE }
    }
    pub fn iosroot_blocks(&self) -> u64 {
        self.iosroot_last - self.iosroot_first + 1
    }
}

/// One copy of the table as it lies on disk.
pub struct Table {
    mbr: Vec<u8>,
    hdr: Vec<u8>,
    entries: Vec<u8>,
    bhdr: Vec<u8>,
    bentries: Vec<u8>,
}

fn crc(d: &[u8]) -> u32 {
    let mut h = crc32fast::Hasher::new();
    h.update(d);
    h.finalize()
}
fn u32_at(b: &[u8], o: usize) -> u32 {
    u32::from_le_bytes(b[o..o + 4].try_into().unwrap())
}
fn u64_at(b: &[u8], o: usize) -> u64 {
    u64::from_le_bytes(b[o..o + 8].try_into().unwrap())
}
fn hdr_crc(h: &[u8]) -> u32 {
    let mut c = h[..92].to_vec();
    c[16..20].fill(0);
    crc(&c)
}
fn name_of(e: &[u8]) -> String {
    let u: Vec<u16> = e[56..128].chunks(2).map(|c| u16::from_le_bytes([c[0], c[1]])).take_while(|c| *c != 0).collect();
    String::from_utf16_lossy(&u)
}
fn range_of(e: &[u8]) -> (u64, u64) {
    (u64_at(e, 32), u64_at(e, 40))
}

fn read_dumps(head: &Path, tail: &Path) -> Result<Table> {
    let h = fs::read(head).with_context(|| format!("{}", head.display()))?;
    let t = fs::read(tail).with_context(|| format!("{}", tail.display()))?;
    ensure!(h.len() as u64 == DUMP_BLOCKS * BLOCK, "{}: {} bytes, a dump has {}", head.display(), h.len(), DUMP_BLOCKS * BLOCK);
    ensure!(t.len() as u64 == DUMP_BLOCKS * BLOCK, "{}: {} bytes, a dump has {}", tail.display(), t.len(), DUMP_BLOCKS * BLOCK);
    let b = BLOCK as usize;
    let tail_lba = |lba: u64| ((lba - (DISK_BLOCKS - DUMP_BLOCKS)) * BLOCK) as usize;
    Ok(Table {
        mbr: h[..b].to_vec(),
        hdr: h[b..2 * b].to_vec(),
        entries: h[2 * b..6 * b].to_vec(),
        bhdr: t[tail_lba(ALT_LBA)..tail_lba(ALT_LBA) + b].to_vec(),
        bentries: t[tail_lba(BACKUP_ENTRIES_LBA)..tail_lba(BACKUP_ENTRIES_LBA) + 4 * b].to_vec(),
    })
}

/// The fields both header copies must have, in any state of this plan.
fn check_headers(t: &Table) -> Result<()> {
    for (what, h, cur, alt, pe, ent) in [("primary", &t.hdr, 1, ALT_LBA, 2, &t.entries), ("backup", &t.bhdr, ALT_LBA, 1, BACKUP_ENTRIES_LBA, &t.bentries)] {
        ensure!(&h[..8] == b"EFI PART", "{what} header has no signature");
        ensure!(u32_at(h, 8) == 0x10000 && u32_at(h, 12) == 92, "{what} header: revision or size is not the expected one");
        ensure!(u32_at(h, 16) == hdr_crc(h), "{what} header CRC is wrong");
        ensure!(u64_at(h, 24) == cur && u64_at(h, 32) == alt, "{what} header: LBA {} and {}, expected {cur} and {alt}", u64_at(h, 24), u64_at(h, 32));
        ensure!(u64_at(h, 40) == FIRST_USABLE && u64_at(h, 48) == LAST_USABLE, "{what} header: usable {}..{}, expected {FIRST_USABLE}..{LAST_USABLE}", u64_at(h, 40), u64_at(h, 48));
        ensure!(u64_at(h, 72) == pe, "{what} header: entries at LBA {}, expected {pe}", u64_at(h, 72));
        ensure!(u32_at(h, 80) as usize == SLOTS && u32_at(h, 84) as usize == ESZ, "{what} header: {} slots of {} bytes, expected {SLOTS} of {ESZ}", u32_at(h, 80), u32_at(h, 84));
        ensure!(u32_at(h, 88) == crc(&ent[..SLOTS * ESZ]), "{what} entries CRC is wrong");
        ensure!(h[92..].iter().all(|x| *x == 0), "{what} header block: bytes after the header are not zero");
        ensure!(ent[SLOTS * ESZ..].iter().all(|x| *x == 0), "{what} entries: the rest of the 16 KiB is not zero");
    }
    ensure!(t.hdr[56..72] == t.bhdr[56..72], "the disk GUIDs of the two headers differ");
    ensure!(t.entries == t.bentries, "the entries of the two copies differ");
    ensure!(t.mbr[510..512] == [0x55, 0xaa] && t.mbr[450] == 0xee, "no protective MBR");
    Ok(())
}

fn check_old(t: &Table) -> Result<()> {
    check_headers(t)?;
    for (i, n) in NAMES.iter().enumerate() {
        let e = &t.entries[i * ESZ..(i + 1) * ESZ];
        ensure!(name_of(e) == *n, "slot {i} is '{}', expected '{n}'", name_of(e));
    }
    ensure!(t.entries[NAMES.len() * ESZ..SLOTS * ESZ].iter().all(|x| *x == 0), "a slot after 'userdata' is not empty: this table already has another entry");
    let m = &t.entries[13 * ESZ..14 * ESZ];
    ensure!(range_of(m) == METADATA, "metadata is {:?}, expected {:?}", range_of(m), METADATA);
    let u = &t.entries[14 * ESZ..15 * ESZ];
    ensure!(range_of(u) == (USERDATA_FIRST, LAST_USABLE), "userdata is {:?}, expected {:?}: not the layout this plan knows", range_of(u), (USERDATA_FIRST, LAST_USABLE));
    ensure!(u64_at(u, 48) == 0, "userdata has attributes {:#x}, expected 0", u64_at(u, 48));
    let mut last = FIRST_USABLE - 1;
    for i in 0..NAMES.len() {
        let (a, b) = range_of(&t.entries[i * ESZ..(i + 1) * ESZ]);
        ensure!(a == last + 1 && b >= a, "slot {i} ({}) is {a}..{b}: not contiguous", NAMES[i]);
        last = b;
    }
    Ok(())
}

/// The table after the change, and every rule on it. Takes the old table as well: all other bytes must be the same.
fn check_new(n: &Table, old: &Table, l: Layout) -> Result<()> {
    check_headers(n)?;
    ensure!(n.mbr == old.mbr, "the MBR changed");
    ensure!(n.hdr[56..72] == old.hdr[56..72], "the disk GUID changed");
    for i in 0..14 {
        ensure!(n.entries[i * ESZ..(i + 1) * ESZ] == old.entries[i * ESZ..(i + 1) * ESZ], "entry {i} ({}) changed", NAMES[i]);
    }
    let (ou, nu) = (&old.entries[14 * ESZ..15 * ESZ], &n.entries[14 * ESZ..15 * ESZ]);
    ensure!(ou[..32] == nu[..32], "userdata: type or unique GUID changed");
    ensure!(ou[48..] == nu[48..], "userdata: attributes or name changed");
    ensure!(range_of(nu) == (USERDATA_FIRST, l.userdata_last), "userdata is {:?}", range_of(nu));
    let i = &n.entries[15 * ESZ..16 * ESZ];
    ensure!(name_of(i) == "iosroot", "slot 15 is '{}'", name_of(i));
    ensure!(range_of(i) == (l.iosroot_first, l.iosroot_last), "iosroot is {:?}", range_of(i));
    ensure!(l.iosroot_first % ALIGN == 0, "iosroot starts at {}, not on 2 MiB", l.iosroot_first);
    ensure!(l.iosroot_first == l.userdata_last + 1 && l.iosroot_last == LAST_USABLE, "gap or overlap");
    ensure!(u64_at(i, 48) == 0, "iosroot has attributes");
    ensure!(n.entries[16 * ESZ..SLOTS * ESZ].iter().all(|x| *x == 0), "a slot after iosroot is not empty");
    Ok(())
}

fn fix_crcs(t: &mut Table) {
    let c = crc(&t.entries[..SLOTS * ESZ]);
    for h in [&mut t.hdr, &mut t.bhdr] {
        h[88..92].copy_from_slice(&c.to_le_bytes());
        let hc = hdr_crc(h);
        h[16..20].copy_from_slice(&hc.to_le_bytes());
    }
}

fn apply(old: &Table, l: Layout) -> Table {
    let mut e = old.entries.clone();
    e[14 * ESZ + 40..14 * ESZ + 48].copy_from_slice(&l.userdata_last.to_le_bytes());
    let s = &mut e[15 * ESZ..16 * ESZ];
    s[..16].copy_from_slice(&IOSROOT_TYPE);
    // unique GUID: the same disk gives the same plan; version 4 style bits
    let g = Sha256::digest([b"laurel iosroot".as_slice(), &old.hdr[56..72]].concat());
    s[16..32].copy_from_slice(&g[..16]);
    s[16 + 7] = (s[16 + 7] & 0x0f) | 0x40;
    s[16 + 8] = (s[16 + 8] & 0x3f) | 0x80;
    s[32..40].copy_from_slice(&l.iosroot_first.to_le_bytes());
    s[40..48].copy_from_slice(&l.iosroot_last.to_le_bytes());
    for (i, c) in "iosroot".encode_utf16().enumerate() {
        s[56 + 2 * i..58 + 2 * i].copy_from_slice(&c.to_le_bytes());
    }
    let mut t = Table { mbr: old.mbr.clone(), hdr: old.hdr.clone(), entries: e.clone(), bhdr: old.bhdr.clone(), bentries: e };
    fix_crcs(&mut t);
    t
}

/// FNV-1a 64, the same as laurel_dualboot.h: finds a damaged plan file, not an attacker.
fn fnv(d: &[u8]) -> u64 {
    let mut h = 0xcbf29ce484222325u64;
    for x in d {
        h = (h ^ *x as u64).wrapping_mul(0x100000001b3);
    }
    h
}

/// Plan format: "LDBPLAN1", u64 disk blocks, u32 steps, u32 0, u64 FNV of all that follows; each step: u64 LBA, u32 blocks, u32 kind, then old + new bytes (kind 1),
/// nothing (kind 2: zero these blocks). The order is the one the helper runs:
///   1, 2  backup entries, backup header: they prove that this device takes writes, and while the primary is valid nothing reads the backup
///   3     zero the old f2fs superblocks of userdata: when the new table is valid, no old superblock exists
///   4     primary header + entries in ONE write command: LBA 1, 2. Up to here the old table rules; after it the new one
pub fn plan_bytes(from: &Table, to: &Table) -> Vec<u8> {
    let b = BLOCK as usize;
    let mut body = Vec::new();
    let mut steps = 0u32;
    let mut step = |lba: u64, blocks: u32, kind: u32, bytes: &[&[u8]]| {
        body.extend_from_slice(&lba.to_le_bytes());
        body.extend_from_slice(&blocks.to_le_bytes());
        body.extend_from_slice(&kind.to_le_bytes());
        for x in bytes {
            body.extend_from_slice(x);
        }
        steps += 1;
    };
    step(BACKUP_ENTRIES_LBA, 1, KIND_REPLACE, &[&from.bentries[..b], &to.bentries[..b]]);
    step(ALT_LBA, 1, KIND_REPLACE, &[&from.bhdr, &to.bhdr]);
    step(USERDATA_FIRST, SB_BLOCKS, KIND_ZERO, &[]);
    step(1, 2, KIND_REPLACE, &[&from.hdr, &from.entries[..b], &to.hdr, &to.entries[..b]]);
    let mut o = Vec::with_capacity(body.len() + 32);
    o.extend_from_slice(b"LDBPLAN1");
    o.extend_from_slice(&DISK_BLOCKS.to_le_bytes());
    o.extend_from_slice(&steps.to_le_bytes());
    o.extend_from_slice(&0u32.to_le_bytes());
    o.extend_from_slice(&fnv(&body).to_le_bytes());
    o.extend_from_slice(&body);
    o
}

fn print_table(t: &Table, title: &str) {
    println!("{title}");
    for i in 0..SLOTS {
        let e = &t.entries[i * ESZ..(i + 1) * ESZ];
        if e[..16].iter().all(|x| *x == 0) {
            continue;
        }
        let (a, b) = range_of(e);
        println!("  {:2} {:12} {:>9}..{:<9} {:>12} bytes attr {:#x}", i + 1, name_of(e), a, b, (b - a + 1) * BLOCK, u64_at(e, 48));
    }
    println!("  primary header CRC {:#010x}, backup header CRC {:#010x}, entries CRC {:#010x}", u32_at(&t.hdr, 16), u32_at(&t.bhdr, 16), u32_at(&t.hdr, 88));
}

/// `gpt plan`: from dumps of the expected old table, the plan file. Prints both tables and the numbers. --reverse: the plan back from the new table to the old one.
pub fn plan(head: &Path, tail: &Path, out: &Path, reverse: bool) -> Result<()> {
    let old = read_dumps(head, tail)?;
    check_old(&old)?;
    let l = Layout::new();
    let new = apply(&old, l);
    check_new(&new, &old, l)?;
    print_table(&old, "before:");
    print_table(&new, "after:");
    let total = (LAST_USABLE - USERDATA_FIRST + 1) * BLOCK;
    println!("userdata {} -> {} bytes ({:.2} % of the old size)", total, (l.userdata_last - USERDATA_FIRST + 1) * BLOCK, (l.userdata_last - USERDATA_FIRST + 1) as f64 * BLOCK as f64 * 100.0 / total as f64);
    println!("IOSROOT_FIRST={} IOSROOT_LAST={} IOSROOT_BYTES={} IOSROOT_VOLUME_MAX={} USERDATA_LAST={}", l.iosroot_first, l.iosroot_last, l.iosroot_blocks() * BLOCK, (l.iosroot_blocks() - LOG_BLOCKS) * BLOCK, l.userdata_last);
    let p = if reverse { plan_bytes(&new, &old) } else { plan_bytes(&old, &new) };
    fs::write(out, &p).with_context(|| format!("{}", out.display()))?;
    println!("plan {}: {} bytes, {} steps, sha256 {:x}", out.display(), p.len(), u32_at(&p, 16), Sha256::digest(&p));
    Ok(())
}

/// `gpt same`: two dumps hold the same table: blocks 0..6 and the last 5 blocks, byte for byte. Data blocks in the dumps may differ.
pub fn same(head: &Path, tail: &Path, ref_head: &Path, ref_tail: &Path) -> Result<()> {
    let (a, b) = (read_dumps(head, tail)?, read_dumps(ref_head, ref_tail)?);
    for (n, x, y) in [("MBR", &a.mbr, &b.mbr), ("primary header", &a.hdr, &b.hdr), ("primary entries", &a.entries, &b.entries), ("backup header", &a.bhdr, &b.bhdr), ("backup entries", &a.bentries, &b.bentries)] {
        if x != y {
            let at = x.iter().zip(y.iter()).position(|(p, q)| p != q).unwrap_or(0);
            bail!("{n} differs from the backup at byte {at}. The table on the phone is not the one the plan was made from: stop");
        }
    }
    println!("the table in {} is the backup's, byte for byte", head.display());
    Ok(())
}

/// `gpt verify-new`: the dump read back from the phone is exactly the new table of the plan made from the reference dumps, and passes each rule on its own.
pub fn verify_new(head: &Path, tail: &Path, ref_head: &Path, ref_tail: &Path) -> Result<()> {
    let got = read_dumps(head, tail)?;
    let old = read_dumps(ref_head, ref_tail)?;
    check_old(&old)?;
    let l = Layout::new();
    let want = apply(&old, l);
    check_new(&got, &old, l)?;
    ensure!(got.hdr == want.hdr && got.entries == want.entries && got.bhdr == want.bhdr && got.bentries == want.bentries, "the table on the phone passes the rules but is not the planned bytes");
    print_table(&got, "on the phone:");
    println!("new table: both CRCs right, all other entries the same, userdata {}..{}, iosroot {}..{}", USERDATA_FIRST, l.userdata_last, l.iosroot_first, l.iosroot_last);
    Ok(())
}

/// `gpt image`: a gpt_both0-style image of the old table (MBR, header, 16 KiB entries, 16 KiB entries, header), for the last-resort `fastboot flash partition:0`, which ERASES ALL OF LUN 0.
pub fn image(head: &Path, tail: &Path, out: &Path) -> Result<()> {
    let old = read_dumps(head, tail)?;
    check_old(&old)?;
    let mut o = Vec::new();
    for x in [&old.mbr, &old.hdr, &old.entries, &old.bentries, &old.bhdr] {
        o.extend_from_slice(x);
    }
    fs::write(out, &o).with_context(|| format!("{}", out.display()))?;
    println!("{}: {} bytes. fastboot flash partition:0 ERASES ALL OF LUN 0 (ABL WriteGpt): system_a/b, product, odm, persist and the rest must be flashed from the backup after it", out.display(), o.len());
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A table with the layout of the phone, made here. Names and numbers are in this file; the GUIDs are made up.
    fn synth() -> Table {
        let b = BLOCK as usize;
        let mut mbr = vec![0u8; b];
        mbr[450] = 0xee;
        mbr[510] = 0x55;
        mbr[511] = 0xaa;
        let mut e = vec![0u8; 4 * b];
        let ends = [7u64, 8199, 8455, 8583, 8711, 74247, 139783, 172551, 205319, 221703, 254471, 1040903, 1827335, 1831431, LAST_USABLE];
        let mut first = FIRST_USABLE;
        for (i, n) in NAMES.iter().enumerate() {
            let s = &mut e[i * ESZ..(i + 1) * ESZ];
            s[..16].copy_from_slice(&[i as u8 + 1; 16]);
            s[16..32].copy_from_slice(&[i as u8 + 100; 16]);
            s[32..40].copy_from_slice(&first.to_le_bytes());
            s[40..48].copy_from_slice(&ends[i].to_le_bytes());
            if n.ends_with("_a") {
                s[48..56].copy_from_slice(&0x7f000000000000u64.to_le_bytes());
            }
            for (k, c) in n.encode_utf16().enumerate() {
                s[56 + 2 * k..58 + 2 * k].copy_from_slice(&c.to_le_bytes());
            }
            first = ends[i] + 1;
        }
        let mk = |cur: u64, alt: u64, pe: u64| {
            let mut h = vec![0u8; b];
            h[..8].copy_from_slice(b"EFI PART");
            h[8..12].copy_from_slice(&0x10000u32.to_le_bytes());
            h[12..16].copy_from_slice(&92u32.to_le_bytes());
            h[24..32].copy_from_slice(&cur.to_le_bytes());
            h[32..40].copy_from_slice(&alt.to_le_bytes());
            h[40..48].copy_from_slice(&FIRST_USABLE.to_le_bytes());
            h[48..56].copy_from_slice(&LAST_USABLE.to_le_bytes());
            h[56..72].copy_from_slice(&[9u8; 16]);
            h[72..80].copy_from_slice(&pe.to_le_bytes());
            h[80..84].copy_from_slice(&(SLOTS as u32).to_le_bytes());
            h[84..88].copy_from_slice(&(ESZ as u32).to_le_bytes());
            h
        };
        let mut t = Table { mbr, hdr: mk(1, ALT_LBA, 2), entries: e.clone(), bhdr: mk(ALT_LBA, 1, BACKUP_ENTRIES_LBA), bentries: e };
        fix_crcs(&mut t);
        t
    }

    fn numbers() -> Layout {
        Layout { userdata_last: 21633535, iosroot_first: 21633536, iosroot_last: 30119930 }
    }

    #[test]
    fn layout_numbers() {
        let l = Layout::new();
        assert_eq!(l, numbers());
        assert_eq!(l.iosroot_first % ALIGN, 0);
        assert_eq!(l.iosroot_blocks() * BLOCK, 34760273920);
        // the iOS 26 root and the old iOS 16 root both fit, with the console log
        assert!(34354491392 + LOG_BLOCKS * BLOCK <= 34760273920);
        assert!((16u64 << 30) + LOG_BLOCKS * BLOCK <= 34760273920);
    }

    #[test]
    fn good_table_gives_a_valid_new_table() {
        let old = synth();
        check_old(&old).unwrap();
        let n = apply(&old, Layout::new());
        check_new(&n, &old, Layout::new()).unwrap();
        assert_eq!(n.mbr, old.mbr);
        assert_eq!(n.entries[..14 * ESZ], old.entries[..14 * ESZ]);
        assert_ne!(u32_at(&n.hdr, 16), u32_at(&old.hdr, 16));
        assert_ne!(u32_at(&n.bhdr, 16), u32_at(&old.bhdr, 16));
    }

    #[test]
    fn plan_order_keeps_a_valid_table() {
        let old = synth();
        let n = apply(&old, Layout::new());
        let p = plan_bytes(&old, &n);
        assert_eq!(&p[..8], b"LDBPLAN1");
        assert_eq!(u32_at(&p, 16), 4);
        assert_eq!(fnv(&p[32..]), u64_at(&p, 24));
        let mut o = 32usize;
        let mut lbas = vec![];
        for _ in 0..4 {
            let (lba, bl, kind) = (u64_at(&p, o), u32_at(&p, o + 8), u32_at(&p, o + 12));
            lbas.push((lba, bl, kind));
            o += 16 + if kind == KIND_REPLACE { 2 * bl as usize * BLOCK as usize } else { 0 };
        }
        assert_eq!(o, p.len());
        assert_eq!(lbas, vec![(BACKUP_ENTRIES_LBA, 1, 1), (ALT_LBA, 1, 1), (USERDATA_FIRST, 2, 2), (1, 2, 1)]);
    }

    #[test]
    fn each_wrong_old_table_is_refused() {
        type Bad = fn(&mut Table);
        let cases: [(&str, Bad); 14] = [
            ("sig", |t| t.hdr[0] ^= 1),
            ("header crc", |t| t.hdr[16] ^= 1),
            ("backup crc", |t| t.bhdr[16] ^= 1),
            ("entry count", |t| { t.hdr[80] = 64; let c = hdr_crc(&t.hdr); t.hdr[16..20].copy_from_slice(&c.to_le_bytes()); }),
            ("copies differ", |t| { t.bentries[3] ^= 1; let c = crc(&t.bentries[..SLOTS * ESZ]); t.bhdr[88..92].copy_from_slice(&c.to_le_bytes()); let c = hdr_crc(&t.bhdr); t.bhdr[16..20].copy_from_slice(&c.to_le_bytes()); }),
            ("entries crc", |t| t.entries[100] ^= 1),
            ("name", |t| { t.entries[14 * ESZ + 56] = b'x'; t.bentries[14 * ESZ + 56] = b'x'; fix_crcs(t); }),
            ("already new", |t| { let n = apply(t, Layout::new()); *t = n; }),
            ("extra slot", |t| { t.entries[15 * ESZ] = 1; t.bentries[15 * ESZ] = 1; fix_crcs(t); }),
            ("userdata end", |t| { let v = (LAST_USABLE - 1).to_le_bytes(); t.entries[14 * ESZ + 40..14 * ESZ + 48].copy_from_slice(&v); t.bentries[14 * ESZ + 40..14 * ESZ + 48].copy_from_slice(&v); fix_crcs(t); }),
            ("userdata attr", |t| { t.entries[14 * ESZ + 48] = 1; t.bentries[14 * ESZ + 48] = 1; fix_crcs(t); }),
            ("metadata moved", |t| { t.entries[13 * ESZ + 32] ^= 1; t.bentries[13 * ESZ + 32] ^= 1; fix_crcs(t); }),
            ("no mbr", |t| t.mbr[450] = 0),
            ("usable last", |t| { t.hdr[48] ^= 1; let c = hdr_crc(&t.hdr); t.hdr[16..20].copy_from_slice(&c.to_le_bytes()); }),
        ];
        for (n, f) in cases {
            let mut t = synth();
            f(&mut t);
            assert!(check_old(&t).is_err(), "accepted: {n}");
        }
    }

    #[test]
    fn check_new_finds_any_other_change() {
        let old = synth();
        for i in [0usize, 13 * ESZ + 20, 14 * ESZ, 14 * ESZ + 20, 14 * ESZ + 50, 16 * ESZ + 1] {
            let mut n = apply(&old, Layout::new());
            n.entries[i] ^= 1;
            n.bentries[i] ^= 1;
            fix_crcs(&mut n);
            assert!(check_new(&n, &old, Layout::new()).is_err(), "byte {i}");
        }
    }

    /// The real layout, when the backup is on this machine. No GPT bytes in git.
    #[test]
    fn real_backup_layout() {
        let Some(home) = std::env::var_os("HOME") else { return };
        let dir = Path::new(&home).join("laurel-backup");
        let Some(b) = fs::read_dir(&dir).ok().and_then(|r| r.flatten().map(|e| e.path()).find(|p| p.join("gpt-sda-head.bin").exists())) else {
            println!("note: no backup with gpt-sda-head.bin under {}: the real layout was not tested", dir.display());
            return;
        };
        let old = read_dumps(&b.join("gpt-sda-head.bin"), &b.join("gpt-sda-tail.bin")).unwrap();
        check_old(&old).unwrap();
        let n = apply(&old, Layout::new());
        check_new(&n, &old, Layout::new()).unwrap();
        assert_eq!(range_of(&n.entries[14 * ESZ..15 * ESZ]), (USERDATA_FIRST, 21633535));
        assert_eq!(range_of(&n.entries[15 * ESZ..16 * ESZ]), (21633536, 30119930));
    }
}
