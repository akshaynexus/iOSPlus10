//! `op10tool camframe`: one rear-camera frame of the Mi A3 (kernel patch 2771, bsd/dev/laurel_cam_ctl.c) over the
//! USB command server (UDP 5141), saved as the raw MIPI RAW10 bytes and as a PNG.
//!
//! Protocol (bsd/dev/laurel_cam_rdi.h): "camframe" starts a 1.5 s capture on the phone; "caminfo" answers
//! "caminfo gen G state S w W h H stride T bytes B bits 10 bayer RGGB frame M fps F mean X exposure L gain N runs R";
//! "camread G O" answers a 16-byte header ("LCF1", u32 gen, u32 offset, u32 length, little-endian) and up to 1400
//! bytes of the kept frame. Reads are pipelined (32 in flight) and repeated until every part is there.
//! `--raw FILE` converts a saved frame only (no phone).
//! Picture: RAW10 unpack (4 pixels in 5 bytes), black level 64, bilinear demosaic, grey-world white balance,
//! exposure to the 99th percentile, sRGB gamma, 8-bit RGB PNG. Bayer "TPG" (CSID test pattern) = grey image.

use anyhow::{bail, Context, Result};
use std::collections::HashMap;
use std::fs;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

const CHUNK: u32 = 1400;
const HDR: usize = 16;
const BLACK: f32 = 64.0;

pub struct Args {
    pub host: String,
    pub out: PathBuf,
    pub no_capture: bool,
    pub raw: Option<PathBuf>,
    pub width: u32,
    pub height: u32,
    pub bayer: String,
}

fn info(sock: &std::net::UdpSocket) -> Result<HashMap<String, String>> {
    let mut buf = [0u8; 2048];
    for _ in 0..8 {
        sock.send(b"caminfo")?;
        sock.set_read_timeout(Some(Duration::from_millis(300)))?;
        match sock.recv(&mut buf) {
            Ok(n) => {
                let t = String::from_utf8_lossy(&buf[..n]).to_string();
                if t.starts_with("error") {
                    bail!("phone: {t}");
                }
                if let Some(rest) = t.strip_prefix("caminfo ") {
                    let w: Vec<&str> = rest.split_whitespace().collect();
                    return Ok(w.chunks(2).filter(|p| p.len() == 2).map(|p| (p[0].to_string(), p[1].to_string())).collect());
                }
            }
            Err(e) if matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) => continue,
            Err(e) => return Err(e).context("caminfo"),
        }
    }
    bail!("no caminfo reply (kernel without patch 2771, or the USB link is down: scripts/debug/usblog.sh)")
}

fn num(m: &HashMap<String, String>, k: &str) -> Result<u32> {
    m.get(k).and_then(|v| v.parse().ok()).with_context(|| format!("caminfo has no {k}"))
}

fn fetch(sock: &std::net::UdpSocket, gen: u32, bytes: u32) -> Result<Vec<u8>> {
    let parts = bytes.div_ceil(CHUNK);
    let mut data = vec![0u8; bytes as usize];
    let mut have = vec![false; parts as usize];
    let mut sent: HashMap<u32, Instant> = HashMap::new();
    let (mut left, mut next, mut resends) = (parts, 0u32, 0u32);
    let start = Instant::now();
    let mut buf = [0u8; 2048];
    sock.set_read_timeout(Some(Duration::from_millis(20)))?;
    while left > 0 {
        if start.elapsed() > Duration::from_secs(90) {
            bail!("frame incomplete after 90 s: {left} of {parts} parts missing");
        }
        // keep 32 requests in flight; a request without an answer in 300 ms goes out again
        let now = Instant::now();
        let stale: Vec<u32> = sent.iter().filter(|(_, t)| now - **t > Duration::from_millis(300)).map(|(p, _)| *p).collect();
        for p in stale {
            sent.remove(&p);
            if !have[p as usize] {
                sock.send(format!("camread {gen} {}", p * CHUNK).as_bytes())?;
                sent.insert(p, now);
                resends += 1;
            }
        }
        while sent.len() < 32 && next < parts {
            if !have[next as usize] {
                sock.send(format!("camread {gen} {}", next * CHUNK).as_bytes())?;
                sent.insert(next, Instant::now());
            }
            next += 1;
        }
        match sock.recv(&mut buf) {
            Ok(n) if n >= HDR && &buf[..4] == b"LCF1" => {
                let le = |o: usize| u32::from_le_bytes(buf[o..o + 4].try_into().unwrap());
                let (g, off, len) = (le(4), le(8), le(12));
                if g != gen || off % CHUNK != 0 || off + len > bytes || HDR + len as usize != n {
                    continue;
                }
                let p = off / CHUNK;
                sent.remove(&p);
                if !have[p as usize] {
                    data[off as usize..(off + len) as usize].copy_from_slice(&buf[HDR..n]);
                    have[p as usize] = true;
                    left -= 1;
                }
            }
            Ok(n) => {
                let t = String::from_utf8_lossy(&buf[..n]).to_string();
                if t.contains("no such frame part") {
                    bail!("phone: {t} (a new capture ran meanwhile)");
                }
            }
            Err(e) if matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) => {}
            Err(e) => return Err(e).context("camread"),
        }
    }
    println!("camframe: {bytes} bytes in {parts} parts, {resends} resent, {:.1} s", start.elapsed().as_secs_f64());
    Ok(data)
}

/// RAW10 (MIPI packed) -> 10-bit values, row-major
pub fn unpack(raw: &[u8], w: usize, h: usize) -> Result<Vec<u16>> {
    let stride = w / 4 * 5;
    if w % 4 != 0 || raw.len() < stride * h {
        bail!("RAW10 frame of {} bytes is not {w}x{h} ({} bytes)", raw.len(), stride * h);
    }
    let mut px = vec![0u16; w * h];
    for y in 0..h {
        for g in 0..w / 4 {
            let b = &raw[y * stride + g * 5..y * stride + g * 5 + 5];
            for k in 0..4 {
                px[y * w + g * 4 + k] = (b[k] as u16) << 2 | ((b[4] >> (2 * k)) & 3) as u16;
            }
        }
    }
    Ok(px)
}

/// colour of the Bayer site (x, y): 0 R, 1 G, 2 B
fn site(bayer: &str, x: usize, y: usize) -> usize {
    let pat: [usize; 4] = match bayer {
        "BGGR" => [2, 1, 1, 0],
        "GRBG" => [1, 0, 2, 1],
        "GBRG" => [1, 2, 0, 1],
        _ => [0, 1, 1, 2], // RGGB
    };
    pat[(y & 1) * 2 + (x & 1)]
}

/// bilinear demosaic + grey-world white balance + exposure + sRGB gamma -> 8-bit RGB
pub fn develop(px: &[u16], w: usize, h: usize, bayer: &str) -> Vec<u8> {
    let v = |x: isize, y: isize| -> f32 {
        let x = x.clamp(0, w as isize - 1) as usize;
        let y = y.clamp(0, h as isize - 1) as usize;
        (px[y * w + x] as f32 - BLACK).max(0.0)
    };
    let mut rgb = vec![0f32; w * h * 3];
    if bayer == "TPG" {
        for i in 0..w * h {
            let g = px[i] as f32;
            rgb[i * 3..i * 3 + 3].copy_from_slice(&[g, g, g]);
        }
    } else {
        for y in 0..h as isize {
            for x in 0..w as isize {
                let c = site(bayer, x as usize, y as usize);
                let cross = (v(x - 1, y) + v(x + 1, y) + v(x, y - 1) + v(x, y + 1)) / 4.0;
                let diag = (v(x - 1, y - 1) + v(x + 1, y - 1) + v(x - 1, y + 1) + v(x + 1, y + 1)) / 4.0;
                let horiz = (v(x - 1, y) + v(x + 1, y)) / 2.0;
                let vert = (v(x, y - 1) + v(x, y + 1)) / 2.0;
                let me = v(x, y);
                let o = (y as usize * w + x as usize) * 3;
                let (r, g, b) = match c {
                    0 => (me, cross, diag),
                    2 => (diag, cross, me),
                    _ => {
                        // green: the red neighbours are on this row if the row's other site is red
                        if site(bayer, (x as usize) ^ 1, y as usize) == 0 { (horiz, me, vert) } else { (vert, me, horiz) }
                    }
                };
                rgb[o..o + 3].copy_from_slice(&[r, g, b]);
            }
        }
        // grey world: equal channel means
        let mut sum = [0f64; 3];
        for p in rgb.chunks(3) {
            for c in 0..3 {
                sum[c] += p[c] as f64;
            }
        }
        // (never below 1: the green sites of a raw Bayer sensor are the most sensitive ones)
        let gains: Vec<f32> = (0..3).map(|c| if sum[c] > 0.0 { ((sum[1] / sum[c]) as f32).clamp(1.0, 4.0) } else { 1.0 }).collect();
        for p in rgb.chunks_mut(3) {
            for c in 0..3 {
                p[c] *= gains[c];
            }
        }
    }
    // exposure: the 99th percentile of the brightest channel -> white
    let mut m: Vec<f32> = rgb.chunks(3).map(|p| p[0].max(p[1]).max(p[2])).collect();
    let k = (m.len() * 99 / 100).min(m.len().saturating_sub(1));
    let white = *m.select_nth_unstable_by(k, |a, b| a.partial_cmp(b).unwrap()).1;
    let scale = if white > 0.0 { 1.0 / white } else { 1.0 };
    rgb.iter()
        .map(|&c| {
            let l = (c * scale).clamp(0.0, 1.0);
            let s = if l <= 0.0031308 { 12.92 * l } else { 1.055 * l.powf(1.0 / 2.4) - 0.055 };
            (s * 255.0 + 0.5) as u8
        })
        .collect()
}

/// 8-bit RGB PNG (one IDAT, zlib through flate2)
pub fn png(path: &Path, rgb: &[u8], w: u32, h: u32) -> Result<()> {
    use flate2::{write::ZlibEncoder, Compression};
    use std::io::Write;
    let mut raw = Vec::with_capacity((w as usize * 3 + 1) * h as usize);
    for row in rgb.chunks(w as usize * 3) {
        raw.push(0);
        raw.extend_from_slice(row);
    }
    let mut z = ZlibEncoder::new(Vec::new(), Compression::default());
    z.write_all(&raw)?;
    let idat = z.finish()?;
    let mut f = b"\x89PNG\r\n\x1a\n".to_vec();
    let mut chunk = |kind: &[u8], body: &[u8]| {
        f.extend_from_slice(&(body.len() as u32).to_be_bytes());
        let mut c = kind.to_vec();
        c.extend_from_slice(body);
        f.extend_from_slice(&c);
        f.extend_from_slice(&crc32fast::hash(&c).to_be_bytes());
    };
    let mut ihdr = Vec::new();
    ihdr.extend_from_slice(&w.to_be_bytes());
    ihdr.extend_from_slice(&h.to_be_bytes());
    ihdr.extend_from_slice(&[8, 2, 0, 0, 0]);
    chunk(b"IHDR", &ihdr);
    chunk(b"IDAT", &idat);
    chunk(b"IEND", &[]);
    fs::write(path, f).with_context(|| format!("write {}", path.display()))
}

fn save(out: &Path, name: &str, raw: &[u8], w: u32, h: u32, bayer: &str) -> Result<()> {
    fs::create_dir_all(out)?;
    let px = unpack(raw, w as usize, h as usize)?;
    let mean = px.iter().map(|&p| p as u64).sum::<u64>() / px.len().max(1) as u64;
    let rgb = develop(&px, w as usize, h as usize, bayer);
    let p = out.join(format!("{name}.png"));
    png(&p, &rgb, w, h)?;
    println!("camframe: {}x{} {bayer}, mean {mean} (RAW10), picture {}", w, h, p.display());
    Ok(())
}

pub fn run(a: Args) -> Result<()> {
    if let Some(raw) = &a.raw {
        let data = fs::read(raw).with_context(|| format!("read {}", raw.display()))?;
        let name = raw.file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_else(|| "camframe".into());
        return save(&a.out, &name, &data, a.width, a.height, &a.bayer);
    }
    let (sock, phone) = crate::ctl::socket(&a.host)?;
    let mut m = info(&sock)?;
    if !a.no_capture {
        let gen0 = num(&m, "gen")?;
        let mut buf = [0u8; 512];
        sock.send(b"camframe")?;
        sock.set_read_timeout(Some(Duration::from_secs(2)))?;
        let n = sock.recv(&mut buf).context("no reply to camframe")?;
        let t = String::from_utf8_lossy(&buf[..n]).to_string();
        println!("{phone}: {t}");
        if t.starts_with("error") {
            bail!("the phone's camera path is off (see the LAUREL CAMERA lines in the USB log)");
        }
        let start = Instant::now();
        loop {
            std::thread::sleep(Duration::from_millis(250));
            m = info(&sock)?;
            if m.get("state").map(String::as_str) == Some("ready") && num(&m, "gen")? > gen0 {
                break;
            }
            if m.get("state").map(String::as_str) == Some("off") {
                bail!("capture failed: camera path off (USB log: LAUREL CAMERA: rear stream: off: ...)");
            }
            if start.elapsed() > Duration::from_secs(20) {
                bail!("no new frame in 20 s (state {:?})", m.get("state"));
            }
        }
    }
    if m.get("state").map(String::as_str) != Some("ready") {
        bail!("no kept frame on the phone (state {:?})", m.get("state"));
    }
    let (gen, bytes, w, h) = (num(&m, "gen")?, num(&m, "bytes")?, num(&m, "w")?, num(&m, "h")?);
    let bayer = m.get("bayer").cloned().unwrap_or_else(|| "RGGB".into());
    println!("camframe: gen {gen}, frame {} at {} fps, mean {}, exposure {} gain {}", m.get("frame").map_or("?", |s| s),
        m.get("fps").map_or("?", |s| s), m.get("mean").map_or("?", |s| s), m.get("exposure").map_or("?", |s| s),
        m.get("gain").map_or("?", |s| s));
    let data = fetch(&sock, gen, bytes)?;
    fs::create_dir_all(&a.out)?;
    let name = format!("camframe-gen{gen}");
    let rp = a.out.join(format!("{name}.raw10"));
    fs::write(&rp, &data).with_context(|| format!("write {}", rp.display()))?;
    println!("camframe: raw {}", rp.display());
    save(&a.out, &name, &data, w, h, &bayer)
}
