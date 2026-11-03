//! `op10tool autotest-png`, `op10tool autotest-seq`: the host half of scripts/laurel/ios26-autotest.sh.
//! Input: what userland/laurel/autotest/laurel_autotest.m writes (LATF, LATS). Docs: docs/laurel_sprout/ios26-autotest.md.
//! Each frame record: 40 bytes little endian (magic LATF, surface, w, h, row, format, t_us u64, inferred, reserved), then h rows of `row` bytes, BGRA.
//! A sequence: magic LATS, then frame records at 1/4 size, one per change on the phone.

use anyhow::{bail, Context, Result};
use flate2::write::ZlibEncoder;
use flate2::Compression;
use std::fs;
use std::io::Write;
use std::path::Path;

const HEAD: usize = 40;
const BGRA: u32 = u32::from_be_bytes(*b"BGRA");
/// A pixel counts as changed if one channel moves more than this.
const PIXEL_DIFF: u8 = 8;
/// Two frames are the same picture if under this share of the pixels changed.
const SAME_SHARE: f64 = 0.002;
/// A return to an older picture counts only if the frame before it differs by at least this share: the last slow frames of an animation can differ by a little and come back.
const FLASH_SHARE: f64 = 0.02;
/// A pixel is dark at or below this value in all channels.
const DARK: u8 = 8;
/// A frame is mostly black from this share of dark pixels.
const BLACK_SHARE: f64 = 0.90;
/// How far back a frame looks for an older picture.
const WINDOW: usize = 8;

#[derive(Debug, Clone)]
pub struct Frame {
    pub surface: u32,
    pub w: usize,
    pub h: usize,
    pub t_us: u64,
    pub inferred: bool,
    /// BGRA, w * 4 bytes a row
    pub pixels: Vec<u8>,
}

fn u32_at(b: &[u8], at: usize) -> u32 {
    u32::from_le_bytes(b[at..at + 4].try_into().unwrap())
}

/// One frame record at the start of `b`; returns the frame and the bytes it used.
pub fn parse_frame(b: &[u8]) -> Result<(Frame, usize)> {
    if b.len() < HEAD {
        bail!("frame record cut: {} bytes, the head has {HEAD}", b.len());
    }
    if &b[..4] != b"LATF" {
        bail!("no LATF record: {:02x?}", &b[..4]);
    }
    let (surface, w, h, row, format) = (u32_at(b, 4), u32_at(b, 8) as usize, u32_at(b, 12) as usize, u32_at(b, 16) as usize, u32_at(b, 20));
    if format != BGRA {
        bail!("surface {surface}: format {format:#x}, only BGRA is known");
    }
    if w == 0 || h == 0 || w > 8192 || h > 8192 || row < w * 4 {
        bail!("surface {surface}: bad size {w}x{h}, row {row}");
    }
    let t_us = u64::from_le_bytes(b[24..32].try_into().unwrap());
    let inferred = u32_at(b, 32) != 0;
    let end = HEAD + row * h;
    if b.len() < end {
        bail!("frame record cut: {} bytes, it needs {end}", b.len());
    }
    let mut pixels = Vec::with_capacity(w * 4 * h);
    for y in 0..h {
        let at = HEAD + y * row;
        pixels.extend_from_slice(&b[at..at + w * 4]);
    }
    Ok((Frame { surface, w, h, t_us, inferred, pixels }, end))
}

fn png_chunk(out: &mut Vec<u8>, kind: &[u8; 4], data: &[u8]) {
    out.extend_from_slice(&(data.len() as u32).to_be_bytes());
    out.extend_from_slice(kind);
    out.extend_from_slice(data);
    let mut crc = crc32fast::Hasher::new();
    crc.update(kind);
    crc.update(data);
    out.extend_from_slice(&crc.finalize().to_be_bytes());
}

/// An RGB PNG with alpha dropped: the panel shows no alpha.
pub fn png_bytes(f: &Frame) -> Result<Vec<u8>> {
    let mut raw = Vec::with_capacity((f.w * 3 + 1) * f.h);
    for row in f.pixels.chunks_exact(f.w * 4) {
        raw.push(0);
        for p in row.chunks_exact(4) {
            raw.extend_from_slice(&[p[2], p[1], p[0]]);
        }
    }
    let mut z = ZlibEncoder::new(Vec::new(), Compression::fast());
    z.write_all(&raw)?;
    let idat = z.finish()?;
    let mut out = vec![0x89, b'P', b'N', b'G', 0x0d, 0x0a, 0x1a, 0x0a];
    let mut ihdr = Vec::with_capacity(13);
    ihdr.extend_from_slice(&(f.w as u32).to_be_bytes());
    ihdr.extend_from_slice(&(f.h as u32).to_be_bytes());
    ihdr.extend_from_slice(&[8, 2, 0, 0, 0]);
    png_chunk(&mut out, b"IHDR", &ihdr);
    png_chunk(&mut out, b"IDAT", &idat);
    png_chunk(&mut out, b"IEND", &[]);
    Ok(out)
}

/// Share of pixels with all channels at or below DARK.
pub fn dark_share(f: &Frame) -> f64 {
    let n = f.w * f.h;
    let dark = f.pixels.chunks_exact(4).filter(|p| p[0] <= DARK && p[1] <= DARK && p[2] <= DARK).count();
    dark as f64 / n as f64
}

/// Share of pixels that changed between two frames of the same size; 1.0 for other sizes.
pub fn diff_share(a: &Frame, b: &Frame) -> f64 {
    if a.w != b.w || a.h != b.h {
        return 1.0;
    }
    let changed = a
        .pixels
        .chunks_exact(4)
        .zip(b.pixels.chunks_exact(4))
        .filter(|(p, q)| (0..3).any(|i| p[i].abs_diff(q[i]) > PIXEL_DIFF))
        .count();
    changed as f64 / (a.w * a.h) as f64
}

#[derive(Debug, Default, PartialEq)]
pub struct Report {
    pub frames: usize,
    pub black: Vec<usize>,
    /// (frame, the older frame it equals)
    pub older: Vec<(usize, usize)>,
    pub surfaces: usize,
    pub span_ms: u64,
}

/// A frame is a return to an older state if it differs from the frame before it and equals a frame before that.
pub fn analyse(frames: &[Frame]) -> Report {
    let mut r = Report { frames: frames.len(), ..Default::default() };
    let mut ids: Vec<u32> = frames.iter().map(|f| f.surface).collect();
    ids.sort_unstable();
    ids.dedup();
    r.surfaces = ids.len();
    if let (Some(a), Some(b)) = (frames.first(), frames.last()) {
        r.span_ms = (b.t_us - a.t_us) / 1000;
    }
    for (i, f) in frames.iter().enumerate() {
        if dark_share(f) >= BLACK_SHARE {
            r.black.push(i);
        }
        if i < 2 || diff_share(f, &frames[i - 1]) < FLASH_SHARE {
            continue;
        }
        for j in (i.saturating_sub(WINDOW)..i - 1).rev() {
            if diff_share(f, &frames[j]) < SAME_SHARE {
                r.older.push((i, j));
                break;
            }
        }
    }
    r
}

/// `prev`: an earlier frame record; the line then also says how much of the picture changed.
pub fn run_png(input: &Path, output: &Path, prev: Option<&Path>) -> Result<()> {
    let b = fs::read(input).with_context(|| format!("read {}", input.display()))?;
    let (f, _) = parse_frame(&b)?;
    fs::write(output, png_bytes(&f)?).with_context(|| format!("write {}", output.display()))?;
    let mut line = format!(
        "{}: {}x{}, surface {} ({}), {:.1} % dark",
        output.display(),
        f.w,
        f.h,
        f.surface,
        if f.inferred { "inferred from in-use marks" } else { "named by the kernel" },
        dark_share(&f) * 100.0
    );
    if let Some(p) = prev {
        let old = fs::read(p).with_context(|| format!("read {}", p.display()))?;
        let (o, _) = parse_frame(&old)?;
        line += &format!(", {:.2} % changed", diff_share(&f, &o) * 100.0);
    }
    println!("{line}");
    Ok(())
}

pub fn parse_seq(b: &[u8]) -> Result<Vec<Frame>> {
    if b.len() < 4 || &b[..4] != b"LATS" {
        bail!("no LATS head");
    }
    let mut at = 4;
    let mut frames = Vec::new();
    while at < b.len() {
        // A cut last record is what a lost SSH leaves: keep what came before it.
        match parse_frame(&b[at..]) {
            Ok((f, n)) => {
                frames.push(f);
                at += n;
            }
            Err(e) if !frames.is_empty() => {
                eprintln!("autotest-seq: stop after {} frames: {e}", frames.len());
                break;
            }
            Err(e) => return Err(e),
        }
    }
    Ok(frames)
}

/// Writes frame-NNN.png for the frames worth a look, and prints one `seq:` line that the summary reads.
pub fn run_seq(input: &Path, outdir: &Path, all: bool) -> Result<()> {
    let b = fs::read(input).with_context(|| format!("read {}", input.display()))?;
    let frames = parse_seq(&b)?;
    let r = analyse(&frames);
    fs::create_dir_all(outdir)?;
    let mut keep: Vec<usize> = r.black.clone();
    for &(i, j) in &r.older {
        keep.extend([i - 1, i, j]);
    }
    if !frames.is_empty() {
        keep.extend([0, frames.len() - 1]);
    }
    if all {
        keep = (0..frames.len()).collect();
    }
    keep.sort_unstable();
    keep.dedup();
    for &i in &keep {
        fs::write(outdir.join(format!("frame-{i:03}.png")), png_bytes(&frames[i])?)?;
    }
    for &(i, j) in &r.older {
        println!("older: frame {i} at {} ms equals frame {j} at {} ms (surface {} vs {})", frames[i].t_us / 1000, frames[j].t_us / 1000, frames[i].surface, frames[j].surface);
    }
    for &i in &r.black {
        println!("black: frame {i} at {} ms, surface {}, {:.0} % dark", frames[i].t_us / 1000, frames[i].surface, dark_share(&frames[i]) * 100.0);
    }
    let inferred = frames.iter().any(|f| f.inferred);
    println!(
        "seq: {} frames in {} ms, {} surfaces, {} older, {} black, {}",
        r.frames,
        r.span_ms,
        r.surfaces,
        r.older.len(),
        r.black.len(),
        if inferred { "surface inferred" } else { "surface from the kernel" }
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn frame(surface: u32, t_ms: u64, color: [u8; 4]) -> Frame {
        let (w, h) = (20, 20);
        let mut pixels = Vec::new();
        for _ in 0..w * h {
            pixels.extend_from_slice(&color);
        }
        Frame { surface, w, h, t_us: t_ms * 1000, inferred: true, pixels }
    }

    fn record(f: &Frame, row: usize) -> Vec<u8> {
        let mut o = Vec::new();
        o.extend_from_slice(b"LATF");
        for v in [f.surface, f.w as u32, f.h as u32, row as u32, BGRA] {
            o.extend_from_slice(&v.to_le_bytes());
        }
        o.extend_from_slice(&f.t_us.to_le_bytes());
        o.extend_from_slice(&(f.inferred as u32).to_le_bytes());
        o.extend_from_slice(&0u32.to_le_bytes());
        for y in 0..f.h {
            o.extend_from_slice(&f.pixels[y * f.w * 4..(y + 1) * f.w * 4]);
            o.resize(o.len() + row - f.w * 4, 0xee);
        }
        o
    }

    #[test]
    fn a_record_with_row_padding_reads_back() {
        let f = frame(7, 3, [1, 2, 3, 255]);
        let b = record(&f, 96);
        let (g, n) = parse_frame(&b).unwrap();
        assert_eq!(n, b.len());
        assert_eq!(g.pixels, f.pixels);
        assert_eq!((g.surface, g.t_us, g.inferred), (7, 3000, true));
    }

    #[test]
    fn cut_or_foreign_records_are_refused() {
        let b = record(&frame(1, 0, [1, 2, 3, 255]), 80);
        assert!(parse_frame(&b[..b.len() - 1]).is_err());
        assert!(parse_frame(&b[..10]).is_err());
        let mut c = b.clone();
        c[20..24].copy_from_slice(&0x52476641u32.to_le_bytes());
        assert!(parse_frame(&c).is_err());
    }

    #[test]
    fn a_cut_sequence_keeps_the_whole_frames() {
        let mut b = b"LATS".to_vec();
        b.extend(record(&frame(1, 0, [9, 9, 9, 255]), 80));
        let one = b.len();
        b.extend(record(&frame(2, 16, [99, 9, 9, 255]), 80));
        assert_eq!(parse_seq(&b[..one + 50]).unwrap().len(), 1);
        assert_eq!(parse_seq(&b).unwrap().len(), 2);
    }

    #[test]
    fn a_b_a_is_a_return_to_an_older_frame() {
        let (a, b, c) = ([200, 10, 10, 255], [10, 200, 10, 255], [10, 10, 200, 255]);
        let fs = vec![frame(1, 0, a), frame(2, 16, b), frame(1, 33, a), frame(2, 50, c)];
        let r = analyse(&fs);
        assert_eq!(r.older, vec![(2, 0)]);
        assert_eq!(r.surfaces, 2);
        assert_eq!(r.span_ms, 50);
    }

    #[test]
    fn steady_motion_and_a_repeat_are_not_flashes() {
        let fs: Vec<Frame> = (0..6).map(|i| frame(1, i * 16, [20 + i as u8 * 30, 10, 10, 255])).collect();
        assert!(analyse(&fs).older.is_empty());
        let same = vec![frame(1, 0, [100, 0, 0, 255]), frame(2, 16, [100, 0, 0, 255]), frame(1, 33, [100, 0, 0, 255])];
        assert!(analyse(&same).older.is_empty());
    }

    #[test]
    fn a_small_step_back_at_the_end_of_an_animation_is_not_a_flash() {
        let base = frame(1, 0, [100, 100, 100, 255]);
        let mut near = base.clone();
        for p in near.pixels.chunks_exact_mut(4).take(4) {
            p[0] = 200; // 1 % of the pixels
        }
        let fs = vec![base.clone(), near, base];
        assert!(analyse(&fs).older.is_empty());
    }

    #[test]
    fn a_black_frame_is_found() {
        let fs = vec![frame(1, 0, [200, 200, 200, 255]), frame(2, 16, [0, 0, 0, 255])];
        assert_eq!(analyse(&fs).black, vec![1]);
    }

    #[test]
    fn png_has_the_right_head_and_pixels() {
        let f = frame(1, 0, [1, 2, 3, 255]); // B G R A
        let p = png_bytes(&f).unwrap();
        assert_eq!(&p[..8], &[0x89, b'P', b'N', b'G', 0x0d, 0x0a, 0x1a, 0x0a]);
        assert_eq!(u32::from_be_bytes(p[16..20].try_into().unwrap()), 20);
        let idat = p.windows(4).position(|w| w == b"IDAT").unwrap();
        let n = u32::from_be_bytes(p[idat - 4..idat].try_into().unwrap()) as usize;
        let mut raw = Vec::new();
        use std::io::Read;
        flate2::read::ZlibDecoder::new(&p[idat + 4..idat + 4 + n]).read_to_end(&mut raw).unwrap();
        assert_eq!(&raw[..4], &[0, 3, 2, 1]);
    }
}
