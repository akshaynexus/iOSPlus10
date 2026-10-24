//! Raw image -> Android sparse image (libsparse format 1.0), same chunking as scripts' former
//! img2simg.py: file holes (SEEK_DATA/SEEK_HOLE) -> DONT_CARE, blocks that repeat one 32-bit word
//! -> FILL, other blocks -> RAW (max 4096 blocks per RAW chunk).

use anyhow::{ensure, Context, Result};
use std::fs::File;
use std::io::{BufWriter, Read, Seek, SeekFrom, Write};
use std::os::unix::io::AsRawFd;
use std::path::Path;

const MAGIC: u32 = 0xED26_FF3A;
const RAW: u16 = 0xCAC1;
const FILL: u16 = 0xCAC2;
const DONT_CARE: u16 = 0xCAC3;
const MAX_RAW: u32 = 4096;

/// Data regions (start, end) in bytes; the whole file if SEEK_DATA is not supported.
fn data_ranges(f: &File, size: u64) -> Vec<(u64, u64)> {
    let fd = f.as_raw_fd();
    let mut out = Vec::new();
    let mut pos: i64 = 0;
    while (pos as u64) < size {
        let s = unsafe { libc::lseek(fd, pos, libc::SEEK_DATA) };
        if s < 0 {
            let e = std::io::Error::last_os_error().raw_os_error();
            if e == Some(libc::ENXIO) { break; }      // no more data
            return vec![(0, size)];                     // not supported
        }
        let e = unsafe { libc::lseek(fd, s, libc::SEEK_HOLE) };
        if e < 0 { return vec![(0, size)]; }
        out.push((s as u64, e as u64));
        pos = e;
    }
    out
}

enum Chunk { Raw(u32, Vec<u8>), Fill(u32, [u8; 4]), DontCare(u32) }

pub fn run(input: &Path, output: &Path, block: u32) -> Result<()> {
    let b = block as u64;
    let mut f = File::open(input).with_context(|| format!("open {}", input.display()))?;
    let size = f.metadata()?.len();
    ensure!(size % b == 0, "image size must be a multiple of the block size");
    let total = (size / b) as u32;
    let ranges = data_ranges(&f, size);

    let mut chunks: Vec<Chunk> = Vec::new();
    let add_dont_care = |chunks: &mut Vec<Chunk>, n: u32| {
        if let Some(Chunk::DontCare(m)) = chunks.last_mut() { *m += n } else { chunks.push(Chunk::DontCare(n)) }
    };
    let mut blk: u64 = 0;
    let mut buf = vec![0u8; (b * 1024) as usize];
    for (s, e) in ranges {
        let (s, e) = (s / b, (e + b - 1) / b);
        if s > blk { add_dont_care(&mut chunks, (s - blk) as u32); }
        f.seek(SeekFrom::Start(s * b))?;
        let mut raw: Vec<u8> = Vec::new();
        let mut k = s;
        while k < e {
            let n = ((e - k) as usize).min(1024);
            let want = n * b as usize;
            let got = read_full(&mut f, &mut buf[..want])?;
            for i in 0..(got / b as usize) {
                let d = &buf[i * b as usize..(i + 1) * b as usize];
                let w = [d[0], d[1], d[2], d[3]];
                if d.chunks_exact(4).all(|x| x == w) {
                    if !raw.is_empty() {
                        chunks.push(Chunk::Raw((raw.len() as u64 / b) as u32, std::mem::take(&mut raw)));
                    }
                    match chunks.last_mut() {
                        Some(Chunk::Fill(m, v)) if *v == w => *m += 1,
                        _ => chunks.push(Chunk::Fill(1, w)),
                    }
                } else {
                    raw.extend_from_slice(d);
                    if raw.len() as u64 == MAX_RAW as u64 * b {
                        chunks.push(Chunk::Raw(MAX_RAW, std::mem::take(&mut raw)));
                    }
                }
            }
            k += n as u64;
        }
        if !raw.is_empty() { chunks.push(Chunk::Raw((raw.len() as u64 / b) as u32, raw)); }
        blk = e;
    }
    if blk < total as u64 { add_dont_care(&mut chunks, total - blk as u32); }

    let mut w = BufWriter::with_capacity(1 << 22, File::create(output)?);
    w.write_all(&MAGIC.to_le_bytes())?;
    for v in [1u16, 0, 28, 12] { w.write_all(&v.to_le_bytes())?; }
    for v in [block, total, chunks.len() as u32, 0] { w.write_all(&v.to_le_bytes())?; }
    let mut raw_blocks = 0u64;
    for c in &chunks {
        let (t, n, body): (u16, u32, &[u8]) = match c {
            Chunk::Raw(n, d) => { raw_blocks += *n as u64; (RAW, *n, d) }
            Chunk::Fill(n, v) => (FILL, *n, v),
            Chunk::DontCare(n) => (DONT_CARE, *n, &[]),
        };
        w.write_all(&t.to_le_bytes())?;
        w.write_all(&0u16.to_le_bytes())?;
        w.write_all(&n.to_le_bytes())?;
        w.write_all(&(12 + body.len() as u32).to_le_bytes())?;
        w.write_all(body)?;
    }
    w.flush()?;
    println!("{}: {} blocks, {} chunks, {} MiB raw data", output.display(), total, chunks.len(), raw_blocks * b >> 20);
    Ok(())
}

fn read_full(f: &mut File, buf: &mut [u8]) -> Result<usize> {
    let mut n = 0;
    while n < buf.len() {
        let r = f.read(&mut buf[n..])?;
        if r == 0 { break; }
        n += r;
    }
    Ok(n)
}
