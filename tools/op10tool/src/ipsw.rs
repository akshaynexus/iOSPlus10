//! Download members of a remote ZIP (an IPSW) with parallel HTTP range requests.
//! - `zip` crate reads the directory through `HttpFile` (Read + Seek over range requests).
//! - The member's stored/compressed bytes are split into chunks, fetched by a `rayon` pool and
//!   written in place. Finished chunks go to <part>.done, so an interrupted run resumes.
//! - Stored: that is the file. Deflated: inflated locally (`flate2`). CRC-32 checked (`crc32fast`).

use anyhow::{anyhow, bail, Context, Result};
use rayon::prelude::*;
use std::collections::HashSet;
use std::fs::{self, File, OpenOptions};
use std::io::{self, BufRead, BufReader, Read, Seek, SeekFrom, Write};
use std::os::unix::fs::FileExt;
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::Duration;
use zip::CompressionMethod;

fn agent() -> ureq::Agent {
    ureq::AgentBuilder::new().timeout_connect(Duration::from_secs(30)).timeout_read(Duration::from_secs(120)).build()
}

/// One HTTP range request with retries; returns exactly end-start+1 bytes.
fn range(agent: &ureq::Agent, url: &str, start: u64, end: u64) -> Result<Vec<u8>> {
    let want = (end - start + 1) as usize;
    let mut last = anyhow!("no attempt");
    for attempt in 0..6u64 {
        if attempt > 0 { std::thread::sleep(Duration::from_secs(2 * attempt)); }
        let res = agent.get(url).set("Range", &format!("bytes={start}-{end}")).call()
            .map_err(anyhow::Error::from)
            .and_then(|r| { let mut b = Vec::with_capacity(want); r.into_reader().take(want as u64 + 1).read_to_end(&mut b)?; Ok(b) });
        match res {
            Ok(b) if b.len() == want => return Ok(b),
            Ok(b) => last = anyhow!("range {start}-{end}: got {} bytes", b.len()),
            Err(e) => last = e,
        }
    }
    Err(last)
}

/// Read + Seek over HTTP range requests (64 KiB read-ahead), for the `zip` crate.
struct HttpFile { agent: ureq::Agent, url: String, len: u64, pos: u64, buf: Vec<u8>, buf_at: u64 }

impl HttpFile {
    fn open(agent: &ureq::Agent, url: &str) -> Result<Self> {
        let r = agent.head(url).call()?;
        let len = r.header("Content-Length").ok_or_else(|| anyhow!("no Content-Length"))?.parse()?;
        Ok(Self { agent: agent.clone(), url: url.into(), len, pos: 0, buf: Vec::new(), buf_at: 0 })
    }
}
impl Read for HttpFile {
    fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
        if self.pos >= self.len || out.is_empty() { return Ok(0); }
        let in_buf = self.pos >= self.buf_at && self.pos < self.buf_at + self.buf.len() as u64;
        if !in_buf {
            let end = (self.pos + (out.len() as u64).max(65536)).min(self.len) - 1;
            self.buf = range(&self.agent, &self.url, self.pos, end).map_err(io::Error::other)?;
            self.buf_at = self.pos;
        }
        let off = (self.pos - self.buf_at) as usize;
        let n = out.len().min(self.buf.len() - off);
        out[..n].copy_from_slice(&self.buf[off..off + n]);
        self.pos += n as u64;
        Ok(n)
    }
}
impl Seek for HttpFile {
    fn seek(&mut self, p: SeekFrom) -> io::Result<u64> {
        self.pos = match p {
            SeekFrom::Start(o) => o,
            SeekFrom::End(o) => (self.len as i64 + o) as u64,
            SeekFrom::Current(o) => (self.pos as i64 + o) as u64,
        };
        Ok(self.pos)
    }
}

struct Member { name: String, method: CompressionMethod, crc: u32, csize: u64, usize_: u64, data0: u64 }

fn fetch(agent: &ureq::Agent, url: &str, m: &Member, outdir: &Path, jobs: usize, chunk: u64) -> Result<()> {
    let name = &m.name;
    let base = Path::new(name).file_name().unwrap().to_string_lossy().into_owned();
    let out = outdir.join(&base);
    if out.exists() && fs::metadata(&out)?.len() == m.usize_ {
        println!("{name}: already complete");
        return Ok(());
    }
    let stored = m.method == CompressionMethod::Stored;
    let part = outdir.join(if stored { format!("{base}.part") } else { format!("{base}.deflate.part") });
    let done_f = outdir.join(format!("{}.done", part.file_name().unwrap().to_string_lossy()));
    let size = m.csize;
    let f = OpenOptions::new().read(true).write(true).create(true).truncate(false).open(&part)?;
    f.set_len(size)?;
    let done: HashSet<u64> = if done_f.exists() {
        BufReader::new(File::open(&done_f)?).lines().map_while(|l| l.ok()).filter_map(|l| l.trim().parse().ok()).collect()
    } else { HashSet::new() };
    let todo: Vec<u64> = (0..size.div_ceil(chunk)).filter(|k| !done.contains(k)).collect();
    let got = AtomicU64::new(done.len() as u64 * chunk);
    let log = Mutex::new(OpenOptions::new().append(true).create(true).open(&done_f)?);

    let pool = rayon::ThreadPoolBuilder::new().num_threads(jobs.max(1)).build()?;
    pool.install(|| {
        todo.par_iter().try_for_each(|&k| -> Result<()> {
            let st = k * chunk;
            let en = (st + chunk).min(size) - 1;
            f.write_all_at(&range(agent, url, m.data0 + st, m.data0 + en)?, st)?;
            writeln!(log.lock().unwrap(), "{k}")?;
            let g = (got.fetch_add(en - st + 1, Ordering::SeqCst) + en - st + 1).min(size);
            println!("{name}: {}% ({}/{} MiB)", g * 100 / size, g >> 20, size >> 20);
            Ok(())
        })
    }).with_context(|| format!("{name}: download failed (rerun to resume)"))?;
    drop(f);

    let mut h = crc32fast::Hasher::new();
    let mut buf = vec![0u8; 1 << 24];
    let tmp = if stored {
        let mut r = File::open(&part)?;
        loop { let n = r.read(&mut buf)?; if n == 0 { break; } h.update(&buf[..n]); }
        part.clone()
    } else {
        println!("{name}: inflating");
        let tmp = outdir.join(format!("{base}.part"));
        let mut z = flate2::read::DeflateDecoder::new(BufReader::with_capacity(1 << 24, File::open(&part)?));
        let mut g = io::BufWriter::with_capacity(1 << 24, File::create(&tmp)?);
        loop { let n = z.read(&mut buf)?; if n == 0 { break; } h.update(&buf[..n]); g.write_all(&buf[..n])?; }
        g.flush()?;
        tmp
    };
    let c = h.finalize();
    if c != m.crc {
        let _ = fs::remove_file(&done_f);
        bail!("{name}: CRC-32 mismatch ({c:08x} != {:08x}); chunk list reset, rerun", m.crc);
    }
    fs::rename(&tmp, &out)?;
    let _ = fs::remove_file(&done_f);
    if !stored { let _ = fs::remove_file(&part); }
    println!("{name}: {} bytes, CRC-32 ok -> {}", m.usize_, out.display());
    Ok(())
}

pub fn run(url: &str, outdir: &Path, names: &[String], jobs: usize, chunk: u64) -> Result<()> {
    fs::create_dir_all(outdir)?;
    let agent = agent();
    let mut zip = zip::ZipArchive::new(HttpFile::open(&agent, url)?).context("reading the ZIP directory")?;
    let all: Vec<String> = zip.file_names().filter_map(|n| n.ok().map(|n| n.into_owned())).collect();
    for want in names {
        let name = all.iter().find(|n| *n == want || n.ends_with(&format!("/{want}")))
            .ok_or_else(|| anyhow!("{want}: not in the archive"))?;
        let i = zip.index_for_name(name).unwrap();
        let e = zip.by_index_raw(i)?;
        let m = Member {
            name: name.clone(), method: e.compression(), crc: e.crc32(),
            csize: e.compressed_size(), usize_: e.size(),
            data0: e.data_start().ok_or_else(|| anyhow!("{name}: no data offset"))?,
        };
        drop(e);
        if !matches!(m.method, CompressionMethod::Stored | CompressionMethod::Deflated) {
            bail!("{name}: compression {:?} not supported", m.method);
        }
        fetch(&agent, url, &m, outdir, jobs, chunk)?;
    }
    Ok(())
}
