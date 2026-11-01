//! `op10tool hfs-build`, `hfs-verify`, `hfs-sample`: an HFSX (case-sensitive HFS+) image from a spec, with no mount and no root access.
//! The image has the same shape as the root that boots on the phone: block size 4096, B-trees as `mkfs.hfsplus -s -J` makes them,
//! an 8 MiB journal with flags 5 (XNU makes the journal at the first mount). All file data is contiguous and one extent per file.
//! Hard links do not exist in the image: the caller gives each path its own data or a symlink. Same input: same bytes.
//!
//! Spec: one entry per line, fields split by NUL: TYPE MODE UID GID MTIME FLAGS PATH SOURCE. TYPE d, f or l. MODE octal, PATH relative and
//! in the volume, SOURCE a host file (f) or the link target (l). FLAGS: BSD flags, decimal (SF_RESTRICTED 0x80000).

use anyhow::{bail, ensure, Context, Result};
use rayon::prelude::*;
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashMap};
use std::fs::File;
use std::io::{BufWriter, Write};
use std::os::unix::fs::FileExt;
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use unicode_normalization::UnicodeNormalization;

const BS: u64 = 4096;
const CAT_NODE: usize = 8192;
const EXT_NODE: usize = 4096;
const ATTR_NODE: usize = 8192;
const EXT_BYTES: u64 = 4 << 20;
const ATTR_BYTES: u64 = 6 << 20;
const JOURNAL_BYTES: u64 = 8 << 20;
const HFS_EPOCH: u64 = 2082844800;
const ROOT_CNID: u32 = 2;
const PRIVATE_NAME: &str = "\u{0}\u{0}\u{0}\u{0}HFS+ Private Data";
const MAX_HDR_MAP_NODES: u64 = ((CAT_NODE - 256) * 8) as u64;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Kind {
    Dir,
    File,
    Link,
}

struct Entry {
    kind: Kind,
    mode: u16,
    uid: u32,
    gid: u32,
    mtime: u64,
    flags: u32,
    path: Vec<u8>,
    src: Vec<u8>,
    size: u64,
    cnid: u32,
    parent: u32,
    valence: u32,
    subdirs: u32,
    start: u32,
    blocks: u32,
}

fn be16(b: &mut Vec<u8>, v: u16) {
    b.extend_from_slice(&v.to_be_bytes());
}
fn be32(b: &mut Vec<u8>, v: u32) {
    b.extend_from_slice(&v.to_be_bytes());
}
fn be64(b: &mut Vec<u8>, v: u64) {
    b.extend_from_slice(&v.to_be_bytes());
}
fn rd16(b: &[u8], o: usize) -> u16 {
    u16::from_be_bytes(b[o..o + 2].try_into().unwrap())
}
fn rd32(b: &[u8], o: usize) -> u32 {
    u32::from_be_bytes(b[o..o + 4].try_into().unwrap())
}
fn rd64(b: &[u8], o: usize) -> u64 {
    u64::from_be_bytes(b[o..o + 8].try_into().unwrap())
}

/// The name as the catalog stores it: UTF-16 in Apple's decomposed form, with ':' as '/'. U+2000-2FFF, F900-FAFF and 2F800-2FAFF stay composed, as in HFS+.
fn catalog_name(raw: &[u8]) -> Result<Vec<u16>> {
    let s = std::str::from_utf8(raw).with_context(|| format!("name is not UTF-8: {:?}", String::from_utf8_lossy(raw)))?;
    let mut out: Vec<u16> = Vec::with_capacity(s.len());
    if s.is_ascii() {
        out.extend(s.bytes().map(|c| if c == b':' { b'/' as u16 } else { c as u16 }));
    } else {
        let keep = |c: char| matches!(c as u32, 0x2000..=0x2FFF | 0xF900..=0xFAFF | 0x2F800..=0x2FAFF);
        let mut seg = String::new();
        let mut buf = [0u16; 2];
        for c in s.chars() {
            if keep(c) {
                for d in seg.nfd() {
                    out.extend_from_slice(d.encode_utf16(&mut buf));
                }
                seg.clear();
                out.extend_from_slice(c.encode_utf16(&mut buf));
            } else {
                seg.push(c);
            }
        }
        for d in seg.nfd() {
            out.extend_from_slice(d.encode_utf16(&mut buf));
        }
        for u in out.iter_mut() {
            if *u == b':' as u16 {
                *u = b'/' as u16;
            }
        }
    }
    ensure!(!out.is_empty() && out.len() <= 255, "name of {} UTF-16 units: {:?}", out.len(), s);
    Ok(out)
}

fn split_path(p: &[u8]) -> (&[u8], &[u8]) {
    match p.iter().rposition(|c| *c == b'/') {
        Some(i) => (&p[..i], &p[i + 1..]),
        None => (&p[..0], p),
    }
}

fn parse_spec(path: &Path) -> Result<Vec<Entry>> {
    let data = std::fs::read(path).with_context(|| format!("read {path:?}"))?;
    let mut v = Vec::new();
    for (n, line) in data.split(|c| *c == b'\n').enumerate() {
        if line.is_empty() {
            continue;
        }
        let f: Vec<&[u8]> = line.split(|c| *c == 0).collect();
        ensure!(f.len() == 8, "spec line {}: {} fields", n + 1, f.len());
        let num = |x: &[u8], radix: u32| -> Result<u64> { Ok(u64::from_str_radix(std::str::from_utf8(x)?, radix)?) };
        let kind = match f[0] {
            b"d" => Kind::Dir,
            b"f" => Kind::File,
            b"l" => Kind::Link,
            _ => bail!("spec line {}: type {:?}", n + 1, String::from_utf8_lossy(f[0])),
        };
        let path = f[6].to_vec();
        ensure!(!path.is_empty() && path[0] != b'/' && !path.ends_with(b"/"), "spec line {}: path {:?}", n + 1, String::from_utf8_lossy(&path));
        let perm = (num(f[1], 8)? & 0o7777) as u16;
        let fmt: u16 = match kind {
            Kind::Dir => 0o040000,
            Kind::File => 0o100000,
            Kind::Link => 0o120000,
        };
        v.push(Entry {
            kind,
            mode: fmt | perm,
            uid: num(f[2], 10)? as u32,
            gid: num(f[3], 10)? as u32,
            mtime: num(f[4], 10)?,
            flags: num(f[5], 10)? as u32,
            path,
            src: f[7].to_vec(),
            size: 0,
            cnid: 0,
            parent: 0,
            valence: 0,
            subdirs: 0,
            start: 0,
            blocks: 0,
        });
    }
    v.sort_by(|a, b| a.path.cmp(&b.path));
    for w in v.windows(2) {
        ensure!(w[0].path != w[1].path, "spec has {:?} twice", String::from_utf8_lossy(&w[0].path));
    }
    Ok(v)
}

struct Rec {
    parent: u32,
    name: Vec<u16>,
    data: Vec<u8>,
}

fn key_bytes(parent: u32, name: &[u16]) -> Vec<u8> {
    let mut k = Vec::with_capacity(8 + name.len() * 2);
    be16(&mut k, (6 + name.len() * 2) as u16);
    be32(&mut k, parent);
    be16(&mut k, name.len() as u16);
    for c in name {
        be16(&mut k, *c);
    }
    k
}

fn hfs_time(t: u64) -> u32 {
    (t + HFS_EPOCH) as u32
}

fn bsdinfo(b: &mut Vec<u8>, e_uid: u32, e_gid: u32, flags: u32, mode: u16, special: u32) {
    be32(b, e_uid);
    be32(b, e_gid);
    b.push((flags >> 16) as u8);
    b.push(flags as u8);
    be16(b, mode);
    be32(b, special);
}

fn folder_rec(cnid: u32, valence: u32, subdirs: u32, t: u32, uid: u32, gid: u32, flags: u32, mode: u16, frflags: u16) -> Vec<u8> {
    let mut b = Vec::with_capacity(88);
    be16(&mut b, 1);
    be16(&mut b, 0x10); // kHFSHasFolderCountMask (HFSX)
    be32(&mut b, valence);
    be32(&mut b, cnid);
    for _ in 0..4 {
        be32(&mut b, t);
    }
    be32(&mut b, 0);
    bsdinfo(&mut b, uid, gid, flags, mode, 0);
    b.extend_from_slice(&[0u8; 8]);
    be16(&mut b, frflags);
    b.extend_from_slice(&[0u8; 6]);
    b.extend_from_slice(&[0u8; 16]);
    be32(&mut b, 0);
    be32(&mut b, subdirs);
    debug_assert_eq!(b.len(), 88);
    b
}

#[allow(clippy::too_many_arguments)]
fn file_rec(cnid: u32, t: u32, uid: u32, gid: u32, flags: u32, mode: u16, ftype: &[u8; 4], creator: &[u8; 4], frflags: u16, size: u64, start: u32, blocks: u32) -> Vec<u8> {
    let mut b = Vec::with_capacity(248);
    be16(&mut b, 2);
    be16(&mut b, 2); // kHFSThreadExistsMask
    be32(&mut b, 0);
    be32(&mut b, cnid);
    for _ in 0..4 {
        be32(&mut b, t);
    }
    be32(&mut b, 0);
    bsdinfo(&mut b, uid, gid, flags, mode, 1);
    b.extend_from_slice(ftype);
    b.extend_from_slice(creator);
    be16(&mut b, frflags);
    b.extend_from_slice(&[0u8; 6]);
    b.extend_from_slice(&[0u8; 16]);
    be32(&mut b, 0);
    be32(&mut b, 0);
    fork(&mut b, size, blocks, start, blocks);
    fork(&mut b, 0, 0, 0, 0);
    debug_assert_eq!(b.len(), 248);
    b
}

fn fork(b: &mut Vec<u8>, size: u64, total: u32, start: u32, blocks: u32) {
    be64(b, size);
    be32(b, 0);
    be32(b, total);
    be32(b, start);
    be32(b, blocks);
    for _ in 0..7 {
        be32(b, 0);
        be32(b, 0);
    }
}

fn thread_rec(is_dir: bool, parent: u32, name: &[u16]) -> Vec<u8> {
    let mut b = Vec::with_capacity(10 + name.len() * 2);
    be16(&mut b, if is_dir { 3 } else { 4 });
    be16(&mut b, 0);
    be32(&mut b, parent);
    be16(&mut b, name.len() as u16);
    for c in name {
        be16(&mut b, *c);
    }
    b
}

/// One built B-tree node: descriptor + records + offset table.
fn make_node(size: usize, kind: u8, height: u8, flink: u32, blink: u32, recs: &[Vec<u8>]) -> Vec<u8> {
    let mut n = vec![0u8; size];
    n[0..4].copy_from_slice(&flink.to_be_bytes());
    n[4..8].copy_from_slice(&blink.to_be_bytes());
    n[8] = kind;
    n[9] = height;
    n[10..12].copy_from_slice(&(recs.len() as u16).to_be_bytes());
    let mut off = 14usize;
    for (i, r) in recs.iter().enumerate() {
        n[size - 2 * (i + 1)..size - 2 * i].copy_from_slice(&(off as u16).to_be_bytes());
        n[off..off + r.len()].copy_from_slice(r);
        off += r.len();
    }
    let i = recs.len();
    n[size - 2 * (i + 1)..size - 2 * i].copy_from_slice(&(off as u16).to_be_bytes());
    n
}

struct TreeInfo {
    depth: u16,
    root: u32,
    leaf_records: u32,
    first_leaf: u32,
    last_leaf: u32,
}

#[allow(clippy::too_many_arguments)]
fn header_node(node_size: usize, info: &TreeInfo, max_key: u16, total_nodes: u32, used_nodes: u32, clump: u32, compare: u8, attrs: u32) -> Vec<u8> {
    let mut h = Vec::with_capacity(106);
    be16(&mut h, info.depth);
    be32(&mut h, info.root);
    be32(&mut h, info.leaf_records);
    be32(&mut h, info.first_leaf);
    be32(&mut h, info.last_leaf);
    be16(&mut h, node_size as u16);
    be16(&mut h, max_key);
    be32(&mut h, total_nodes);
    be32(&mut h, total_nodes - used_nodes);
    be16(&mut h, 0);
    be32(&mut h, clump);
    h.push(0);
    h.push(compare);
    be32(&mut h, attrs);
    h.extend_from_slice(&[0u8; 64]);
    debug_assert_eq!(h.len(), 106);
    let user = vec![0u8; 128];
    let map_len = node_size - 256;
    let mut map = vec![0u8; map_len];
    for i in 0..used_nodes as usize {
        map[i / 8] |= 0x80 >> (i % 8);
    }
    make_node(node_size, 1, 0, 0, 0, &[h, user, map])
}

/// Sorted records into nodes. Node 0 is the header; leaves, then index levels.
fn build_catalog(recs: &[Rec]) -> Result<(Vec<Vec<u8>>, TreeInfo)> {
    let space = |n: usize, bytes: usize| 14 + bytes + 2 * (n + 1) <= CAT_NODE;
    let mut leaves: Vec<Vec<Vec<u8>>> = Vec::new();
    let mut cur: Vec<Vec<u8>> = Vec::new();
    let mut bytes = 0usize;
    for r in recs {
        let mut rb = key_bytes(r.parent, &r.name);
        rb.extend_from_slice(&r.data);
        if rb.len() % 2 == 1 {
            rb.push(0);
        }
        if !space(cur.len() + 1, bytes + rb.len()) {
            leaves.push(std::mem::take(&mut cur));
            bytes = 0;
        }
        bytes += rb.len();
        cur.push(rb);
    }
    if !cur.is_empty() {
        leaves.push(cur);
    }
    let mut nodes: Vec<Vec<u8>> = vec![Vec::new()]; // header later
    let first_leaf = 1u32;
    let count = leaves.len() as u32;
    let mut level: Vec<(Vec<u8>, u32)> = Vec::new();
    for (i, l) in leaves.iter().enumerate() {
        let num = 1 + i as u32;
        let flink = if i as u32 + 1 < count { num + 1 } else { 0 };
        let blink = if i > 0 { num - 1 } else { 0 };
        let kl = rd16(&l[0], 0) as usize;
        level.push((l[0][..2 + kl].to_vec(), num));
        nodes.push(make_node(CAT_NODE, 0xFF, 1, flink, blink, l));
    }
    let last_leaf = count;
    let mut height = 1u8;
    while level.len() > 1 {
        height += 1;
        let mut groups: Vec<Vec<Vec<u8>>> = Vec::new();
        let mut keys: Vec<Vec<u8>> = Vec::new();
        let mut cur: Vec<Vec<u8>> = Vec::new();
        let mut b = 0usize;
        for (k, child) in &level {
            let mut r = k.clone();
            r.extend_from_slice(&child.to_be_bytes());
            if !space(cur.len() + 1, b + r.len()) {
                groups.push(std::mem::take(&mut cur));
                b = 0;
            }
            if cur.is_empty() {
                keys.push(k.clone());
            }
            b += r.len();
            cur.push(r);
        }
        groups.push(cur);
        let base = nodes.len() as u32;
        let mut next = Vec::new();
        let n = groups.len() as u32;
        for (i, g) in groups.iter().enumerate() {
            let num = base + i as u32;
            let flink = if (i as u32) + 1 < n { num + 1 } else { 0 };
            let blink = if i > 0 { num - 1 } else { 0 };
            nodes.push(make_node(CAT_NODE, 0, height, flink, blink, g));
            next.push((keys[i].clone(), num));
        }
        level = next;
    }
    let root = level.first().map(|x| x.1).unwrap_or(0);
    Ok((nodes, TreeInfo { depth: height as u16, root, leaf_records: recs.len() as u32, first_leaf, last_leaf }))
}

pub struct BuildOpts<'a> {
    pub spec: &'a Path,
    pub out: &'a Path,
    pub size: u64,
    pub label: &'a str,
    pub manifest: &'a Path,
    pub min_free: u64,
    pub created: u64,
    pub max_size: u64,
}

fn write_all_at(f: &File, buf: &[u8], off: u64) -> Result<()> {
    f.write_all_at(buf, off).with_context(|| format!("write at {off}"))
}

pub fn build(o: &BuildOpts) -> Result<()> {
    ensure!(o.size % BS == 0 && o.size > (64 << 20), "size {} is not a multiple of 4096", o.size);
    ensure!(o.size <= o.max_size, "volume {} bytes, the area holds {} bytes", o.size, o.max_size);
    let mut entries = parse_spec(o.spec)?;
    // file sizes: stat in parallel, the sources may be on a slow FUSE mount
    entries.par_iter_mut().try_for_each(|e| -> Result<()> {
        match e.kind {
            Kind::File => {
                let p = std::ffi::OsStr::from_encoded_bytes_unchecked_safe(&e.src);
                let md = std::fs::symlink_metadata(p).with_context(|| format!("source of {}", String::from_utf8_lossy(&e.path)))?;
                ensure!(md.is_file(), "source of {} is not a file", String::from_utf8_lossy(&e.path));
                e.size = md.len();
            }
            Kind::Link => e.size = e.src.len() as u64,
            Kind::Dir => {}
        }
        Ok(())
    })?;
    // CNIDs: 16, 17 journal files; 18 private directory
    let mut by_path: HashMap<Vec<u8>, usize> = HashMap::with_capacity(entries.len());
    let mut next_id = 19u32;
    for (i, e) in entries.iter_mut().enumerate() {
        e.cnid = next_id;
        next_id += 1;
        by_path.insert(e.path.clone(), i);
    }
    let mut root_val = 3u32; // .journal, .journal_info_block, private directory
    let mut root_sub = 1u32;
    for i in 0..entries.len() {
        let parent_path = split_path(&entries[i].path).0.to_vec();
        let is_dir = entries[i].kind == Kind::Dir;
        if parent_path.is_empty() {
            entries[i].parent = ROOT_CNID;
            root_val += 1;
            root_sub += is_dir as u32;
        } else {
            let pi = *by_path.get(&parent_path).with_context(|| format!("no directory for {}", String::from_utf8_lossy(&entries[i].path)))?;
            ensure!(entries[pi].kind == Kind::Dir, "parent of {} is not a directory", String::from_utf8_lossy(&entries[i].path));
            entries[i].parent = entries[pi].cnid;
            entries[pi].valence += 1;
            entries[pi].subdirs += is_dir as u32;
        }
    }
    // layout: block 0 volume header; bitmap; journal info block; journal; extents; attributes; catalog; data
    let total_blocks = o.size / BS;
    let bitmap_blocks = (total_blocks / 8).div_ceil(BS);
    let jib_block = 1 + bitmap_blocks;
    let journal_block = jib_block + 1;
    let journal_blocks = JOURNAL_BYTES / BS;
    let ext_block = journal_block + journal_blocks;
    let ext_blocks = EXT_BYTES / BS;
    let attr_block = ext_block + ext_blocks;
    let attr_blocks = ATTR_BYTES / BS;
    let cat_block = attr_block + attr_blocks;
    let t0 = hfs_time(o.created);
    // the records: extents are put in after the catalog size is known, which they do not change
    let label16: Vec<u16> = o.label.encode_utf16().collect();
    let private16: Vec<u16> = PRIVATE_NAME.encode_utf16().collect();
    let jname: Vec<u16> = ".journal".encode_utf16().collect();
    let jiname: Vec<u16> = ".journal_info_block".encode_utf16().collect();
    let names: Vec<Vec<u16>> = entries.iter().map(|e| catalog_name(split_path(&e.path).1)).collect::<Result<_>>()?;
    let make_recs = |entries: &[Entry]| -> Vec<Rec> {
        let mut r: Vec<Rec> = Vec::with_capacity(entries.len() * 2 + 10);
        r.push(Rec { parent: 1, name: label16.clone(), data: folder_rec(ROOT_CNID, root_val, root_sub, t0, 0, 0, 0, 0o040755, 0) });
        r.push(Rec { parent: ROOT_CNID, name: vec![], data: thread_rec(true, 1, &label16) });
        r.push(Rec { parent: ROOT_CNID, name: private16.clone(), data: folder_rec(18, 0, 0, t0, 0, 0, 0, 0o040000, 0x5000) });
        r.push(Rec { parent: 18, name: vec![], data: thread_rec(true, ROOT_CNID, &private16) });
        r.push(Rec {
            parent: ROOT_CNID,
            name: jname.clone(),
            data: file_rec(16, t0, 0, 0, 0, 0o100000, b"jrnl", b"hfs+", 0x5000, JOURNAL_BYTES, journal_block as u32, journal_blocks as u32),
        });
        r.push(Rec { parent: 16, name: vec![], data: thread_rec(false, ROOT_CNID, &jname) });
        r.push(Rec { parent: ROOT_CNID, name: jiname.clone(), data: file_rec(17, t0, 0, 0, 0, 0o100000, b"jrnl", b"hfs+", 0x5000, BS, jib_block as u32, 1) });
        r.push(Rec { parent: 17, name: vec![], data: thread_rec(false, ROOT_CNID, &jiname) });
        for (e, name) in entries.iter().zip(&names) {
            let t = hfs_time(e.mtime);
            match e.kind {
                Kind::Dir => r.push(Rec { parent: e.parent, name: name.clone(), data: folder_rec(e.cnid, e.valence, e.subdirs, t, e.uid, e.gid, e.flags, e.mode, 0) }),
                Kind::File => r.push(Rec {
                    parent: e.parent,
                    name: name.clone(),
                    data: file_rec(e.cnid, t, e.uid, e.gid, e.flags, e.mode, b"\0\0\0\0", b"\0\0\0\0", 0, e.size, e.start, e.blocks),
                }),
                Kind::Link => r.push(Rec {
                    parent: e.parent,
                    name: name.clone(),
                    data: file_rec(e.cnid, t, e.uid, e.gid, e.flags, e.mode, b"slnk", b"rhap", 0, e.size, e.start, e.blocks),
                }),
            }
            r.push(Rec { parent: e.cnid, name: vec![], data: thread_rec(e.kind == Kind::Dir, e.parent, name) });
        }
        r.par_sort_by(|a, b| (a.parent, &a.name).cmp(&(b.parent, &b.name)));
        r
    };
    let recs = make_recs(&entries);
    for w in recs.windows(2) {
        ensure!((w[0].parent, &w[0].name) != (w[1].parent, &w[1].name), "two names in one folder are the same after decomposition: {:?}", String::from_utf16_lossy(&w[0].name));
    }
    let (nodes, _) = build_catalog(&recs)?;
    let used = nodes.len() as u64;
    // room to grow on the phone: half again, at least 64 MiB
    let total_nodes = (used + used / 2 + (64 << 20) / CAT_NODE as u64).min(MAX_HDR_MAP_NODES);
    ensure!(used <= total_nodes, "catalog of {used} nodes: more than this tool's map node");
    let cat_blocks = total_nodes * CAT_NODE as u64 / BS;
    // file data
    let mut next = cat_block + cat_blocks;
    for e in entries.iter_mut() {
        if e.kind != Kind::Dir && e.size > 0 {
            let b = e.size.div_ceil(BS);
            e.start = next as u32;
            e.blocks = b as u32;
            next += b;
        }
    }
    let used_blocks = next + 1; // + the last block, with the alternate header
    ensure!(used_blocks < total_blocks, "the data needs {used_blocks} blocks, the volume has {total_blocks}");
    let free_blocks = total_blocks - used_blocks;
    ensure!(free_blocks * BS >= o.min_free, "free space {} bytes after the data: the minimum is {}", free_blocks * BS, o.min_free);
    let recs = make_recs(&entries);
    let (mut nodes, info) = build_catalog(&recs)?;
    nodes[0] = header_node(CAT_NODE, &info, 516, total_nodes as u32, used as u32, (32 << 20) as u32, 0xBC, 6);

    let img = File::options().read(true).write(true).create(true).truncate(true).open(o.out).with_context(|| format!("create {:?}", o.out))?;
    img.set_len(o.size)?;
    // catalog
    nodes.par_iter().enumerate().try_for_each(|(i, n)| write_all_at(&img, n, cat_block * BS + (i * CAT_NODE) as u64))?;
    // extents and attributes: empty trees
    let empty = TreeInfo { depth: 0, root: 0, leaf_records: 0, first_leaf: 0, last_leaf: 0 };
    let eh = header_node(EXT_NODE, &empty, 10, (EXT_BYTES / EXT_NODE as u64) as u32, 1, EXT_BYTES as u32, 0, 2);
    write_all_at(&img, &eh, ext_block * BS)?;
    let ah = header_node(ATTR_NODE, &empty, 266, (ATTR_BYTES / ATTR_NODE as u64) as u32, 1, ATTR_BYTES as u32, 0, 6);
    write_all_at(&img, &ah, attr_block * BS)?;
    // journal info block: journal in the file system, make it at first mount (5, as mkfs.hfsplus -J)
    let mut jib = vec![0u8; BS as usize];
    jib[0..4].copy_from_slice(&5u32.to_be_bytes());
    jib[36..44].copy_from_slice(&(journal_block * BS).to_be_bytes());
    jib[44..52].copy_from_slice(&JOURNAL_BYTES.to_be_bytes());
    write_all_at(&img, &jib, jib_block * BS)?;
    // bitmap: blocks 0..next, and the last block
    let mut bm = vec![0u8; (bitmap_blocks * BS) as usize];
    let full = (next / 8) as usize;
    bm[..full].fill(0xFF);
    for b in full as u64 * 8..next {
        bm[(b / 8) as usize] |= 0x80 >> (b % 8);
    }
    let last = total_blocks - 1;
    bm[(last / 8) as usize] |= 0x80 >> (last % 8);
    write_all_at(&img, &bm, BS)?;
    // volume header
    let files = entries.iter().filter(|e| e.kind != Kind::Dir).count() as u32 + 2;
    let folders = entries.iter().filter(|e| e.kind == Kind::Dir).count() as u32 + 1;
    let mut vh = Vec::with_capacity(512);
    vh.extend_from_slice(b"HX");
    be16(&mut vh, 5);
    be32(&mut vh, 0x8000_2100); // unmounted, journaled, as the booted root
    vh.extend_from_slice(b"H+Lx");
    be32(&mut vh, jib_block as u32);
    for t in [t0, t0, 0, t0] {
        be32(&mut vh, t);
    }
    be32(&mut vh, files);
    be32(&mut vh, folders);
    be32(&mut vh, BS as u32);
    be32(&mut vh, total_blocks as u32);
    be32(&mut vh, free_blocks as u32);
    be32(&mut vh, next as u32);
    be32(&mut vh, 65536);
    be32(&mut vh, 65536);
    be32(&mut vh, next_id);
    be32(&mut vh, 1);
    be64(&mut vh, 1);
    vh.extend_from_slice(&[0u8; 32]);
    // clump sizes as mkfs.hfsplus: the volume grows its special files by these
    let fork_c = |b: &mut Vec<u8>, size: u64, clump: u32, blocks: u32, start: u32| {
        fork(b, size, blocks, start, blocks);
        let at = b.len() - 80 + 8;
        b[at..at + 4].copy_from_slice(&clump.to_be_bytes());
    };
    fork_c(&mut vh, bm.len() as u64, 65536, bitmap_blocks as u32, 1);
    fork_c(&mut vh, EXT_BYTES, EXT_BYTES as u32, ext_blocks as u32, ext_block as u32);
    fork_c(&mut vh, cat_blocks * BS, 32 << 20, cat_blocks as u32, cat_block as u32);
    fork_c(&mut vh, ATTR_BYTES, ATTR_BYTES as u32, attr_blocks as u32, attr_block as u32);
    fork(&mut vh, 0, 0, 0, 0);
    debug_assert_eq!(vh.len(), 512);
    write_all_at(&img, &vh, 1024)?;
    write_all_at(&img, &vh, o.size - 1024)?;

    // data, in parallel, with the hashes of the manifest
    let done = AtomicU64::new(0);
    let total_data: u64 = entries.iter().filter(|e| e.kind == Kind::File).map(|e| e.size).sum();
    let hashes: Vec<Option<String>> = entries
        .par_iter()
        .map(|e| -> Result<Option<String>> {
            match e.kind {
                Kind::Dir => Ok(None),
                Kind::Link => {
                    if e.size > 0 {
                        write_all_at(&img, &e.src, e.start as u64 * BS)?;
                    }
                    Ok(None)
                }
                Kind::File => {
                    let p = std::ffi::OsStr::from_encoded_bytes_unchecked_safe(&e.src);
                    let f = File::open(p).with_context(|| format!("open source of {}", String::from_utf8_lossy(&e.path)))?;
                    let mut h = Sha256::new();
                    let mut off = 0u64;
                    let mut buf = vec![0u8; 1 << 20];
                    let base = e.start as u64 * BS;
                    while off < e.size {
                        let want = ((e.size - off) as usize).min(buf.len());
                        let n = f.read_at(&mut buf[..want], off).with_context(|| format!("read source of {}", String::from_utf8_lossy(&e.path)))?;
                        ensure!(n != 0, "short source: {} at {off} of {}", String::from_utf8_lossy(&e.path), e.size);
                        h.update(&buf[..n]);
                        write_all_at(&img, &buf[..n], base + off)?;
                        off += n as u64;
                    }
                    let d = done.fetch_add(e.size, Ordering::Relaxed) + e.size;
                    if d >> 31 != (d - e.size) >> 31 {
                        eprintln!("hfs-build: {} of {} MiB", d >> 20, total_data >> 20);
                    }
                    Ok(Some(h.finalize().iter().map(|b| format!("{b:02x}")).collect()))
                }
            }
        })
        .collect::<Result<_>>()?;
    img.sync_all()?;
    // manifest
    let mut m = BufWriter::new(File::create(o.manifest).with_context(|| format!("create {:?}", o.manifest))?);
    writeln!(m, "# hfs-build manifest: TYPE MODE UID GID FLAGS SIZE SHA256_OR_TARGET PATH, split by NUL; one entry per line")?;
    writeln!(m, "# volume bytes {} block 4096 free-bytes {} files {} folders {} next-block {}", o.size, free_blocks * BS, files - 2, folders - 1, next)?;
    for (e, h) in entries.iter().zip(&hashes) {
        let t = match e.kind {
            Kind::Dir => "d",
            Kind::File => "f",
            Kind::Link => "l",
        };
        m.write_all(t.as_bytes())?;
        write!(m, "\0{:o}\0{}\0{}\0{}\0{}\0", e.mode, e.uid, e.gid, e.flags, e.size)?;
        match (e.kind, h) {
            (Kind::File, Some(s)) => m.write_all(s.as_bytes())?,
            (Kind::Link, _) => m.write_all(&e.src)?,
            _ => {}
        }
        m.write_all(b"\0")?;
        m.write_all(&e.path)?;
        m.write_all(b"\n")?;
    }
    m.flush()?;
    println!(
        "hfs-build: {} files + symlinks, {} folders, {} MiB data, catalog {} of {} nodes, {} MiB free of {} MiB, {:?}",
        files - 2,
        folders - 1,
        total_data >> 20,
        used,
        total_nodes,
        (free_blocks * BS) >> 20,
        o.size >> 20,
        o.out
    );
    Ok(())
}

/// A reader of its own: no code shared with the writer except the helpers. Checks the volume, then every file against the manifest.
pub fn verify(image: &Path, manifest: &Path) -> Result<()> {
    let img = File::open(image).with_context(|| format!("open {image:?}"))?;
    let size = img.metadata()?.len();
    let mut vh = vec![0u8; 512];
    img.read_exact_at(&mut vh, 1024)?;
    ensure!(&vh[0..2] == b"HX" && rd16(&vh, 2) == 5, "not HFSX");
    let mut alt = vec![0u8; 512];
    img.read_exact_at(&mut alt, size - 1024)?;
    ensure!(vh == alt, "alternate volume header differs");
    let bs = rd32(&vh, 40) as u64;
    let total = rd32(&vh, 44) as u64;
    ensure!(bs == BS && total * bs == size, "block size {bs}, {total} blocks, image {size} bytes");
    let free = rd32(&vh, 48) as u64;
    let fork_at = |i: usize| -> (u64, u64, u64) {
        let o = 112 + 80 * i;
        (rd64(&vh, o), rd32(&vh, o + 16) as u64, rd32(&vh, o + 20) as u64)
    };
    let (bm_len, bm_start, _) = fork_at(0);
    let (_, ext_start, ext_blocks) = fork_at(1);
    let (cat_len, cat_start, cat_blocks) = fork_at(2);
    let (_, attr_start, attr_blocks) = fork_at(3);
    let mut bm = vec![0u8; bm_len as usize];
    img.read_exact_at(&mut bm, bm_start * bs)?;
    let bit = |b: u64| bm[(b / 8) as usize] & (0x80 >> (b % 8)) != 0;
    let set_bits: u64 = bm.iter().map(|b| b.count_ones() as u64).sum();
    ensure!(set_bits + free == total, "bitmap has {set_bits} set bits, header says {} used", total - free);
    let mut hdr = vec![0u8; CAT_NODE];
    img.read_exact_at(&mut hdr, cat_start * bs)?;
    ensure!(hdr[8] == 1, "catalog node 0 is not a header");
    let node_size = rd16(&hdr, 14 + 18) as usize;
    ensure!(node_size == CAT_NODE && hdr[14 + 37] == 0xBC, "catalog node size {node_size}, compare {:#x}", hdr[14 + 37]);
    let leaf_records = rd32(&hdr, 14 + 6) as u64;
    let first_leaf = rd32(&hdr, 14 + 10) as u64;
    let total_nodes = rd32(&hdr, 14 + 22) as u64;
    ensure!(total_nodes * node_size as u64 == cat_len && cat_len == cat_blocks * bs, "catalog size");
    // walk the leaves
    struct Item {
        parent: u32,
        name: Vec<u16>,
        rtype: i16,
        cnid: u32,
        valence: u32,
        subdirs: u32,
        mode: u16,
        uid: u32,
        gid: u32,
        admin: u8,
        owner: u8,
        size: u64,
        start: u64,
        blocks: u64,
        tparent: u32,
        tname: Vec<u16>,
    }
    let mut items: Vec<Item> = Vec::with_capacity(leaf_records as usize);
    let mut node = first_leaf;
    let mut prev: Option<(u32, Vec<u16>)> = None;
    let mut n = vec![0u8; node_size];
    let mut prev_node = 0u64;
    while node != 0 {
        img.read_exact_at(&mut n, cat_start * bs + node * node_size as u64)?;
        ensure!(n[8] == 0xFF, "node {node}: kind {}", n[8]);
        ensure!(rd32(&n, 4) as u64 == prev_node, "node {node}: back link");
        let cnt = rd16(&n, 10) as usize;
        for i in 0..cnt {
            let o = rd16(&n, node_size - 2 * (i + 1)) as usize;
            let kl = rd16(&n, o) as usize;
            let parent = rd32(&n, o + 2);
            let nl = rd16(&n, o + 6) as usize;
            ensure!(kl == 6 + 2 * nl, "key length at node {node} record {i}");
            let name: Vec<u16> = (0..nl).map(|c| rd16(&n, o + 8 + 2 * c)).collect();
            let key = (parent, name.clone());
            if let Some(p) = &prev {
                ensure!(*p < key, "keys out of order at node {node} record {i}");
            }
            prev = Some(key);
            let r = o + 2 + kl;
            let rtype = rd16(&n, r) as i16;
            let mut it = Item { parent, name, rtype, cnid: 0, valence: 0, subdirs: 0, mode: 0, uid: 0, gid: 0, admin: 0, owner: 0, size: 0, start: 0, blocks: 0, tparent: 0, tname: vec![] };
            match rtype {
                1 | 2 => {
                    it.valence = rd32(&n, r + 4);
                    it.cnid = rd32(&n, r + 8);
                    it.uid = rd32(&n, r + 32);
                    it.gid = rd32(&n, r + 36);
                    it.admin = n[r + 40];
                    it.owner = n[r + 41];
                    it.mode = rd16(&n, r + 42);
                    if rtype == 1 {
                        it.subdirs = rd32(&n, r + 84);
                    } else {
                        it.size = rd64(&n, r + 88);
                        it.start = rd32(&n, r + 104) as u64;
                        it.blocks = rd32(&n, r + 108) as u64;
                    }
                }
                3 | 4 => {
                    it.tparent = rd32(&n, r + 4);
                    let tl = rd16(&n, r + 8) as usize;
                    it.tname = (0..tl).map(|c| rd16(&n, r + 10 + 2 * c)).collect();
                }
                _ => bail!("record type {rtype} at node {node} record {i}"),
            }
            items.push(it);
        }
        prev_node = node;
        node = rd32(&n, 0) as u64;
    }
    ensure!(items.len() as u64 == leaf_records, "{} records, header says {leaf_records}", items.len());
    // folders, threads, paths
    let mut by_id: HashMap<u32, usize> = HashMap::with_capacity(items.len() / 2);
    for (i, it) in items.iter().enumerate() {
        if it.rtype <= 2 {
            ensure!(by_id.insert(it.cnid, i).is_none(), "CNID {} twice", it.cnid);
        }
    }
    let mut children: HashMap<u32, (u32, u32)> = HashMap::new();
    let mut threads = 0u64;
    for it in &items {
        if it.rtype >= 3 {
            threads += 1;
            let tgt = *by_id.get(&it.parent).with_context(|| format!("thread of {} has no record", it.parent))?;
            ensure!(items[tgt].parent == it.tparent && items[tgt].name == it.tname, "thread of {} does not match", it.parent);
            ensure!((items[tgt].rtype == 1) == (it.rtype == 3), "thread type of {}", it.parent);
        } else if it.parent != 1 {
            let c = children.entry(it.parent).or_default();
            c.0 += 1;
            c.1 += (it.rtype == 1) as u32;
        }
    }
    for it in items.iter().filter(|i| i.rtype == 1) {
        let c = children.get(&it.cnid).copied().unwrap_or((0, 0));
        ensure!(c.0 == it.valence && c.1 == it.subdirs, "folder {}: valence {}/{} subfolders {}/{}", it.cnid, it.valence, c.0, it.subdirs, c.1);
    }
    let mut extents: Vec<(u64, u64)> = vec![(0, 1), (bm_start, bm_len.div_ceil(bs)), (ext_start, ext_blocks), (cat_start, cat_blocks), (attr_start, attr_blocks), (total - 1, 1)];
    let mut path_of: HashMap<u32, Vec<u8>> = HashMap::new();
    path_of.insert(2, Vec::new());
    fn path_for(id: u32, items: &[Item], by_id: &HashMap<u32, usize>, memo: &mut HashMap<u32, Vec<u8>>) -> Result<Vec<u8>> {
        if let Some(p) = memo.get(&id) {
            return Ok(p.clone());
        }
        let it = &items[*by_id.get(&id).with_context(|| format!("no record for {id}"))?];
        let mut p = path_for(it.parent, items, by_id, memo)?;
        if !p.is_empty() {
            p.push(b'/');
        }
        let s = String::from_utf16(&it.name).map_err(|e| anyhow::anyhow!("name: {e}"))?;
        p.extend_from_slice(s.as_bytes());
        memo.insert(id, p.clone());
        Ok(p)
    }
    let mut seen: BTreeMap<Vec<u8>, usize> = BTreeMap::new();
    let (mut nfiles, mut nlinks, mut ndirs) = (0u64, 0u64, 0u64);
    for (i, it) in items.iter().enumerate() {
        if it.rtype > 2 || it.parent == 1 {
            continue;
        }
        if it.rtype == 2 && it.blocks > 0 {
            ensure!(it.start + it.blocks < total, "file {} outside the volume", it.cnid);
            ensure!(it.size <= it.blocks * bs && it.size > (it.blocks - 1) * bs, "file {}: size {} with {} blocks", it.cnid, it.size, it.blocks);
            extents.push((it.start, it.blocks));
        }
        if it.cnid == 16 || it.cnid == 17 || it.cnid == 18 {
            continue;
        }
        let p = path_for(it.cnid, &items, &by_id, &mut path_of)?;
        match it.rtype {
            1 => ndirs += 1,
            _ if it.mode & 0o170000 == 0o120000 => nlinks += 1,
            _ => nfiles += 1,
        }
        seen.insert(p, i);
    }
    // extents: no overlap, all in the bitmap, and nothing else in the bitmap
    extents.sort();
    let mut end = 0u64;
    let mut sum = 0u64;
    for (s, l) in &extents {
        ensure!(*s >= end, "extents overlap at block {s}");
        for b in *s..s + *l {
            ensure!(bit(b), "block {b} is used but free in the bitmap");
        }
        end = s + l;
        sum += l;
    }
    ensure!(sum == total - free, "files use {sum} blocks, the bitmap says {}", total - free);
    // the manifest
    let data = std::fs::read(manifest).with_context(|| format!("read {manifest:?}"))?;
    let mut lines = Vec::new();
    for l in data.split(|c| *c == b'\n') {
        if !l.is_empty() && l[0] != b'#' {
            lines.push(l);
        }
    }
    ensure!(lines.len() == seen.len(), "manifest has {} entries, the catalog {}", lines.len(), seen.len());
    let name_of = |p: &[u8]| -> Result<Vec<u8>> {
        // the catalog holds decomposed names: the manifest path is compared in the same form
        let mut out = Vec::new();
        for (k, part) in p.split(|c| *c == b'/').enumerate() {
            if k > 0 {
                out.push(b'/');
            }
            let n = catalog_name(part)?;
            out.extend_from_slice(String::from_utf16(&n).unwrap().as_bytes());
        }
        Ok(out)
    };
    let checked = lines
        .par_iter()
        .map(|l| -> Result<(u64, u64)> {
            let f: Vec<&[u8]> = l.split(|c| *c == 0).collect();
            ensure!(f.len() == 8, "manifest line with {} fields", f.len());
            let path = name_of(f[7])?;
            let i = *seen.get(&path).with_context(|| format!("{} is not in the image", String::from_utf8_lossy(&path)))?;
            let it = &items[i];
            let shown = String::from_utf8_lossy(&path).to_string();
            let mode = u32::from_str_radix(std::str::from_utf8(f[1])?, 8)? as u16;
            let flags: u32 = std::str::from_utf8(f[4])?.parse()?;
            ensure!(it.mode == mode, "{shown}: mode {:o}, manifest {:o}", it.mode, mode);
            ensure!(it.uid.to_string().as_bytes() == f[2] && it.gid.to_string().as_bytes() == f[3], "{shown}: owner");
            ensure!(((it.admin as u32) << 16 | it.owner as u32) == flags, "{shown}: flags");
            match f[0] {
                b"d" => {
                    ensure!(it.rtype == 1, "{shown}: not a directory");
                    Ok((0, 0))
                }
                b"l" => {
                    ensure!(it.rtype == 2 && it.mode & 0o170000 == 0o120000, "{shown}: not a symlink");
                    let mut buf = vec![0u8; it.size as usize];
                    img.read_exact_at(&mut buf, it.start * bs)?;
                    ensure!(buf == f[6], "{shown}: link target");
                    Ok((0, 0))
                }
                b"f" => {
                    ensure!(it.rtype == 2 && it.mode & 0o170000 == 0o100000, "{shown}: not a file");
                    let want: u64 = std::str::from_utf8(f[5])?.parse()?;
                    ensure!(it.size == want, "{shown}: size {} manifest {want}", it.size);
                    let mut h = Sha256::new();
                    let mut buf = vec![0u8; 1 << 20];
                    let mut off = 0u64;
                    while off < it.size {
                        let w = ((it.size - off) as usize).min(buf.len());
                        img.read_exact_at(&mut buf[..w], it.start * bs + off)?;
                        h.update(&buf[..w]);
                        off += w as u64;
                    }
                    let got: String = h.finalize().iter().map(|b| format!("{b:02x}")).collect();
                    ensure!(got.as_bytes() == f[6], "{shown}: SHA-256 differs");
                    Ok((1, it.size))
                }
                _ => bail!("{shown}: manifest type"),
            }
        })
        .collect::<Result<Vec<_>>>()?;
    let hashed: u64 = checked.iter().map(|c| c.0).sum();
    let bytes: u64 = checked.iter().map(|c| c.1).sum();
    println!(
        "hfs-verify: OK: {} catalog records ({} threads), {} files, {} symlinks, {} folders; {} SHA-256 match, {} MiB; {} extents, none overlap, bitmap exact; {} MiB free of {} MiB",
        items.len(),
        threads,
        nfiles,
        nlinks,
        ndirs,
        hashed,
        bytes >> 20,
        extents.len(),
        (free * bs) >> 20,
        size >> 20
    );
    Ok(())
}

trait OsStrFromBytes {
    fn from_encoded_bytes_unchecked_safe(b: &[u8]) -> &std::ffi::OsStr;
}
impl OsStrFromBytes for std::ffi::OsStr {
    fn from_encoded_bytes_unchecked_safe(b: &[u8]) -> &std::ffi::OsStr {
        use std::os::unix::ffi::OsStrExt;
        std::ffi::OsStr::from_bytes(b)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names() {
        assert_eq!(catalog_name(b"abc").unwrap(), vec![97, 98, 99]);
        // e acute decomposes; a colon is stored as a slash
        assert_eq!(catalog_name("é".as_bytes()).unwrap(), vec![0x65, 0x301]);
        assert_eq!(catalog_name(b"a:b").unwrap(), vec![97, 47, 98]);
        // the CJK compatibility range stays
        assert_eq!(catalog_name("\u{F900}".as_bytes()).unwrap(), vec![0xF900]);
        assert!(catalog_name(b"").is_err());
        assert!(catalog_name(&[0xff]).is_err());
    }

    #[test]
    fn build_and_verify_small_volume() {
        let d = std::env::temp_dir().join(format!("hfs-test-{}", std::process::id()));
        std::fs::create_dir_all(&d).unwrap();
        let src = d.join("src.bin");
        std::fs::write(&src, vec![7u8; 10000]).unwrap();
        let spec = d.join("spec");
        let mut s = Vec::new();
        let mut add = |t: &str, m: &str, p: &[u8], so: &[u8]| {
            s.extend_from_slice(t.as_bytes());
            s.push(0);
            s.extend_from_slice(m.as_bytes());
            s.extend_from_slice(b"\x000\x000\x0010\x000\0");
            s.extend_from_slice(p);
            s.push(0);
            s.extend_from_slice(so);
            s.push(b'\n');
        };
        add("d", "755", b"usr", b"");
        add("d", "755", "usr/caf\u{e9}".as_bytes(), b"");
        add("f", "644", b"usr/a.bin", src.to_str().unwrap().as_bytes());
        add("l", "777", b"usr/link", b"a.bin");
        std::fs::write(&spec, &s).unwrap();
        let img = d.join("v.img");
        let man = d.join("m.txt");
        let o = BuildOpts { spec: &spec, out: &img, size: 128 << 20, label: "t", manifest: &man, min_free: 0, created: 10, max_size: 1 << 40 };
        build(&o).unwrap();
        verify(&img, &man).unwrap();
        // same input, same bytes
        let a = std::fs::read(&img).unwrap();
        build(&o).unwrap();
        assert!(a == std::fs::read(&img).unwrap());
        // one wrong byte in a file: found
        let f = File::options().write(true).open(&img).unwrap();
        let t = a.windows(10000).position(|w| w == vec![7u8; 10000].as_slice()).unwrap();
        f.write_all_at(&[8], t as u64).unwrap();
        assert!(verify(&img, &man).is_err());
        // bigger than the area: refused
        let o2 = BuildOpts { spec: &spec, out: &img, size: 128 << 20, label: "t", manifest: &man, min_free: 0, created: 10, max_size: 1 << 20 };
        assert!(build(&o2).is_err());
        std::fs::remove_dir_all(&d).unwrap();
    }
}
