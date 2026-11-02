//! `simg-verify-list`: what a full read-back of a flashed sparse image must find (docs/laurel_sprout/dual-boot.md, step 6b).
//!
//! A sparse image has DON'T CARE chunks: the flash leaves the old bytes of the partition there, so a hash of the whole partition cannot match. This reads the chunks of the
//! .simg itself (what fastboot sends), and gives a list of the RAW and FILL block ranges, in order, and one CRC-32 over the bytes of those ranges. `ldbhelper root-verify` reads
//! the partition over the same ranges on the phone and computes the same CRC-32 (tools/laurel-dualboot/ldbhelper.c).
//!
//! Limit of the CRC-32: it finds accidental damage: every burst up to 32 bits, and other damage except 1 in 2^32. It does not find a change made on purpose.
//!
//! List file, little-endian: "LDBRNG1\0", u64 ranges, u64 blocks, u64 end (last block + 1), u64 FNV-1a of the range bytes (the same hash as a GPT plan), then per range u32 first, u32 count.

use anyhow::{bail, ensure, Context, Result};
use std::fs::File;
use std::io::{BufReader, BufWriter, Read, Write};
use std::path::Path;

pub const MAGIC: &[u8; 8] = b"LDBRNG1\0";
const SPARSE_MAGIC: u32 = 0xed26_ff3a;
const CHUNK_RAW: u16 = 0xcac1;
const CHUNK_FILL: u16 = 0xcac2;
const CHUNK_DONT_CARE: u16 = 0xcac3;
const CHUNK_CRC: u16 = 0xcac4;
/// The block of the partition: LUN 0 of the phone has 4096-byte logical blocks. ldbhelper reads whole blocks with O_DIRECT.
const BLK: u64 = 4096;

#[derive(Debug, Default, PartialEq)]
pub struct Summary {
    pub ranges: Vec<(u32, u32)>,
    pub raw: u64,
    pub fill: u64,
    pub dont_care: u64,
    pub total: u64,
    pub crc: u32,
}

impl Summary {
    pub fn blocks(&self) -> u64 { self.raw + self.fill }
    pub fn end(&self) -> u64 { self.ranges.last().map_or(0, |&(f, c)| u64::from(f) + u64::from(c)) }
}

fn le16(b: &[u8], o: usize) -> u16 { u16::from_le_bytes([b[o], b[o + 1]]) }
fn le32(b: &[u8], o: usize) -> u32 { u32::from_le_bytes([b[o], b[o + 1], b[o + 2], b[o + 3]]) }

/// Reads all chunks, checks that the file is what its header says, and hashes the bytes that the flash writes.
pub fn scan(r: &mut impl Read) -> Result<Summary> {
    let mut h = [0u8; 28];
    r.read_exact(&mut h).context("no sparse header")?;
    ensure!(le32(&h, 0) == SPARSE_MAGIC, "not a sparse image");
    ensure!(le16(&h, 4) == 1, "sparse major version {}", le16(&h, 4));
    let (file_hdr, chunk_hdr) = (u64::from(le16(&h, 8)), u64::from(le16(&h, 10)));
    let (blk, total, chunks) = (u64::from(le32(&h, 12)), u64::from(le32(&h, 16)), le32(&h, 20));
    ensure!(blk == BLK, "sparse block size {blk}, the partition has {BLK}");
    ensure!(file_hdr >= 28 && chunk_hdr >= 12, "sparse header sizes {file_hdr}, {chunk_hdr}");
    std::io::copy(&mut r.by_ref().take(file_hdr - 28), &mut std::io::sink())?;
    let mut s = Summary { total, ..Summary::default() };
    let mut crc = crc32fast::Hasher::new();
    let mut buf = vec![0u8; 1 << 22];
    let mut pos = 0u64;
    for n in 0..chunks {
        let mut c = [0u8; 12];
        r.read_exact(&mut c).with_context(|| format!("chunk {n}: the file ends"))?;
        std::io::copy(&mut r.by_ref().take(chunk_hdr - 12), &mut std::io::sink())?;
        let (kind, size, bytes) = (le16(&c, 0), u64::from(le32(&c, 4)), u64::from(le32(&c, 8)));
        ensure!(pos + size <= total, "chunk {n} ends past the {total} blocks of the header");
        let body = bytes.checked_sub(chunk_hdr).with_context(|| format!("chunk {n}: {bytes} bytes"))?;
        match kind {
            CHUNK_RAW => {
                ensure!(body == size * BLK, "chunk {n}: RAW of {size} blocks with {body} bytes");
                let mut left = body;
                while left > 0 {
                    let k = left.min(buf.len() as u64) as usize;
                    r.read_exact(&mut buf[..k]).with_context(|| format!("chunk {n}: the file ends"))?;
                    crc.update(&buf[..k]);
                    left -= k as u64;
                }
                s.raw += size;
            }
            CHUNK_FILL => {
                ensure!(body == 4, "chunk {n}: FILL with {body} bytes");
                let mut w = [0u8; 4];
                r.read_exact(&mut w).with_context(|| format!("chunk {n}: the file ends"))?;
                for b in buf.chunks_exact_mut(4) { b.copy_from_slice(&w); }
                let mut left = size * BLK;
                while left > 0 {
                    let k = left.min(buf.len() as u64) as usize;
                    crc.update(&buf[..k]);
                    left -= k as u64;
                }
                s.fill += size;
            }
            CHUNK_DONT_CARE => {
                ensure!(body == 0, "chunk {n}: DON'T CARE with {body} bytes");
                s.dont_care += size;
            }
            CHUNK_CRC => {
                // a checksum of the file so far: it covers no block
                ensure!(body == 4 && size == 0, "chunk {n}: CRC32 chunk of {size} blocks, {body} bytes");
                let mut w = [0u8; 4];
                r.read_exact(&mut w).with_context(|| format!("chunk {n}: the file ends"))?;
            }
            other => bail!("chunk {n}: unknown type {other:#x}"),
        }
        if size > 0 && (kind == CHUNK_RAW || kind == CHUNK_FILL) {
            match s.ranges.last_mut() {
                Some((f, cnt)) if u64::from(*f) + u64::from(*cnt) == pos => *cnt = u32::try_from(u64::from(*cnt) + size).context("a range over 2^32 blocks")?,
                _ => s.ranges.push((u32::try_from(pos).context("a block number over 2^32")?, u32::try_from(size).context("a range over 2^32 blocks")?)),
            }
        }
        pos += size;
    }
    ensure!(pos == total, "the chunks hold {pos} blocks, the header says {total}");
    let mut more = [0u8; 1];
    ensure!(r.read(&mut more)? == 0, "bytes after the last of {chunks} chunks");
    ensure!(!s.ranges.is_empty(), "no RAW or FILL block: nothing to read back");
    s.crc = crc.finalize();
    Ok(s)
}

pub fn list_bytes(s: &Summary) -> Vec<u8> {
    let mut body = Vec::with_capacity(s.ranges.len() * 8);
    for &(f, c) in &s.ranges {
        body.extend_from_slice(&f.to_le_bytes());
        body.extend_from_slice(&c.to_le_bytes());
    }
    let mut hash = 0xcbf2_9ce4_8422_2325u64;
    for &b in &body { hash = (hash ^ u64::from(b)).wrapping_mul(0x0000_0100_0000_01b3); }
    let mut out = Vec::with_capacity(40 + body.len());
    out.extend_from_slice(MAGIC);
    for v in [s.ranges.len() as u64, s.blocks(), s.end(), hash] { out.extend_from_slice(&v.to_le_bytes()); }
    out.extend_from_slice(&body);
    out
}

pub fn run(input: &Path, output: &Path) -> Result<()> {
    let f = File::open(input).with_context(|| format!("open {}", input.display()))?;
    let s = scan(&mut BufReader::with_capacity(1 << 22, f)).with_context(|| input.display().to_string())?;
    let tmp = output.with_extension("partial");
    {
        let mut w = BufWriter::new(File::create(&tmp).with_context(|| format!("create {}", tmp.display()))?);
        w.write_all(&list_bytes(&s))?;
        w.flush()?;
    }
    std::fs::rename(&tmp, output)?;
    println!("{}: {} blocks: {} raw, {} fill, {} don't care; {} ranges to read, {} MiB", input.display(), s.total, s.raw, s.fill, s.dont_care, s.ranges.len(), s.blocks() * BLK >> 20);
    // the one line that scripts read; `ldbhelper root-verify` prints the same words
    println!("verify ranges {} blocks {} end {} crc32 {:08x}", s.ranges.len(), s.blocks(), s.end(), s.crc);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn chunk(kind: u16, blocks: u32, body: &[u8]) -> Vec<u8> {
        let mut c = Vec::new();
        c.extend_from_slice(&kind.to_le_bytes());
        c.extend_from_slice(&[0, 0]);
        c.extend_from_slice(&blocks.to_le_bytes());
        c.extend_from_slice(&(12 + body.len() as u32).to_le_bytes());
        c.extend_from_slice(body);
        c
    }
    fn image(total: u32, chunks: &[Vec<u8>]) -> Vec<u8> {
        let mut h = Vec::new();
        h.extend_from_slice(&SPARSE_MAGIC.to_le_bytes());
        h.extend_from_slice(&[1, 0, 0, 0, 28, 0, 12, 0]);
        h.extend_from_slice(&4096u32.to_le_bytes());
        h.extend_from_slice(&total.to_le_bytes());
        h.extend_from_slice(&(chunks.len() as u32).to_le_bytes());
        h.extend_from_slice(&[0; 4]);
        for c in chunks { h.extend_from_slice(c); }
        h
    }

    #[test]
    fn simg_verify_ranges_and_crc_cover_raw_and_fill_only() {
        let raw = vec![0xabu8; 4096 * 2];
        let img = image(10, &[
            chunk(CHUNK_DONT_CARE, 1, &[]),
            chunk(CHUNK_RAW, 2, &raw),
            chunk(CHUNK_FILL, 1, &[1, 2, 3, 4]),
            chunk(CHUNK_CRC, 0, &[9, 9, 9, 9]),
            chunk(CHUNK_DONT_CARE, 3, &[]),
            chunk(CHUNK_FILL, 3, &[0, 0, 0, 0]),
        ]);
        let s = scan(&mut img.as_slice()).unwrap();
        assert_eq!(s.ranges, vec![(1, 3), (7, 3)]);
        assert_eq!((s.raw, s.fill, s.dont_care, s.blocks(), s.end()), (2, 4, 4, 6, 10));
        let mut want = crc32fast::Hasher::new();
        want.update(&raw);
        want.update(&[1, 2, 3, 4].repeat(1024));
        want.update(&vec![0u8; 3 * 4096]);
        assert_eq!(s.crc, want.finalize());
        let l = list_bytes(&s);
        assert_eq!(&l[..8], MAGIC);
        assert_eq!(l.len(), 40 + 2 * 8);
        assert_eq!(u32::from_le_bytes(l[48..52].try_into().unwrap()), 7);
    }

    #[test]
    fn simg_verify_refuses_a_file_that_is_not_what_its_header_says() {
        let raw = vec![1u8; 4096];
        let good = image(1, &[chunk(CHUNK_RAW, 1, &raw)]);
        assert!(scan(&mut good.as_slice()).is_ok());
        // cut short, a byte too many, too few blocks, too many blocks, an unknown chunk, RAW with the wrong size, no data at all, another block size
        assert!(scan(&mut good[..good.len() - 1].to_vec().as_slice()).is_err());
        let mut more = good.clone(); more.push(0);
        assert!(scan(&mut more.as_slice()).is_err());
        assert!(scan(&mut image(2, &[chunk(CHUNK_RAW, 1, &raw)]).as_slice()).is_err());
        assert!(scan(&mut image(1, &[chunk(CHUNK_RAW, 1, &raw), chunk(CHUNK_DONT_CARE, 1, &[])]).as_slice()).is_err());
        assert!(scan(&mut image(1, &[chunk(0xcac9, 1, &[])]).as_slice()).is_err());
        assert!(scan(&mut image(1, &[chunk(CHUNK_RAW, 1, &raw[..4095])]).as_slice()).is_err());
        assert!(scan(&mut image(1, &[chunk(CHUNK_DONT_CARE, 1, &[])]).as_slice()).is_err());
        let mut bs = good; bs[12] = 0; bs[13] = 2;
        assert!(scan(&mut bs.as_slice()).is_err());
    }

    #[test]
    fn simg_verify_equals_a_real_img2simg_output() {
        let d = std::env::temp_dir().join(format!("simg-verify-{}", std::process::id()));
        std::fs::create_dir_all(&d).unwrap();
        let (raw, simg) = (d.join("r.img"), d.join("r.simg"));
        // no HFS+ header: a hole stays DON'T CARE
        let f = File::create(&raw).unwrap();
        f.set_len(4096 * 64).unwrap();
        drop(f);
        let mut data = vec![0u8; 4096 * 64];
        for (i, b) in data[4096 * 8..4096 * 16].iter_mut().enumerate() { *b = (i * 7 % 251) as u8; }
        std::fs::write(&raw, &data).unwrap();
        crate::img2simg::img2simg(&raw, &simg).unwrap();
        let s = scan(&mut File::open(&simg).unwrap()).unwrap();
        let mut want = crc32fast::Hasher::new();
        for &(f, c) in &s.ranges { want.update(&data[f as usize * 4096..(f + c) as usize * 4096]); }
        assert_eq!(s.crc, want.finalize());
        assert_eq!(s.total, 64);
        std::fs::remove_dir_all(&d).unwrap();
    }
}
