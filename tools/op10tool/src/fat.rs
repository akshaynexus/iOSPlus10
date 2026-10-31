//! `op10tool fatls`: the FAT16/FAT32 index of a modem firmware image (NON-HLOS.bin or a dump of
//! modem_a/modem_b), made the same way as the kernel's (patches/laurel/xnu/2400: fat_mount,
//! fat_scan, fat_read_chain). It shows on the host what the phone will log and which files the
//! kernel will find, without firmware in git. Read-only.

use anyhow::{bail, Context, Result};
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;

// limits of the kernel parser (patch 2400 FAT_MAX_*); keep them equal
const MAX_FILES: usize = 4096;
const MAX_NAMES: usize = 256 << 10; // bytes of all paths, with their NULs
const MAX_DIR: u64 = 1 << 20;
const MAX_DIRS: u32 = 1024;
const MAX_DEPTH: u32 = 16;
const MAX_PATH: usize = 255;
const FAT32_MAX_CLUSTERS: u64 = 0x0fff_fff5;
/// modem_a / modem_b size on the Mi A3 (partition.xml: 184320 KiB); the kernel takes the GPT size
pub const MI_A3_MODEM_BYTES: u64 = 184320 * 1024;

pub struct Entry {
    pub path: String,
    pub clus: u32,
    pub size: u32,
    pub runs: u32,
}

pub struct Volume {
    f: File,
    pub bps: u32,
    pub clus_bytes: u32,
    pub kind: u32,
    nclus: u32,
    data_off: u64,
    fat: Vec<u8>,
    pub files: Vec<Entry>,
    names_used: usize,
    ndirs: u32,
    path_clus: Vec<u32>,
}

fn le16(b: &[u8], o: usize) -> u32 {
    u16::from_le_bytes([b[o], b[o + 1]]) as u32
}
fn le32(b: &[u8], o: usize) -> u32 {
    u32::from_le_bytes([b[o], b[o + 1], b[o + 2], b[o + 3]])
}

fn lower(ch: u32) -> char {
    match ch {
        0x41..=0x5a => char::from_u32(ch + 0x20).unwrap(),
        0x20..=0x7e => char::from_u32(ch).unwrap(),
        _ => '_',
    }
}

impl Volume {
    fn read_at(&mut self, off: u64, buf: &mut [u8]) -> Result<()> {
        self.f.seek(SeekFrom::Start(off))?;
        self.f.read_exact(buf).with_context(|| format!("read {} bytes at {:#x}", buf.len(), off))
    }

    fn valid(&self, c: u32) -> bool {
        c >= 2 && c < self.nclus + 2
    }

    fn next(&self, c: u32) -> u32 {
        if self.kind == 16 {
            let v = le16(&self.fat, 2 * c as usize);
            if v >= 0xfff7 { 0 } else { v }
        } else {
            let v = le32(&self.fat, 4 * c as usize) & 0x0fff_ffff;
            if v >= 0x0fff_fff7 { 0 } else { v }
        }
    }

    fn chain_clusters(&self, mut c: u32) -> u32 {
        let mut n = 0;
        while self.valid(c) && n <= self.nclus {
            n += 1;
            c = self.next(c);
        }
        n
    }

    /// n bytes at file offset off of the chain at clus, run by run (kernel fat_read_chain)
    pub fn read_chain(&mut self, mut clus: u32, off: u64, n: usize) -> Result<Vec<u8>> {
        let mut out = vec![0u8; n];
        let (mut pos, mut done, mut seen) = (0u64, 0usize, 0u32);
        while done < n {
            if !self.valid(clus) || seen > self.nclus {
                bail!("broken cluster chain at {clus}");
            }
            let mut run = 1;
            while seen + run <= self.nclus && self.next(clus + run - 1) == clus + run && self.valid(clus + run) {
                run += 1;
            }
            let bytes = run as u64 * self.clus_bytes as u64;
            let at = off + done as u64;
            if at < pos + bytes {
                let inn = at - pos;
                let take = (bytes - inn).min((n - done) as u64) as usize;
                let o = self.data_off + (clus - 2) as u64 * self.clus_bytes as u64 + inn;
                let mut tmp = vec![0u8; take];
                self.read_at(o, &mut tmp)?;
                out[done..done + take].copy_from_slice(&tmp);
                done += take;
            }
            pos += bytes;
            seen += run;
            clus = self.next(clus + run - 1);
        }
        Ok(out)
    }

    fn add(&mut self, path: String, clus: u32, size: u32) {
        if self.files.len() >= MAX_FILES || self.names_used + path.len() + 1 > MAX_NAMES {
            return;
        }
        self.names_used += path.len() + 1;
        let want = (size as u64).div_ceil(self.clus_bytes as u64).min(self.nclus as u64) as u32;
        let (mut c, mut runs) = (clus, 0);
        for _ in 0..want {
            if !self.valid(c) {
                break;
            }
            let nx = self.next(c);
            if nx != c + 1 {
                runs += 1;
            }
            c = nx;
        }
        self.files.push(Entry { path, clus, size, runs });
    }

    fn scan(&mut self, dir: &str, buf: &[u8], depth: u32) -> Result<()> {
        const AT: [usize; 13] = [1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30];
        let mut lfn = [0u8; 256];
        let (mut lfn_sum, mut lfn_ok) = (0u8, false);
        for e in buf.chunks_exact(32) {
            if e[0] == 0 {
                break;
            }
            if e[0] == 0xe5 {
                lfn_ok = false;
                continue;
            }
            if e[11] & 0x3f == 0x0f {
                let ord = (e[0] & 0x1f) as usize;
                if ord == 0 || ord > 19 {
                    lfn_ok = false;
                    continue;
                }
                if e[0] & 0x40 != 0 {
                    lfn = [0; 256];
                    lfn_sum = e[13];
                    lfn_ok = true;
                } else if e[13] != lfn_sum {
                    lfn_ok = false;
                }
                for (k, &a) in AT.iter().enumerate() {
                    let i = (ord - 1) * 13 + k;
                    if i < lfn.len() - 1 {
                        let ch = le16(e, a);
                        lfn[i] = if ch == 0 || ch == 0xffff { 0 } else { lower(ch) as u8 };
                    }
                }
                continue;
            }
            if e[11] & 0x08 != 0 {
                lfn_ok = false;
                continue;
            }
            let sum = e[..11].iter().fold(0u8, |s, &b| ((s & 1) << 7).wrapping_add(s >> 1).wrapping_add(b));
            let name: String = if lfn_ok && sum == lfn_sum && lfn[0] != 0 {
                lfn.iter().take_while(|&&b| b != 0).map(|&b| b as char).collect()
            } else {
                let mut n: String = e[..8]
                    .iter()
                    .enumerate()
                    .take_while(|(_, &b)| b != b' ')
                    .map(|(k, &b)| lower(if k == 0 && b == 0x05 { 0xe5 } else { b as u32 }))
                    .collect();
                if e[8] != b' ' {
                    n.push('.');
                    n.extend(e[8..11].iter().take_while(|&&b| b != b' ').map(|&b| lower(b as u32)));
                }
                n
            };
            lfn_ok = false;
            if name.is_empty() || name == "." || name == ".." {
                continue;
            }
            let clus = le16(e, 26) | if self.kind == 32 { le16(e, 20) << 16 } else { 0 };
            let path = if dir.is_empty() { name } else { format!("{dir}/{name}") };
            if path.len() > MAX_PATH {
                continue;
            }
            if e[11] & 0x10 != 0 {
                let nc = self.chain_clusters(clus);
                let bytes = nc as u64 * self.clus_bytes as u64;
                let looped = self.path_clus[..=depth as usize].contains(&clus);
                if depth >= MAX_DEPTH || nc == 0 || bytes > MAX_DIR || looped || self.ndirs >= MAX_DIRS {
                    continue;
                }
                self.ndirs += 1;
                // a failed read skips this directory, like the kernel
                if let Ok(sub) = self.read_chain(clus, 0, bytes as usize) {
                    self.path_clus[depth as usize + 1] = clus;
                    self.scan(&path, &sub, depth + 1)?;
                }
            } else {
                self.add(path, clus, le32(e, 28));
            }
        }
        Ok(())
    }

    pub fn open(path: &Path, part_bytes: u64) -> Result<Volume> {
        let mut f = File::open(path).with_context(|| format!("open {}", path.display()))?;
        let mut bs = [0u8; 512];
        f.read_exact(&mut bs)?;
        if bs[510] != 0x55 || bs[511] != 0xaa {
            bail!("no boot sector signature");
        }
        let (bps, spc, rsvd, nfats, rootents) = (le16(&bs, 11), bs[13] as u32, le16(&bs, 14), bs[16] as u32, le16(&bs, 17));
        let total = if le16(&bs, 19) != 0 { le16(&bs, 19) } else { le32(&bs, 32) };
        let spf = if le16(&bs, 22) != 0 { le16(&bs, 22) } else { le32(&bs, 36) };
        if !(512..=4096).contains(&bps) || !bps.is_power_of_two() || spc == 0 || !spc.is_power_of_two()
            || rsvd == 0 || nfats == 0 || spf == 0 || total == 0
        {
            bail!("not a FAT volume (bps {bps} spc {spc} rsvd {rsvd} fats {nfats} spf {spf} total {total})");
        }
        let root_secs = (rootents * 32).div_ceil(bps);
        let first_data = rsvd as u64 + nfats as u64 * spf as u64 + root_secs as u64;
        if first_data >= total as u64 {
            bail!("data area outside the volume");
        }
        let nclus64 = (total as u64 - first_data) / spc as u64;
        if nclus64 > FAT32_MAX_CLUSTERS {
            bail!("{nclus64} clusters: more than FAT32 allows");
        }
        let nclus = nclus64 as u32;
        let kind = if nclus < 4085 { 12 } else if nclus < 65525 { 16 } else { 32 };
        if kind == 12 {
            bail!("FAT12 (the kernel reads FAT16 and FAT32 only)");
        }
        let fat_bytes = (nclus as u64 + 2) * (kind / 8) as u64;
        if fat_bytes > spf as u64 * bps as u64 || fat_bytes > 16 << 20 {
            bail!("FAT size {fat_bytes} does not fit");
        }
        let end = first_data * bps as u64 + nclus as u64 * (bps * spc) as u64;
        if end > part_bytes {
            bail!("data area ends at {end:#x}, past the partition ({part_bytes:#x} bytes)");
        }
        let mut v = Volume {
            f,
            bps,
            clus_bytes: bps * spc,
            kind,
            nclus,
            data_off: first_data * bps as u64,
            fat: vec![0; fat_bytes as usize],
            files: Vec::new(),
            names_used: 0,
            ndirs: 0,
            path_clus: vec![0; MAX_DEPTH as usize + 1],
        };
        let mut fat = vec![0u8; fat_bytes as usize];
        v.read_at(rsvd as u64 * bps as u64, &mut fat)?;
        v.fat = fat;
        let root = if kind == 16 {
            let mut r = vec![0u8; (root_secs * bps) as usize];
            v.read_at((rsvd as u64 + nfats as u64 * spf as u64) * bps as u64, &mut r)?;
            r
        } else {
            let rc = le32(&bs, 44);
            v.path_clus[0] = rc;
            let b = (v.chain_clusters(rc) as u64 * v.clus_bytes as u64).min(MAX_DIR);
            v.read_chain(rc, 0, b as usize)?
        };
        v.scan("", &root, 0)?;
        Ok(v)
    }
}

/// op10tool fatls IMAGE [PATH...]: summary line as the kernel logs it, then every file (or the named ones)
pub fn run(image: &Path, paths: &[String], part_bytes: u64) -> Result<()> {
    let mut v = Volume::open(image, part_bytes)?;
    let frag = v.files.iter().filter(|e| e.runs > 1).count();
    let mdt = v.files.iter().any(|e| e.path == "image/modem.mdt");
    println!(
        "{}: FAT{}, {}-byte sectors, {} KiB clusters, {} files ({} fragmented){}",
        image.display(),
        v.kind,
        v.bps,
        v.clus_bytes >> 10,
        v.files.len(),
        frag,
        if mdt { "" } else { ", no image/modem.mdt" }
    );
    let mut missing = false;
    if paths.is_empty() {
        for e in &v.files {
            println!("{:>10} clus {:>6} runs {:>3}  {}", e.size, e.clus, e.runs, e.path);
        }
    } else {
        for p in paths {
            let p = p.to_ascii_lowercase();
            match v.files.iter().position(|e| e.path == p) {
                Some(i) => {
                    let (clus, size, runs) = (v.files[i].clus, v.files[i].size, v.files[i].runs);
                    let data = v.read_chain(clus, 0, size as usize)?;
                    println!("{size:>10} clus {clus:>6} runs {runs:>3} crc32 {:08x}  {p}", crc32fast::hash(&data));
                }
                None => {
                    println!("{:>10}  {p}: not found", "-");
                    missing = true;
                }
            }
        }
    }
    if missing {
        bail!("some files are missing");
    }
    Ok(())
}
