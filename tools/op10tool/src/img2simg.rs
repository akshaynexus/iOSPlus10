//! Raw image <-> Android sparse image, with the `android-sparse` crate for the file format.
//!
//! img2simg keeps its own block classification, like AOSP img2simg:
//! - file holes (SEEK_DATA/SEEK_HOLE) -> Skip (DONT_CARE);
//! - data blocks that repeat one 32-bit word, zeros included -> Fill;
//! - other blocks -> Raw.
//! The crate's own Encoder turns every zero block into Skip. That is not safe for a filesystem image:
//! zero-filled file data (e.g. in the dyld shared cache) would keep whatever was on the partition.

use android_sparse::{Block, Reader, Writer};
use anyhow::{ensure, Context, Result};
use rayon::prelude::*;
use std::fs::File;
use std::io::{BufReader, BufWriter, Read, Seek, SeekFrom};
use std::os::unix::io::AsRawFd;
use std::path::Path;

const B: u64 = Block::SIZE as u64;

/// Data regions (start, end) in bytes; the whole file if SEEK_DATA is not supported.
fn data_ranges(f: &File, size: u64) -> Vec<(u64, u64)> {
    let fd = f.as_raw_fd();
    let mut out = Vec::new();
    let mut pos: i64 = 0;
    while (pos as u64) < size {
        let s = unsafe { libc::lseek(fd, pos, libc::SEEK_DATA) };
        if s < 0 {
            if std::io::Error::last_os_error().raw_os_error() == Some(libc::ENXIO) { break; }
            return vec![(0, size)];
        }
        let e = unsafe { libc::lseek(fd, s, libc::SEEK_HOLE) };
        if e < 0 { return vec![(0, size)]; }
        out.push((s as u64, e as u64));
        pos = e;
    }
    out
}

pub fn img2simg(input: &Path, output: &Path) -> Result<()> {
    let mut f = File::open(input).with_context(|| format!("open {}", input.display()))?;
    let size = f.metadata()?.len();
    ensure!(size % B == 0, "image size must be a multiple of {B}");
    let total = size / B;
    let mut w = Writer::new(BufWriter::with_capacity(1 << 22, File::create(output)?))?;
    let (mut raw, mut fill, mut skip) = (0u64, 0u64, 0u64);
    let mut blk = 0u64;
    const BATCH: u64 = 4096;                       // 16 MiB per read; blocks classified in parallel
    let mut buf = vec![0u8; (B * BATCH) as usize];
    for (s, e) in data_ranges(&f, size) {
        let (s, e) = (s / B, e.div_ceil(B));
        for _ in blk..s { w.write_block(&Block::Skip)?; skip += 1; }
        f.seek(SeekFrom::Start(s * B))?;
        let mut k = s;
        while k < e {
            let n = (e - k).min(BATCH) as usize;
            f.read_exact(&mut buf[..n * B as usize])?;
            let data = &buf[..n * B as usize];
            // Some(word) = the block repeats one 32-bit word (FILL); None = RAW
            let kinds: Vec<Option<[u8; 4]>> = data.par_chunks_exact(B as usize).map(|d| {
                let v = [d[0], d[1], d[2], d[3]];
                d.chunks_exact(4).all(|x| x == v).then_some(v)
            }).collect();
            for (d, kind) in data.chunks_exact(B as usize).zip(kinds) {
                match kind {
                    Some(v) => { w.write_block(&Block::Fill(v))?; fill += 1; }
                    None => { w.write_block(&Block::Raw(Box::new(d.try_into().unwrap())))?; raw += 1; }
                }
            }
            k += n as u64;
        }
        blk = e;
    }
    for _ in blk..total { w.write_block(&Block::Skip)?; skip += 1; }
    w.close()?;
    println!("{}: {total} blocks ({} MiB raw, {fill} fill, {skip} don't-care)", output.display(), raw * B >> 20);
    Ok(())
}

/// Sparse -> raw. DONT_CARE and zero-fill regions become file holes (a seek, no bytes written), so a
/// userdata-sized image (hundreds of GB of DONT_CARE at the end) costs only its data on an APFS/ext4
/// volume. The crate's Decoder writes zeros instead and filled the Mac disk (2026-10-26).
pub fn simg2img(input: &Path, output: &Path) -> Result<()> {
    let r = Reader::new(BufReader::with_capacity(1 << 22, File::open(input)?))?;
    let mut w = BufWriter::with_capacity(1 << 22, File::create(output)?);
    let (mut pos, mut data, mut holes) = (0u64, 0u64, 0u64);
    for b in r {
        match b? {
            Block::Raw(buf) => { std::io::Write::write_all(&mut w, &buf[..])?; pos += B; data += 1; }
            Block::Fill(v) if v == [0, 0, 0, 0] => { w.seek(SeekFrom::Start(pos + B))?; pos += B; holes += 1; }
            Block::Fill(v) => {
                let mut blk = [0u8; Block::SIZE as usize];
                for c in blk.chunks_exact_mut(4) { c.copy_from_slice(&v); }
                std::io::Write::write_all(&mut w, &blk)?; pos += B; data += 1;
            }
            Block::Skip => { w.seek(SeekFrom::Start(pos + B))?; pos += B; holes += 1; }
            Block::Crc32(_) => {}
        }
    }
    std::io::Write::flush(&mut w)?;
    w.get_ref().set_len(pos)?;
    println!("{} -> {} ({} MiB logical, {} data blocks, {} hole blocks)", input.display(), output.display(), pos >> 20, data, holes);
    Ok(())
}

/// HFS+ (HX) volume size from the volume header at byte 1024: blockSize (u32 BE at +0x28) x totalBlocks
/// (u32 BE at +0x2c). With `trim`, truncate the file to that size: `simg2img` gives a partition-sized
/// file (DONT_CARE to the end), and scripts/ios16/root-simg.sh needs the image below the firmware areas.
pub fn hfs_size(input: &Path, trim: bool) -> Result<()> {
    let mut f = std::fs::OpenOptions::new().read(true).write(trim).open(input)
        .with_context(|| format!("open {}", input.display()))?;
    let mut h = [0u8; 512];
    f.seek(SeekFrom::Start(1024))?;
    f.read_exact(&mut h)?;
    ensure!(&h[0..2] == b"HX" || &h[0..2] == b"H+", "{}: no HFS+ volume header at 1024", input.display());
    let bs = u32::from_be_bytes([h[0x28], h[0x29], h[0x2a], h[0x2b]]) as u64;
    let tb = u32::from_be_bytes([h[0x2c], h[0x2d], h[0x2e], h[0x2f]]) as u64;
    let size = bs * tb;
    let cur = f.metadata()?.len();
    println!("{}: HFS+ {} x {} = {} bytes ({} MiB), file {} bytes", input.display(), bs, tb, size, size >> 20, cur);
    if trim {
        ensure!(cur >= size, "file is shorter than the volume");
        f.set_len(size)?;
        println!("truncated to {size}");
    }
    Ok(())
}
