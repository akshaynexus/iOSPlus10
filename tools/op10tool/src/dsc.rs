//! Read a split arm64e dyld shared cache and thin/fat arm64(e) Mach-O files: files, mappings, images, sections,
//! function starts, symbols, slide info v5. Nothing here writes.
//! Structures: dyld include/mach-o/dyld_cache_format.h, fixup-chains.h, xnu EXTERNAL_HEADERS/mach-o/loader.h.
//! Input files are untrusted: every read is bounds-checked and a bad structure is an error, never a panic in a slice.

#![allow(dead_code)] // fields of the on-disk formats, kept complete

use anyhow::{anyhow, bail, Context, Result};
use std::fs::File;
use std::os::fd::AsRawFd;
use std::path::{Path, PathBuf};

pub const LC_SEGMENT_64: u32 = 0x19;
pub const LC_SYMTAB: u32 = 0x2;
pub const LC_FUNCTION_STARTS: u32 = 0x26;
pub const LC_CODE_SIGNATURE: u32 = 0x1d;
pub const LC_DYLD_CHAINED_FIXUPS: u32 = 0x8000_0034;
pub const SECTION_INSTRUCTIONS: u32 = 0x8000_0400;
pub const VM_PROT_EXECUTE: u32 = 4;
pub const SLIDE_V5_NO_REBASE: u16 = 0xffff;
const HEADER_MAPPINGS: usize = 0x10;
const HEADER_SIGNATURE: usize = 0x28;
const HEADER_MAPPING_SLIDE: usize = 0x138;
const HEADER_SUBCACHES: usize = 0x188;
const HEADER_IMAGES: usize = 0x1c0;
const HEADER_CACHE_SUBTYPE: usize = 0x1c8;
const SUBCACHE_ENTRY: usize = 56;

/// Read-only file mapping.
pub struct Map {
    ptr: *const u8,
    len: usize,
}
unsafe impl Send for Map {}
unsafe impl Sync for Map {}
impl Map {
    pub fn open(path: &Path) -> Result<Map> {
        let file = File::open(path).with_context(|| format!("open {}", path.display()))?;
        let len = file.metadata()?.len() as usize;
        if len == 0 {
            return Ok(Map { ptr: std::ptr::NonNull::<u8>::dangling().as_ptr(), len: 0 });
        }
        // SAFETY: PROT_READ + MAP_PRIVATE of an open file; the Map owns the mapping until drop.
        let ptr = unsafe {
            libc::mmap(std::ptr::null_mut(), len, libc::PROT_READ, libc::MAP_PRIVATE, file.as_raw_fd(), 0)
        };
        if ptr == libc::MAP_FAILED {
            bail!("mmap {}", path.display());
        }
        Ok(Map { ptr: ptr as *const u8, len })
    }
    pub fn bytes(&self) -> &[u8] {
        // SAFETY: ptr/len describe the live mapping made in open().
        unsafe { std::slice::from_raw_parts(self.ptr, self.len) }
    }
}
impl Drop for Map {
    fn drop(&mut self) {
        if self.len != 0 {
            // SAFETY: the mapping of open().
            unsafe { libc::munmap(self.ptr as *mut libc::c_void, self.len) };
        }
    }
}

pub fn u32_at(b: &[u8], at: usize) -> Result<u32> {
    let s = b.get(at..at + 4).ok_or_else(|| anyhow!("read u32 at {at:#x} out of range"))?;
    Ok(u32::from_le_bytes(s.try_into().unwrap()))
}
pub fn u64_at(b: &[u8], at: usize) -> Result<u64> {
    let s = b.get(at..at + 8).ok_or_else(|| anyhow!("read u64 at {at:#x} out of range"))?;
    Ok(u64::from_le_bytes(s.try_into().unwrap()))
}
fn cstr(b: &[u8]) -> String {
    let end = b.iter().position(|&c| c == 0).unwrap_or(b.len());
    String::from_utf8_lossy(&b[..end]).into_owned()
}

#[derive(Clone, Copy, Debug)]
pub struct Mapping {
    pub address: u64,
    pub size: u64,
    pub fileoff: u64,
    pub maxprot: u32,
    pub initprot: u32,
}

#[derive(Clone, Copy, Debug)]
pub struct SlidMapping {
    pub address: u64,
    pub size: u64,
    pub fileoff: u64,
    pub slide_offset: u64,
    pub slide_size: u64,
    pub flags: u64,
    pub maxprot: u32,
    pub initprot: u32,
}

pub struct CacheFile {
    pub path: PathBuf,
    pub map: Map,
    pub mappings: Vec<Mapping>,
    pub slid: Vec<SlidMapping>,
    pub sig_offset: u64,
    pub sig_size: u64,
    pub vm_offset: u64,
    pub suffix: String,
}

impl CacheFile {
    fn open(path: &Path, vm_offset: u64, suffix: String) -> Result<CacheFile> {
        let map = Map::open(path)?;
        let d = map.bytes();
        if d.len() < 0x200 || !d.starts_with(b"dyld_v1") {
            bail!("{}: not a dyld cache file", path.display());
        }
        let (off, count) = (u32_at(d, HEADER_MAPPINGS)? as usize, u32_at(d, HEADER_MAPPINGS + 4)? as usize);
        let mut mappings = Vec::new();
        for i in 0..count {
            let a = off + 32 * i;
            mappings.push(Mapping {
                address: u64_at(d, a)?,
                size: u64_at(d, a + 8)?,
                fileoff: u64_at(d, a + 16)?,
                maxprot: u32_at(d, a + 24)?,
                initprot: u32_at(d, a + 28)?,
            });
        }
        let (off, count) = (u32_at(d, HEADER_MAPPING_SLIDE)? as usize, u32_at(d, HEADER_MAPPING_SLIDE + 4)? as usize);
        let mut slid = Vec::new();
        for i in 0..count {
            let a = off + 56 * i;
            slid.push(SlidMapping {
                address: u64_at(d, a)?,
                size: u64_at(d, a + 8)?,
                fileoff: u64_at(d, a + 16)?,
                slide_offset: u64_at(d, a + 24)?,
                slide_size: u64_at(d, a + 32)?,
                flags: u64_at(d, a + 40)?,
                maxprot: u32_at(d, a + 48)?,
                initprot: u32_at(d, a + 52)?,
            });
        }
        let (sig_offset, sig_size) = (u64_at(d, HEADER_SIGNATURE)?, u64_at(d, HEADER_SIGNATURE + 8)?);
        Ok(CacheFile { path: path.to_path_buf(), map, mappings, slid, sig_offset, sig_size, vm_offset, suffix })
    }
    pub fn data(&self) -> &[u8] {
        self.map.bytes()
    }
    /// File offset where the header and its two mapping tables end. All of it is in the first r-x mapping.
    pub fn header_end(&self) -> Result<u64> {
        let d = self.data();
        let (off, count) = (u32_at(d, HEADER_MAPPINGS)? as u64, u32_at(d, HEADER_MAPPINGS + 4)? as u64);
        let (slide_off, slide_count) = (u32_at(d, HEADER_MAPPING_SLIDE)? as u64, u32_at(d, HEADER_MAPPING_SLIDE + 4)? as u64);
        Ok((off + 32 * count).max(slide_off + 56 * slide_count))
    }
}

#[derive(Clone, Copy)]
struct Region {
    start: u64,
    size: u64,
    file: usize,
    fileoff: u64,
    maxprot: u32,
}

pub struct Cache {
    pub files: Vec<CacheFile>,
    regions: Vec<Region>,
    pub images: Vec<(u64, String)>,
    pub shared_region_start: u64,
    pub shared_region_size: u64,
    pub max_slide: u64,
}

impl Cache {
    pub fn open(main: &Path) -> Result<Cache> {
        let first = CacheFile::open(main, 0, String::new())?;
        let (shared_region_start, shared_region_size, max_slide) = {
            let h = first.data();
            (u64_at(h, 224)?, u64_at(h, 232)?, u64_at(h, 240)?)
        };
        let header_size = u32_at(first.data(), HEADER_MAPPINGS)? as usize; // the first mapping follows the header
        let (off, count) = if header_size > HEADER_SUBCACHES {
            let h = first.data();
            (u32_at(h, HEADER_SUBCACHES)? as usize, u32_at(h, HEADER_SUBCACHES + 4)? as usize)
        } else {
            (0, 0)
        };
        let mut entries = Vec::new();
        {
            let h = first.data();
            // Newer caches: entries of 56 bytes with a file suffix; older ones: 24 bytes, suffix ".N" [V dyld_cache_format.h]
            let wide = header_size > HEADER_CACHE_SUBTYPE;
            for i in 0..count {
                if wide {
                    let e = off + SUBCACHE_ENTRY * i;
                    let vm = u64_at(h, e + 16)?;
                    let suffix = cstr(h.get(e + 24..e + 56).ok_or_else(|| anyhow!("subcache entry out of range"))?);
                    entries.push((vm, suffix));
                } else {
                    let e = off + 24 * i;
                    entries.push((u64_at(h, e + 16)?, format!(".{}", i + 1)));
                }
            }
        }
        let (img_off, img_count) = {
            let h = first.data();
            if header_size > HEADER_IMAGES {
                (u32_at(h, HEADER_IMAGES)? as usize, u32_at(h, HEADER_IMAGES + 4)? as usize)
            } else {
                (u32_at(h, 0x18)? as usize, u32_at(h, 0x1c)? as usize)
            }
        };
        let mut images = Vec::new();
        {
            let h = first.data();
            for i in 0..img_count {
                let a = img_off + 32 * i;
                let po = u32_at(h, a + 24)? as usize;
                images.push((u64_at(h, a)?, cstr(h.get(po..).ok_or_else(|| anyhow!("image path out of range"))?)));
            }
        }
        let mut files = vec![first];
        for (vm, suffix) in entries {
            let name = format!("{}{}", main.display(), suffix);
            files.push(CacheFile::open(Path::new(&name), vm, suffix)?);
        }
        let mut regions = Vec::new();
        for (i, f) in files.iter().enumerate() {
            for m in &f.mappings {
                regions.push(Region { start: m.address, size: m.size, file: i, fileoff: m.fileoff, maxprot: m.maxprot });
            }
        }
        regions.sort_by_key(|r| r.start);
        Ok(Cache { files, regions, images, shared_region_start, shared_region_size, max_slide })
    }

    /// (file index, file offset, bytes left in the mapping) of an unslid address.
    pub fn locate(&self, addr: u64) -> Option<(usize, usize, u64)> {
        let i = self.regions.partition_point(|r| r.start <= addr);
        if i == 0 {
            return None;
        }
        let r = self.regions[i - 1];
        if addr < r.start + r.size {
            Some((r.file, (r.fileoff + addr - r.start) as usize, r.start + r.size - addr))
        } else {
            None
        }
    }

    pub fn read(&self, addr: u64, len: usize) -> Result<&[u8]> {
        let (f, off, room) = self.locate(addr).ok_or_else(|| anyhow!("{addr:#x} not mapped"))?;
        if room < len as u64 {
            bail!("{addr:#x}+{len:#x} crosses a mapping");
        }
        self.files[f].data().get(off..off + len).ok_or_else(|| anyhow!("{addr:#x} past end of file"))
    }

    /// Unslid ranges inside r-x mappings that no section owns and that are not free: each file's header and mapping tables, and
    /// all of a main file with no image (it holds the image table, the paths and the subcache table). dyld reads these bytes.
    pub fn reserved_ranges(&self) -> Result<Vec<(u64, u64)>> {
        let mut out = Vec::new();
        for (i, f) in self.files.iter().enumerate() {
            let Some(m) = f.mappings.first() else { continue };
            let end = m.address + m.size;
            let no_image = !self.images.iter().any(|(a, _)| *a >= m.address && *a < end);
            out.push((m.address, if i == 0 && no_image { end } else { m.address + f.header_end()?.min(m.size) }));
        }
        Ok(out)
    }

    /// (start, size, file index, fileoff, maxprot), sorted by address.
    pub fn all_regions(&self) -> Vec<(u64, u64, usize, u64, u32)> {
        self.regions.iter().map(|r| (r.start, r.size, r.file, r.fileoff, r.maxprot)).collect()
    }
    pub fn executable_regions(&self) -> Vec<(u64, u64, usize, u64)> {
        self.regions
            .iter()
            .filter(|r| r.maxprot & VM_PROT_EXECUTE != 0)
            .map(|r| (r.start, r.size, r.file, r.fileoff))
            .collect()
    }
}

#[derive(Clone, Debug)]
pub struct Segment {
    pub name: String,
    pub vmaddr: u64,
    pub vmsize: u64,
    pub fileoff: u64,
    pub filesize: u64,
}

#[derive(Clone, Debug)]
pub struct Section {
    pub segment: String,
    pub name: String,
    pub addr: u64,
    pub size: u64,
    pub fileoff: u32,
    pub flags: u32,
    pub reserved2: u32,
}

/// A parsed Mach-O header, from a cache image or a file.
#[derive(Clone, Debug, Default)]
pub struct Macho {
    pub cputype: u32,
    pub cpusubtype: u32,
    pub filetype: u32,
    pub sizeofcmds: u32,
    pub segments: Vec<Segment>,
    pub sections: Vec<Section>,
    pub function_starts: Option<(u32, u32)>,
    pub symtab: Option<(u32, u32, u32, u32)>,
    pub code_signature: Option<(u32, u32)>,
    pub chained_fixups: Option<(u32, u32)>,
}

impl Macho {
    /// `head` starts at the Mach-O header.
    pub fn parse(head: &[u8]) -> Result<Macho> {
        if u32_at(head, 0)? != 0xfeed_facf {
            bail!("no 64-bit Mach-O header");
        }
        let mut m = Macho {
            cputype: u32_at(head, 4)?,
            cpusubtype: u32_at(head, 8)?,
            filetype: u32_at(head, 12)?,
            sizeofcmds: u32_at(head, 20)?,
            ..Default::default()
        };
        let ncmds = u32_at(head, 16)? as usize;
        let mut at = 32usize;
        for _ in 0..ncmds {
            let cmd = u32_at(head, at)?;
            let size = u32_at(head, at + 4)? as usize;
            if size < 8 {
                bail!("bad load command size");
            }
            match cmd {
                LC_SEGMENT_64 => {
                    let name = cstr(head.get(at + 8..at + 24).ok_or_else(|| anyhow!("segment out of range"))?);
                    m.segments.push(Segment {
                        name: name.clone(),
                        vmaddr: u64_at(head, at + 24)?,
                        vmsize: u64_at(head, at + 32)?,
                        fileoff: u64_at(head, at + 40)?,
                        filesize: u64_at(head, at + 48)?,
                    });
                    let nsect = u32_at(head, at + 64)? as usize;
                    for s in 0..nsect {
                        let b = at + 72 + 80 * s;
                        m.sections.push(Section {
                            segment: name.clone(),
                            name: cstr(head.get(b..b + 16).ok_or_else(|| anyhow!("section out of range"))?),
                            addr: u64_at(head, b + 32)?,
                            size: u64_at(head, b + 40)?,
                            fileoff: u32_at(head, b + 48)?,
                            flags: u32_at(head, b + 64)?,
                            reserved2: u32_at(head, b + 72)?,
                        });
                    }
                }
                LC_FUNCTION_STARTS => m.function_starts = Some((u32_at(head, at + 8)?, u32_at(head, at + 12)?)),
                LC_SYMTAB => {
                    m.symtab = Some((
                        u32_at(head, at + 8)?,
                        u32_at(head, at + 12)?,
                        u32_at(head, at + 16)?,
                        u32_at(head, at + 20)?,
                    ))
                }
                LC_CODE_SIGNATURE => m.code_signature = Some((u32_at(head, at + 8)?, u32_at(head, at + 12)?)),
                LC_DYLD_CHAINED_FIXUPS => m.chained_fixups = Some((u32_at(head, at + 8)?, u32_at(head, at + 12)?)),
                _ => {}
            }
            at += size;
        }
        Ok(m)
    }

    pub fn segment(&self, name: &str) -> Option<&Segment> {
        self.segments.iter().find(|s| s.name == name)
    }

    pub fn text_base(&self) -> u64 {
        self.segment("__TEXT").map(|s| s.vmaddr).unwrap_or(0)
    }

    pub fn instruction_sections(&self) -> impl Iterator<Item = &Section> {
        self.sections.iter().filter(|s| s.flags & SECTION_INSTRUCTIONS != 0 && s.size != 0)
    }
}

fn uleb(b: &[u8], at: &mut usize) -> Option<u64> {
    let (mut v, mut shift) = (0u64, 0u32);
    loop {
        let c = *b.get(*at)?;
        *at += 1;
        if shift < 64 {
            v |= ((c & 0x7f) as u64) << shift;
        }
        shift += 7;
        if c & 0x80 == 0 {
            return Some(v);
        }
    }
}

/// Decode LC_FUNCTION_STARTS: sorted addresses.
pub fn decode_function_starts(blob: &[u8], text_base: u64) -> Vec<u64> {
    let (mut out, mut at, mut addr) = (Vec::new(), 0usize, text_base);
    while at < blob.len() && blob[at] != 0 {
        match uleb(blob, &mut at) {
            Some(delta) => {
                addr = addr.wrapping_add(delta);
                out.push(addr);
            }
            None => break,
        }
    }
    out
}

/// Bytes of a Mach-O's LINKEDIT range through a reader closure working on vm addresses or file offsets.
pub fn image_function_starts(cache: &Cache, m: &Macho) -> Vec<u64> {
    let (Some((off, size)), Some(le)) = (m.function_starts, m.segment("__LINKEDIT")) else { return Vec::new() };
    if size == 0 {
        return Vec::new();
    }
    match cache.read(le.vmaddr + off as u64 - le.fileoff, size as usize) {
        Ok(blob) => decode_function_starts(blob, m.text_base()),
        Err(_) => Vec::new(),
    }
}

/// Defined symbols of a cache image: (address, name). The cache keeps exported names; local names are in the .symbols file.
pub fn image_symbols(cache: &Cache, m: &Macho) -> Vec<(u64, String)> {
    let (Some((symoff, nsyms, stroff, strsize)), Some(le)) = (m.symtab, m.segment("__LINKEDIT")) else {
        return Vec::new();
    };
    let base = le.vmaddr.wrapping_sub(le.fileoff);
    let Ok(syms) = cache.read(base + symoff as u64, nsyms as usize * 16) else { return Vec::new() };
    let Ok(strs) = cache.read(base + stroff as u64, strsize as usize) else { return Vec::new() };
    let mut out = Vec::new();
    for s in syms.chunks_exact(16) {
        let (strx, ntype) = (u32::from_le_bytes(s[0..4].try_into().unwrap()) as usize, s[4]);
        let value = u64::from_le_bytes(s[8..16].try_into().unwrap());
        if ntype & 0xe0 != 0 || ntype & 0x0e != 0x0e || value == 0 || strx >= strs.len() {
            continue;
        }
        out.push((value, cstr(&strs[strx..])));
    }
    out.sort();
    out
}

/// Local symbols of every image from the `.symbols` file next to the main cache: {image address: [(address, name)]}.
pub fn cache_local_symbols(main: &Path, cache: &Cache, want: &[u64]) -> Result<std::collections::HashMap<u64, Vec<(u64, String)>>> {
    let path = format!("{}.symbols", main.display());
    let map = Map::open(Path::new(&path))?;
    let d = map.bytes();
    let info = u64_at(d, 72)? as usize; // localSymbolsOffset
    let (nlist, _n, strings, _ss, entries, count) = (
        u32_at(d, info)? as usize,
        u32_at(d, info + 4)?,
        u32_at(d, info + 8)? as usize,
        u32_at(d, info + 12)?,
        u32_at(d, info + 16)? as usize,
        u32_at(d, info + 20)? as usize,
    );
    let mut out = std::collections::HashMap::new();
    for i in 0..count {
        let e = info + entries + i * 16;
        let image = u64_at(d, e)? + cache.shared_region_start;
        if !want.contains(&image) {
            continue;
        }
        let start = u32_at(d, e + 8)? as usize;
        let n = u32_at(d, e + 12)? as usize;
        let mut v = Vec::with_capacity(n);
        for k in 0..n {
            let a = info + nlist + (start + k) * 16;
            let strx = u32_at(d, a)? as usize;
            let value = u64_at(d, a + 8)?;
            let Some(name) = d.get(info + strings + strx..) else { continue };
            if value != 0 {
                v.push((value, cstr(name)));
            }
        }
        v.sort();
        out.insert(image, v);
    }
    Ok(out)
}

/// Every thin arm64 or arm64e slice of a Mach-O or fat file: (offset, length).
pub fn macho_slices(d: &[u8]) -> Vec<(usize, usize)> {
    if d.len() < 32 {
        return Vec::new();
    }
    let magic_be = u32::from_be_bytes(d[0..4].try_into().unwrap());
    if magic_be == 0xcafe_babe || magic_be == 0xcafe_babf {
        let wide = magic_be == 0xcafe_babf;
        let n = u32::from_be_bytes(d[4..8].try_into().unwrap()) as usize;
        let mut out = Vec::new();
        for i in 0..n.min(32) {
            let a = 8 + i * if wide { 32 } else { 20 };
            let Some(e) = d.get(a..a + if wide { 32 } else { 20 }) else { break };
            let cpu = u32::from_be_bytes(e[0..4].try_into().unwrap());
            let (off, len) = if wide {
                (
                    u64::from_be_bytes(e[8..16].try_into().unwrap()) as usize,
                    u64::from_be_bytes(e[16..24].try_into().unwrap()) as usize,
                )
            } else {
                (
                    u32::from_be_bytes(e[8..12].try_into().unwrap()) as usize,
                    u32::from_be_bytes(e[12..16].try_into().unwrap()) as usize,
                )
            };
            if cpu == 0x0100_000c && off.checked_add(len).is_some_and(|end| end <= d.len()) {
                out.push((off, len));
            }
        }
        return out;
    }
    if u32::from_le_bytes(d[0..4].try_into().unwrap()) == 0xfeed_facf
        && u32::from_le_bytes(d[4..8].try_into().unwrap()) == 0x0100_000c
    {
        return vec![(0, d.len())];
    }
    Vec::new()
}

/// One slide info v5 pointer word, by its fields.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SlideV5 {
    pub raw: u64,
}
impl SlideV5 {
    pub fn auth(self) -> bool {
        self.raw >> 63 != 0
    }
    pub fn next(self) -> u64 {
        (self.raw >> 52) & 0x7ff
    }
    pub fn runtime_offset(self) -> u64 {
        self.raw & 0x3_ffff_ffff
    }
    pub fn diversity(self) -> u64 {
        (self.raw >> 34) & 0xffff
    }
    pub fn addr_div(self) -> bool {
        (self.raw >> 50) & 1 != 0
    }
    pub fn key_is_data(self) -> bool {
        (self.raw >> 51) & 1 != 0
    }
    pub fn high8(self) -> u64 {
        (self.raw >> 34) & 0xff
    }
    /// The same entry as a plain rebase: keep offset and next; clear auth, diversity, addrDiv, keyIsData. high8 = 0.
    pub fn as_plain(self) -> u64 {
        self.raw & (0x3_ffff_ffff | (0x7ff << 52))
    }
}

#[derive(Default, Clone, Copy, Debug)]
pub struct SlideCounts {
    pub pages: u64,
    pub pages_with_rebases: u64,
    pub plain: u64,
    pub plain_high8: u64,
    pub auth: u64,
    pub auth_ia: u64,
    pub auth_da: u64,
    pub auth_addr_div: u64,
    pub auth_zero_div: u64,
}

/// Walk one slid mapping's slide info v5. `f` gets (file offset of the pointer, entry).
pub fn walk_slide_v5(file: &CacheFile, s: &SlidMapping, mut f: impl FnMut(usize, SlideV5)) -> Result<SlideCounts> {
    let d = file.data();
    let info = s.slide_offset as usize;
    let version = u32_at(d, info)?;
    if version != 5 {
        bail!("{}: slide info version {version}, expected 5", file.path.display());
    }
    let page_size = u32_at(d, info + 4)? as usize;
    let count = u32_at(d, info + 8)? as usize;
    let mut c = SlideCounts { pages: count as u64, ..Default::default() };
    for page in 0..count {
        let raw = d.get(info + 24 + page * 2..info + 26 + page * 2).ok_or_else(|| anyhow!("page start out of range"))?;
        let delta = u16::from_le_bytes(raw.try_into().unwrap());
        if delta == SLIDE_V5_NO_REBASE {
            continue;
        }
        c.pages_with_rebases += 1;
        let mut at = s.fileoff as usize + page * page_size + delta as usize;
        loop {
            let e = SlideV5 { raw: u64_at(d, at)? };
            if e.auth() {
                c.auth += 1;
                if e.key_is_data() {
                    c.auth_da += 1
                } else {
                    c.auth_ia += 1
                }
                if e.addr_div() {
                    c.auth_addr_div += 1
                }
                if e.diversity() == 0 {
                    c.auth_zero_div += 1
                }
            } else {
                c.plain += 1;
                if e.high8() != 0 {
                    c.plain_high8 += 1
                }
            }
            f(at, e);
            if e.next() == 0 {
                break;
            }
            at += e.next() as usize * 8;
        }
    }
    Ok(c)
}
