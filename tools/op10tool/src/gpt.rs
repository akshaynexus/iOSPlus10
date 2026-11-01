//! Mi A3 dual boot: the one GPT change on LUN 0 (docs/laurel_sprout/dual-boot.md).
//!
//! `userdata` shrinks to 70 % of its blocks, keeping start, type GUID, unique GUID and attributes. A new last entry `iosroot` takes the rest, from a 2 MiB
//! boundary up to the last usable block. Every other byte of the table stays. Input: dumps of the first and last 1 MiB of /dev/block/sda, in the format
//! of the backup (gpt-sda-head.bin, gpt-sda-tail.bin): 256 blocks each. Everything here works on files and needs no phone. No GPT bytes are in git: the
//! test on the real layout reads the backup folder.
//!
//! The plan is a file for `ldbhelper gpt-write`: which blocks change, their bytes before and after, in the order that keeps a valid table at each moment.
//!
//! The way back is made from the table on the disk, not from the backup: ABL and the slot HAL change attributes and swap type GUIDs of the `_a`/`_b` partitions in both copies, so after any
//! slot change the disk is neither of the two tables of the first plan. `plan-restore` changes only the last LBA of `userdata` and empties the `iosroot` slot. `plan-repair` writes a torn primary from a valid backup.
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

/// What dual-boot.sh asks of this binary (`gpt features`). A later change of the commands changes this text, so a stale out/bin/op10tool is seen before it is used.
pub const FEATURES: &str = "ldb-gpt-2";

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

/// One header with its entries, valid by itself: where it says it is, and its CRCs.
fn check_copy(what: &str, h: &[u8], ent: &[u8], cur: u64, alt: u64, pe: u64) -> Result<()> {
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
    Ok(())
}
fn check_primary(t: &Table) -> Result<()> {
    check_copy("primary", &t.hdr, &t.entries, 1, ALT_LBA, 2)
}
fn check_backup(t: &Table) -> Result<()> {
    check_copy("backup", &t.bhdr, &t.bentries, ALT_LBA, 1, BACKUP_ENTRIES_LBA)
}
/// The fields both header copies must have, in any state of this plan.
fn check_headers(t: &Table) -> Result<()> {
    check_primary(t)?;
    check_backup(t)?;
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
    plan_steps(from, to, true)
}
/// zero: false only for the repair of a primary, which changes nothing else.
fn plan_steps(from: &Table, to: &Table, zero: bool) -> Vec<u8> {
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
    if zero {
        step(USERDATA_FIRST, SB_BLOCKS, KIND_ZERO, &[]);
    }
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

/// `gpt plan`: from dumps of the expected old table, the plan file. Prints both tables and the numbers.
pub fn plan(head: &Path, tail: &Path, out: &Path) -> Result<()> {
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
    let p = plan_bytes(&old, &new);
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

fn is_slot_name(n: &str) -> bool {
    n.ends_with("_a") || n.ends_with("_b")
}
/// The entries belong to this disk: slots 1..15 hold what the reference (the pre-write backup) holds, except what a slot change may change: attributes and type GUID of `_a`/`_b` partitions.
/// A type GUID there must be its own or the one of its pair: SwitchPtnSlots swaps them. The last LBA of `userdata` is not compared here.
fn check_same_disk(e: &[u8], reference: &[u8]) -> Result<()> {
    for (i, n) in NAMES.iter().enumerate() {
        let (a, r) = (&e[i * ESZ..(i + 1) * ESZ], &reference[i * ESZ..(i + 1) * ESZ]);
        ensure!(name_of(a) == *n, "slot {i} is '{}', expected '{n}'", name_of(a));
        ensure!(a[16..32] == r[16..32], "{n}: the unique GUID is not the one of the backup");
        ensure!(a[32..40] == r[32..40], "{n}: the first LBA is not the one of the backup");
        ensure!(*n == "userdata" || a[40..48] == r[40..48], "{n}: the last LBA is not the one of the backup");
        if is_slot_name(n) {
            let pair = format!("{}{}", &n[..n.len() - 1], if n.ends_with("_a") { "b" } else { "a" });
            let j = NAMES.iter().position(|x| *x == pair).with_context(|| format!("{n}: no pair"))?;
            ensure!(a[..16] == r[..16] || a[..16] == reference[j * ESZ..j * ESZ + 16], "{n}: the type GUID is neither its own nor the one of {pair}");
        } else {
            ensure!(a[..16] == r[..16] && a[48..56] == r[48..56], "{n}: type GUID or attributes changed, and it is not a slot partition");
        }
    }
    Ok(())
}
fn layout_is_new(e: &[u8], reference: &[u8]) -> Result<()> {
    check_same_disk(e, reference)?;
    let l = Layout::new();
    ensure!(range_of(&e[14 * ESZ..15 * ESZ]) == (USERDATA_FIRST, l.userdata_last), "userdata is {:?}", range_of(&e[14 * ESZ..15 * ESZ]));
    let i = &e[15 * ESZ..16 * ESZ];
    ensure!(name_of(i) == "iosroot" && range_of(i) == (l.iosroot_first, l.iosroot_last), "slot 16 is '{}' {:?}, not iosroot", name_of(i), range_of(i));
    ensure!(e[16 * ESZ..SLOTS * ESZ].iter().all(|x| *x == 0), "a slot after iosroot is not empty");
    Ok(())
}
fn layout_is_old(e: &[u8], reference: &[u8]) -> Result<()> {
    check_same_disk(e, reference)?;
    ensure!(range_of(&e[14 * ESZ..15 * ESZ]) == (USERDATA_FIRST, LAST_USABLE), "userdata is {:?}", range_of(&e[14 * ESZ..15 * ESZ]));
    ensure!(e[15 * ESZ..SLOTS * ESZ].iter().all(|x| *x == 0), "a slot after userdata is not empty");
    Ok(())
}
/// The backup header of a valid primary, as a writer of this table makes it. Same fields, its own LBAs.
fn backup_header_of(primary: &[u8]) -> Vec<u8> {
    let mut h = primary.to_vec();
    h[24..32].copy_from_slice(&ALT_LBA.to_le_bytes());
    h[32..40].copy_from_slice(&1u64.to_le_bytes());
    h[72..80].copy_from_slice(&BACKUP_ENTRIES_LBA.to_le_bytes());
    let c = hdr_crc(&h);
    h[16..20].copy_from_slice(&c.to_le_bytes());
    h
}
fn primary_header_of(backup: &[u8]) -> Vec<u8> {
    let mut h = backup.to_vec();
    h[24..32].copy_from_slice(&1u64.to_le_bytes());
    h[32..40].copy_from_slice(&ALT_LBA.to_le_bytes());
    h[72..80].copy_from_slice(&2u64.to_le_bytes());
    let c = hdr_crc(&h);
    h[16..20].copy_from_slice(&c.to_le_bytes());
    h
}
/// The table on the disk with the change undone: the last LBA of `userdata` back to the last usable block, slot 16 empty, the CRCs. Every other byte stays.
fn restored(from: &Table) -> Table {
    let mut e = from.entries.clone();
    e[14 * ESZ + 40..14 * ESZ + 48].copy_from_slice(&LAST_USABLE.to_le_bytes());
    e[15 * ESZ..16 * ESZ].fill(0);
    let mut t = Table { mbr: from.mbr.clone(), hdr: from.hdr.clone(), entries: e.clone(), bhdr: from.bhdr.clone(), bentries: e };
    fix_crcs(&mut t);
    t
}
/// The proof of F3: byte by byte, the two tables differ only in what the restore must change. Returns the number of bytes that differ.
fn prove_restore_diff(from: &Table, to: &Table) -> Result<usize> {
    let mut n = 0;
    let allowed_e = |o: usize| (14 * ESZ + 40..14 * ESZ + 48).contains(&o) || (15 * ESZ..16 * ESZ).contains(&o);
    let allowed_h = |o: usize| (16..20).contains(&o) || (88..92).contains(&o);
    for (what, a, b, ok) in [
        ("primary header", &from.hdr, &to.hdr, &allowed_h as &dyn Fn(usize) -> bool),
        ("backup header", &from.bhdr, &to.bhdr, &allowed_h as &dyn Fn(usize) -> bool),
        ("primary entries", &from.entries, &to.entries, &allowed_e as &dyn Fn(usize) -> bool),
        ("backup entries", &from.bentries, &to.bentries, &allowed_e as &dyn Fn(usize) -> bool),
    ] {
        ensure!(a.len() == b.len(), "{what}: the lengths differ");
        for (o, (x, y)) in a.iter().zip(b.iter()).enumerate() {
            if x != y {
                ensure!(ok(o), "{what}: byte {o} changes, and only the last LBA of userdata, the iosroot slot and the CRCs may");
                n += 1;
            }
        }
    }
    ensure!(from.mbr == to.mbr, "the MBR changes");
    Ok(n)
}

/// `gpt state`: one word for the table on the disk. new: a valid primary with iosroot (the backup may be new, or part of a stopped restore: the helper decides by the plan). old: both copies valid and equal, no iosroot.
/// old-backup-differs: a valid primary without iosroot and a backup that differs: a stopped gpt-write. torn-backup-new, torn-backup-old: the primary is not valid, the backup is, with that layout. broken: no valid copy. unknown: valid, but not this disk's layouts.
pub fn state(head: &Path, tail: &Path, ref_head: &Path, ref_tail: &Path) -> Result<()> {
    let t = read_dumps(head, tail)?;
    let r = read_dumps(ref_head, ref_tail)?;
    check_old(&r)?;
    let w = if check_primary(&t).is_ok() {
        if layout_is_new(&t.entries, &r.entries).is_ok() {
            "new"
        } else if layout_is_old(&t.entries, &r.entries).is_ok() {
            if check_backup(&t).is_ok() && t.entries == t.bentries {
                "old"
            } else {
                "old-backup-differs"
            }
        } else {
            "unknown"
        }
    } else if check_backup(&t).is_ok() {
        if layout_is_new(&t.bentries, &r.entries).is_ok() {
            "torn-backup-new"
        } else if layout_is_old(&t.bentries, &r.entries).is_ok() {
            "torn-backup-old"
        } else {
            "unknown"
        }
    } else {
        "broken"
    };
    println!("{w}");
    Ok(())
}

/// `gpt plan-restore`: the plan back from the table on the disk (a dump read a moment ago). All that is read from the primary, so a run that stopped part way makes the same plan again.
pub fn plan_restore(head: &Path, tail: &Path, ref_head: &Path, ref_tail: &Path, out: &Path) -> Result<()> {
    let now = read_dumps(head, tail)?;
    let r = read_dumps(ref_head, ref_tail)?;
    check_old(&r)?;
    check_primary(&now)?;
    layout_is_new(&now.entries, &r.entries)?;
    let from = Table { mbr: now.mbr.clone(), hdr: now.hdr.clone(), entries: now.entries.clone(), bhdr: backup_header_of(&now.hdr), bentries: now.entries.clone() };
    let to = restored(&from);
    let n = prove_restore_diff(&from, &to)?;
    check_primary(&to)?;
    check_backup(&to)?;
    layout_is_old(&to.entries, &r.entries)?;
    print_table(&from, "before (the table on the disk):");
    print_table(&to, "after:");
    println!("diff: {n} bytes in all, only: last LBA of userdata, the iosroot slot, the entries CRC and the header CRC of each copy. Attributes and type GUIDs of all other entries stay");
    let p = plan_bytes(&from, &to);
    fs::write(out, &p).with_context(|| format!("{}", out.display()))?;
    println!("plan {}: {} bytes, {} steps, sha256 {:x}", out.display(), p.len(), u32_at(&p, 16), Sha256::digest(&p));
    Ok(())
}

/// `gpt plan-repair`: a torn primary is written from a valid backup, and nothing else: the plan's steps for the backup hold its own bytes on both sides. Refuses when the primary is valid or the backup is not.
pub fn plan_repair(head: &Path, tail: &Path, ref_head: &Path, ref_tail: &Path, out: &Path) -> Result<()> {
    let now = read_dumps(head, tail)?;
    let r = read_dumps(ref_head, ref_tail)?;
    check_old(&r)?;
    ensure!(check_primary(&now).is_err(), "the primary is valid: nothing to repair");
    check_backup(&now).context("the primary is not valid and the backup is not valid: nothing to repair from")?;
    ensure!(layout_is_new(&now.bentries, &r.entries).is_ok() || layout_is_old(&now.bentries, &r.entries).is_ok(), "the backup copy is valid but holds neither layout of this disk");
    let from = Table { mbr: now.mbr.clone(), hdr: now.hdr.clone(), entries: now.entries.clone(), bhdr: now.bhdr.clone(), bentries: now.bentries.clone() };
    let to = Table { mbr: now.mbr.clone(), hdr: primary_header_of(&now.bhdr), entries: now.bentries.clone(), bhdr: now.bhdr.clone(), bentries: now.bentries.clone() };
    check_headers(&to)?;
    print_table(&to, "after (from the backup copy):");
    let p = plan_steps(&from, &to, false);
    fs::write(out, &p).with_context(|| format!("{}", out.display()))?;
    println!("plan {}: {} bytes, {} steps, sha256 {:x}", out.display(), p.len(), u32_at(&p, 16), Sha256::digest(&p));
    Ok(())
}

/// `gpt verify-plan`: a dump read back holds each new block of this plan, and both copies are valid and equal.
pub fn verify_plan(head: &Path, tail: &Path, plan_file: &Path) -> Result<()> {
    let got = read_dumps(head, tail)?;
    let p = fs::read(plan_file).with_context(|| format!("{}", plan_file.display()))?;
    ensure!(p.len() >= 32 && &p[..8] == b"LDBPLAN1" && fnv(&p[32..]) == u64_at(&p, 24), "{}: not a plan", plan_file.display());
    check_headers(&got)?;
    let (mut o, mut blocks) = (32usize, 0);
    let b = BLOCK as usize;
    for _ in 0..u32_at(&p, 16) {
        let (lba, n, kind) = (u64_at(&p, o), u32_at(&p, o + 8) as usize, u32_at(&p, o + 12));
        o += 16;
        if kind != KIND_REPLACE {
            continue;
        }
        for k in 0..n {
            let new = &p[o + n * b + k * b..o + n * b + (k + 1) * b];
            let at = lba + k as u64;
            let have = match at {
                1 => &got.hdr[..],
                2 => &got.entries[..b],
                ALT_LBA => &got.bhdr[..],
                BACKUP_ENTRIES_LBA => &got.bentries[..b],
                _ => bail!("the plan names LBA {at}, no table block"),
            };
            ensure!(have == new, "LBA {at} on the disk is not the plan's new bytes");
            blocks += 1;
        }
        o += 2 * n * b;
    }
    print_table(&got, "on the disk:");
    println!("{blocks} table blocks equal the plan's new bytes, both copies valid and equal");
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

    /// What a slot change does to the table [ABL SwitchPtnSlots, the HAL]: attributes of `_a`/`_b` entries, and the type GUIDs of a pair swapped, in both copies.
    fn slot_change(t: &mut Table) {
        for i in 0..NAMES.len() {
            if is_slot_name(NAMES[i]) {
                t.entries[i * ESZ + 48..i * ESZ + 56].copy_from_slice(&0x3f000000000000u64.to_le_bytes());
            }
        }
        for (a, b) in [(5, 6), (7, 8), (11, 12)] {
            for k in 0..16 {
                t.entries.swap(a * ESZ + k, b * ESZ + k);
            }
        }
        t.bentries = t.entries.clone();
        fix_crcs(t);
    }

    #[test]
    fn restore_after_a_slot_change_changes_only_its_own_bytes() {
        let old = synth();
        let mut n = apply(&old, Layout::new());
        slot_change(&mut n);
        let from = Table { mbr: n.mbr.clone(), hdr: n.hdr.clone(), entries: n.entries.clone(), bhdr: backup_header_of(&n.hdr), bentries: n.entries.clone() };
        assert_eq!(from.bhdr, n.bhdr, "the backup header made from the primary is the one on the disk");
        let to = restored(&from);
        prove_restore_diff(&from, &to).unwrap();
        check_headers(&to).unwrap();
        layout_is_old(&to.entries, &old.entries).unwrap();
        layout_is_new(&n.entries, &old.entries).unwrap();
        // attributes and type GUIDs stay as they are on the disk, not as in the backup
        assert_eq!(to.entries[5 * ESZ..14 * ESZ], n.entries[5 * ESZ..14 * ESZ]);
        assert_ne!(to.entries[5 * ESZ..14 * ESZ], old.entries[5 * ESZ..14 * ESZ]);
    }

    #[test]
    fn restore_with_no_slot_change_gives_the_backup_byte_for_byte() {
        let old = synth();
        let n = apply(&old, Layout::new());
        let to = restored(&n);
        assert_eq!(to.hdr, old.hdr);
        assert_eq!(to.entries, old.entries);
        assert_eq!(to.bhdr, old.bhdr);
        assert_eq!(to.bentries, old.bentries);
    }

    #[test]
    fn prove_restore_diff_refuses_any_other_byte() {
        let n = apply(&synth(), Layout::new());
        for i in [3usize, 14 * ESZ + 32, 14 * ESZ + 39, 14 * ESZ + 48, 13 * ESZ + 40, 16 * ESZ] {
            let mut to = restored(&n);
            to.entries[i] ^= 1;
            assert!(prove_restore_diff(&n, &to).is_err(), "entry byte {i}");
        }
        for i in [24usize, 40, 60] {
            let mut to = restored(&n);
            to.hdr[i] ^= 1;
            assert!(prove_restore_diff(&n, &to).is_err(), "header byte {i}");
        }
    }

    #[test]
    fn same_disk_refuses_what_a_slot_change_cannot_do() {
        let old = synth();
        let mut n = apply(&old, Layout::new());
        slot_change(&mut n);
        for (what, at, v) in [("non-slot attributes", 1 * ESZ + 48, 1u8), ("non-slot type", 2 * ESZ, 0x55), ("range", 5 * ESZ + 40, 0x55), ("unique GUID", 5 * ESZ + 20, 0x55), ("type GUID of no pair", 5 * ESZ + 3, 0x55)] {
            let mut e = n.entries.clone();
            e[at] ^= v;
            assert!(check_same_disk(&e, &old.entries).is_err(), "{what}");
        }
    }

    #[test]
    fn primary_made_from_the_backup_is_the_primary() {
        let n = apply(&synth(), Layout::new());
        assert_eq!(primary_header_of(&n.bhdr), n.hdr);
        assert_eq!(backup_header_of(&n.hdr), n.bhdr);
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
