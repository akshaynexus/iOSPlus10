//! Download members of a remote ZIP (an IPSW) with many parallel HTTP range requests.
//! - Reads the central directory (ZIP64 aware) with range requests.
//! - Splits the member's stored/compressed bytes into chunks; worker threads fetch them and write in
//!   place. Finished chunks go to OUT.part.done (or OUT.deflate.part.done), so a run resumes.
//! - Stored (method 0): that is the file. Deflated (method 8): inflated locally afterwards.
//! - The CRC-32 from the ZIP directory is checked before the file gets its final name.

use anyhow::{anyhow, bail, ensure, Context, Result};
use std::collections::HashSet;
use std::fs::{self, File, OpenOptions};
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::fs::FileExt;
use std::path::Path;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

struct Entry { method: u16, crc: u32, csize: u64, usize_: u64, lho: u64 }

fn agent() -> ureq::Agent {
    ureq::AgentBuilder::new().timeout_connect(Duration::from_secs(30))
        .timeout_read(Duration::from_secs(120)).build()
}

fn range(agent: &ureq::Agent, url: &str, start: u64, end: u64) -> Result<Vec<u8>> {
    let want = (end - start + 1) as usize;
    let mut last = anyhow!("no attempt");
    for attempt in 0..6 {
        if attempt > 0 { std::thread::sleep(Duration::from_secs(2 * attempt)); }
        match agent.get(url).set("Range", &format!("bytes={start}-{end}")).call() {
            Ok(r) => {
                let mut buf = Vec::with_capacity(want);
                match r.into_reader().take(want as u64 + 1).read_to_end(&mut buf) {
                    Ok(_) if buf.len() == want => return Ok(buf),
                    Ok(_) => last = anyhow!("range {start}-{end}: got {} bytes", buf.len()),
                    Err(e) => last = e.into(),
                }
            }
            Err(e) => last = e.into(),
        }
    }
    Err(last)
}

fn size_of(agent: &ureq::Agent, url: &str) -> Result<u64> {
    let r = agent.head(url).call()?;
    r.header("Content-Length").ok_or_else(|| anyhow!("no Content-Length"))?.parse().map_err(Into::into)
}

fn u16_(b: &[u8], i: usize) -> u16 { u16::from_le_bytes([b[i], b[i + 1]]) }
fn u32_(b: &[u8], i: usize) -> u32 { u32::from_le_bytes(b[i..i + 4].try_into().unwrap()) }
fn u64_(b: &[u8], i: usize) -> u64 { u64::from_le_bytes(b[i..i + 8].try_into().unwrap()) }

fn rfind(h: &[u8], n: &[u8]) -> Option<usize> { h.windows(n.len()).rposition(|w| w == n) }

fn central_directory(agent: &ureq::Agent, url: &str) -> Result<Vec<(String, Entry)>> {
    let total = size_of(agent, url)?;
    let tail = range(agent, url, total - 65536 - 22, total - 1)?;
    let (cd_size, cd_off) = if let Some(i) = rfind(&tail, b"PK\x06\x06") {
        (u64_(&tail, i + 40), u64_(&tail, i + 48))
    } else {
        let i = rfind(&tail, b"PK\x05\x06").ok_or_else(|| anyhow!("no end of central directory"))?;
        (u32_(&tail, i + 12) as u64, u32_(&tail, i + 16) as u64)
    };
    let cd = range(agent, url, cd_off, cd_off + cd_size - 1)?;
    let mut out = Vec::new();
    let mut i = 0;
    while i + 46 <= cd.len() && &cd[i..i + 4] == b"PK\x01\x02" {
        let method = u16_(&cd, i + 10);
        let crc = u32_(&cd, i + 16);
        let (mut csize, mut usz) = (u32_(&cd, i + 20) as u64, u32_(&cd, i + 24) as u64);
        let (nlen, xlen, clen) = (u16_(&cd, i + 28) as usize, u16_(&cd, i + 30) as usize, u16_(&cd, i + 32) as usize);
        let mut lho = u32_(&cd, i + 42) as u64;
        let name = String::from_utf8_lossy(&cd[i + 46..i + 46 + nlen]).into_owned();
        let x = &cd[i + 46 + nlen..i + 46 + nlen + xlen];
        let mut j = 0;
        while j + 4 <= x.len() {
            let (tag, ln) = (u16_(x, j), u16_(x, j + 2) as usize);
            if tag == 1 {
                let mut k = j + 4;
                if usz == 0xffff_ffff { usz = u64_(x, k); k += 8; }
                if csize == 0xffff_ffff { csize = u64_(x, k); k += 8; }
                if lho == 0xffff_ffff { lho = u64_(x, k); }
            }
            j += 4 + ln;
        }
        out.push((name, Entry { method, crc, csize, usize_: usz, lho }));
        i += 46 + nlen + xlen + clen;
    }
    Ok(out)
}

fn fetch(agent: &ureq::Agent, url: &str, name: &str, e: &Entry, outdir: &Path, jobs: usize, chunk: u64) -> Result<()> {
    let hdr = range(agent, url, e.lho, e.lho + 29)?;
    let data0 = e.lho + 30 + u16_(&hdr, 26) as u64 + u16_(&hdr, 28) as u64;
    let base = Path::new(name).file_name().unwrap().to_string_lossy().into_owned();
    let out = outdir.join(&base);
    if out.exists() && fs::metadata(&out)?.len() == e.usize_ {
        println!("{name}: already complete");
        return Ok(());
    }
    let part = outdir.join(if e.method == 0 { format!("{base}.part") } else { format!("{base}.deflate.part") });
    let done_f = part.with_file_name(format!("{}.done", part.file_name().unwrap().to_string_lossy()));
    let size = e.csize;
    let f = OpenOptions::new().read(true).write(true).create(true).truncate(false).open(&part)?;
    f.set_len(size)?;
    let done: HashSet<u64> = if done_f.exists() {
        BufReader::new(File::open(&done_f)?).lines().filter_map(|l| l.ok()?.trim().parse().ok()).collect()
    } else { HashSet::new() };
    let todo: Vec<u64> = (0..size.div_ceil(chunk)).filter(|k| !done.contains(k)).collect();
    let got = Arc::new(AtomicU64::new(done.len() as u64 * chunk));
    let next = Arc::new(AtomicUsize::new(0));
    let todo = Arc::new(todo);
    let f = Arc::new(f);
    let log = Arc::new(Mutex::new(OpenOptions::new().append(true).create(true).open(&done_f)?));
    let err: Arc<Mutex<Option<anyhow::Error>>> = Arc::new(Mutex::new(None));
    std::thread::scope(|s| {
        for _ in 0..jobs.max(1) {
            let (todo, next, got, f, log, err) = (todo.clone(), next.clone(), got.clone(), f.clone(), log.clone(), err.clone());
            let agent = agent.clone();
            s.spawn(move || loop {
                if err.lock().unwrap().is_some() { return; }
                let n = next.fetch_add(1, Ordering::SeqCst);
                let Some(&k) = todo.get(n) else { return };
                let st = k * chunk;
                let en = (st + chunk).min(size) - 1;
                match range(&agent, url, data0 + st, data0 + en).and_then(|d| f.write_all_at(&d, st).map_err(Into::into)) {
                    Ok(()) => {
                        let mut l = log.lock().unwrap();
                        let _ = writeln!(l, "{k}");
                        let g = got.fetch_add(en - st + 1, Ordering::SeqCst) + en - st + 1;
                        let g = g.min(size);
                        println!("{name}: {}% ({}/{} MiB)", g * 100 / size, g >> 20, size >> 20);
                    }
                    Err(e) => { *err.lock().unwrap() = Some(e); return; }
                }
            });
        }
    });
    if let Some(e) = err.lock().unwrap().take() { return Err(e.context(format!("{name}: download failed (rerun to resume)"))); }
    drop(f);

    let mut h = crc32fast::Hasher::new();
    let tmp = if e.method == 0 {
        let mut r = BufReader::with_capacity(1 << 24, File::open(&part)?);
        let mut buf = vec![0u8; 1 << 24];
        loop { let n = r.read(&mut buf)?; if n == 0 { break; } h.update(&buf[..n]); }
        part.clone()
    } else {
        println!("{name}: inflating");
        let tmp = outdir.join(format!("{base}.part"));
        let mut z = flate2::read::DeflateDecoder::new(BufReader::with_capacity(1 << 24, File::open(&part)?));
        let mut g = std::io::BufWriter::with_capacity(1 << 24, File::create(&tmp)?);
        let mut buf = vec![0u8; 1 << 24];
        loop { let n = z.read(&mut buf)?; if n == 0 { break; } h.update(&buf[..n]); g.write_all(&buf[..n])?; }
        g.flush()?;
        tmp
    };
    let c = h.finalize();
    if c != e.crc {
        let _ = fs::remove_file(&done_f);
        bail!("{name}: CRC-32 mismatch ({c:08x} != {:08x}); chunk list reset, rerun", e.crc);
    }
    fs::rename(&tmp, &out)?;
    let _ = fs::remove_file(&done_f);
    if e.method != 0 { let _ = fs::remove_file(&part); }
    println!("{name}: {} bytes, CRC-32 ok -> {}", e.usize_, out.display());
    Ok(())
}

pub fn run(url: &str, outdir: &Path, names: &[String], jobs: usize, chunk: u64) -> Result<()> {
    fs::create_dir_all(outdir)?;
    let agent = agent();
    let ents = central_directory(&agent, url).context("reading the ZIP directory")?;
    for want in names {
        let (name, e) = ents.iter().find(|(n, _)| n == want || n.ends_with(&format!("/{want}")))
            .ok_or_else(|| anyhow!("{want}: not in the archive"))?;
        ensure!(e.method == 0 || e.method == 8, "{name}: compression method {} not supported", e.method);
        fetch(&agent, url, name, e, outdir, jobs, chunk)?;
    }
    Ok(())
}
