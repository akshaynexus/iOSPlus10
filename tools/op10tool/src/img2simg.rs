//! Raw image <-> Android sparse image, with the `android-sparse` crate for the file format.
//!
//! img2simg keeps its own block classification, like AOSP img2simg:
//! - file holes (SEEK_DATA/SEEK_HOLE) -> Skip (DONT_CARE);
//! - data blocks that repeat one 32-bit word, zeros included -> Fill;
//! - other blocks -> Raw.
//! The crate's own Encoder turns every zero block into Skip. That is not safe for a filesystem image:
//! zero-filled file data (e.g. in the dyld shared cache) would keep whatever was on the partition.

use android_sparse::{Block, Decoder, Reader, Writer};
use anyhow::{ensure, Context, Result};
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
    let mut buf = vec![0u8; (B * 1024) as usize];
    for (s, e) in data_ranges(&f, size) {
        let (s, e) = (s / B, e.div_ceil(B));
        for _ in blk..s { w.write_block(&Block::Skip)?; skip += 1; }
        f.seek(SeekFrom::Start(s * B))?;
        let mut k = s;
        while k < e {
            let n = (e - k).min(1024) as usize;
            f.read_exact(&mut buf[..n * B as usize])?;
            for d in buf[..n * B as usize].chunks_exact(B as usize) {
                let v = [d[0], d[1], d[2], d[3]];
                if d.chunks_exact(4).all(|x| x == v) {
                    w.write_block(&Block::Fill(v))?; fill += 1;
                } else {
                    w.write_block(&Block::Raw(Box::new(d.try_into().unwrap())))?; raw += 1;
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

/// Sparse -> raw (for checks). DONT_CARE regions come out as zeros.
pub fn simg2img(input: &Path, output: &Path) -> Result<()> {
    let r = Reader::new(BufReader::with_capacity(1 << 22, File::open(input)?))?;
    let mut d = Decoder::new(File::create(output)?)?;
    for b in r { d.write_block(&b?)?; }
    d.close()?;
    println!("{} -> {}", input.display(), output.display());
    Ok(())
}
