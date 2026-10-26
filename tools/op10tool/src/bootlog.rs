//! `op10tool bootlog`: read the negroni kernel's boot log area (patches/xnu/0367-negroni-bootlog.patch,
//! patches/xnu/README-bootlog.md) and write one text file per boot.
//!
//! Area (userdata blocks N-28673 .. N-19458, 4096-byte blocks): block 0 = superblock "NEGRBLOG"; slot i at
//! block 1 + i*1025 = header block "NEGRBOOT" + the 4 MiB console ring of that boot (byte n at ring offset
//! n % 4 MiB). The layouts below must match struct nbl_super / struct nbl_slot in bsd/dev/negroni_ufs.c.
//!
//! Sources: the USB command server (UDP 5141: "bootlog", "bootlog read A C"; works on a good boot without SSH),
//! or `--file` with a dump of the area (`dd if=/dev/negronibootlog` over SSH: scripts/debug/bootlog-ssh.sh, or
//! a dd of userdata at block N-28673 from any other system).

use anyhow::{bail, Context, Result};
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::io::{ErrorKind, Read, Seek, SeekFrom};
use std::net::UdpSocket;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

pub const BLOCK: usize = 4096;
pub const AREA_BLOCKS: u32 = 9216;
pub const FROM_END: u32 = 28673;
pub const SLOTS: u32 = 8;
pub const SLOT_BLOCKS: u32 = 1025;
pub const RING: u64 = 4 << 20;
const SUPER_LEN: usize = 36;
const SLOT_LEN: usize = 1932;
const CHUNK: usize = 1024;

/// The superblock the kernel writes (nbl_setup_locked), padded to one block: root-simg.sh embeds it.
pub fn superblock() -> Vec<u8> {
    let mut b = vec![0u8; BLOCK];
    b[..8].copy_from_slice(b"NEGRBLOG");
    for (i, v) in [1u32, SLOTS, SLOT_BLOCKS, AREA_BLOCKS, RING as u32, FROM_END].iter().enumerate() {
        b[8 + 4 * i..12 + 4 * i].copy_from_slice(&v.to_le_bytes());
    }
    let crc = crc32fast::hash(&b[..32]);
    b[32..36].copy_from_slice(&crc.to_le_bytes());
    b
}

fn le32(b: &[u8], o: usize) -> u32 {
    u32::from_le_bytes(b[o..o + 4].try_into().unwrap())
}
fn le64(b: &[u8], o: usize) -> u64 {
    u64::from_le_bytes(b[o..o + 8].try_into().unwrap())
}
fn cstr(b: &[u8]) -> String {
    let n = b.iter().position(|&c| c == 0).unwrap_or(b.len());
    String::from_utf8_lossy(&b[..n]).into_owned()
}

#[derive(Clone, Debug)]
struct Slot {
    index: u32,
    boot: u64,
    state: u32,
    flags: u32,
    total: u64,
    seq: u64,
    start_cal: u64,
    last_cal: u64,
    last_up_ms: u64,
    sb_up_ms: u64,
    end_up_ms: u64,
    uuid: String,
    kversion: String,
    bootargs: String,
    pon: String,
    end: String,
}

fn parse_slot(index: u32, b: &[u8]) -> Option<Slot> {
    if &b[..8] != b"NEGRBOOT" || le32(b, 8) != 1 || le32(b, 12) as usize != SLOT_LEN {
        return None;
    }
    if crc32fast::hash(&b[..SLOT_LEN - 4]) != le32(b, SLOT_LEN - 4) {
        return None;
    }
    Some(Slot {
        index,
        boot: le64(b, 16),
        state: le32(b, 24),
        flags: le32(b, 28),
        total: le64(b, 40),
        seq: le64(b, 48),
        start_cal: le64(b, 56),
        last_cal: le64(b, 64),
        last_up_ms: le64(b, 72),
        sb_up_ms: le64(b, 80),
        end_up_ms: le64(b, 88),
        uuid: cstr(&b[96..136]),
        kversion: cstr(&b[136..392]),
        bootargs: cstr(&b[392..1416]),
        pon: cstr(&b[1416..1672]),
        end: cstr(&b[1672..1928]),
    })
}

fn state_name(s: u32) -> &'static str {
    match s {
        1 => "running",
        2 => "panic",
        3 => "halt",
        4 => "restart",
        _ => "?",
    }
}

/// UTC "YYYY-MM-DD hh:mm:ss" (days-from-civil inverse, no time zone database).
fn utc(secs: u64) -> String {
    let days = (secs / 86400) as i64;
    let rem = secs % 86400;
    let z = days + 719468;
    let era = z.div_euclid(146097);
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + if m <= 2 { 1 } else { 0 };
    format!("{y:04}-{m:02}-{d:02} {:02}:{:02}:{:02}", rem / 3600, rem / 60 % 60, rem % 60)
}

/// Area blocks from the phone or a dump.
trait Source {
    fn read(&mut self, blocks: &BTreeSet<u32>) -> Result<BTreeMap<u32, Vec<u8>>>;
}

struct FileSource(fs::File, u64);

impl Source for FileSource {
    fn read(&mut self, blocks: &BTreeSet<u32>) -> Result<BTreeMap<u32, Vec<u8>>> {
        let mut out = BTreeMap::new();
        for &b in blocks {
            let off = b as u64 * BLOCK as u64;
            let mut buf = vec![0u8; BLOCK];
            if off + BLOCK as u64 <= self.1 {
                self.0.seek(SeekFrom::Start(off))?;
                self.0.read_exact(&mut buf)?;
            }
            out.insert(b, buf);
        }
        Ok(out)
    }
}

struct UdpSource {
    sock: UdpSocket,
    phone: std::net::SocketAddr,
}

impl UdpSource {
    fn info(&self) -> Result<String> {
        let mut buf = [0u8; 2048];
        let start = Instant::now();
        while start.elapsed() < Duration::from_secs(3) {
            self.sock.send(b"bootlog").context("send bootlog")?;
            self.sock.set_read_timeout(Some(Duration::from_millis(500)))?;
            loop {
                match self.sock.recv(&mut buf) {
                    Ok(n) => {
                        let t = String::from_utf8_lossy(&buf[..n]).trim().to_string();
                        if t.starts_with("bootlog ") {
                            return Ok(t);
                        }
                        if t.starts_with("error") {
                            bail!("{}: {t}", self.phone);
                        }
                        // a stale data datagram: ignore
                    }
                    Err(e) if matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) => break,
                    Err(e) if e.kind() == ErrorKind::ConnectionRefused => bail!(
                        "{}: ICMP port unreachable: kernel without the command server, or negronictl=0",
                        self.phone
                    ),
                    Err(e) => return Err(e.into()),
                }
            }
        }
        bail!("no reply to \"bootlog\" from {} in 3 s (kernel without patch 0367 replies \"error: unknown command\")", self.phone)
    }
}

impl Source for UdpSource {
    /// Pipelined "bootlog read A C" requests (C <= 4 contiguous blocks, 4 outstanding); for a request whose
    /// datagrams did not all arrive in 250 ms each missing block is asked for again alone (the phone's TX queue
    /// may drop datagrams); 12 tries per block.
    fn read(&mut self, blocks: &BTreeSet<u32>) -> Result<BTreeMap<u32, Vec<u8>>> {
        let mut reqs: Vec<(u32, u32)> = Vec::new();
        for &b in blocks {
            match reqs.last_mut() {
                Some((s, c)) if *s + *c == b && *c < 4 => *c += 1,
                _ => reqs.push((b, 1)),
            }
        }
        let mut have: BTreeMap<u32, (Vec<u8>, u8)> = BTreeMap::new(); // block -> data, chunk mask
        let mut queue: std::collections::VecDeque<(u32, u32)> = reqs.into_iter().collect();
        let mut out: Vec<((u32, u32), Instant, u32)> = Vec::new();
        let mut retry: BTreeMap<u32, u32> = BTreeMap::new(); // block -> tries of its single-block request
        let mut buf = [0u8; 2048];
        let total = blocks.len();
        let t0 = Instant::now();
        let mut shown = Instant::now();
        self.sock.set_read_timeout(Some(Duration::from_millis(20)))?;
        let done = |have: &BTreeMap<u32, (Vec<u8>, u8)>, b: u32| have.get(&b).map_or(false, |(_, m)| *m == 0xf);
        loop {
            out.retain(|((s, c), _, _)| !(*s..*s + *c).all(|b| done(&have, b)));
            if queue.is_empty() && out.is_empty() {
                break;
            }
            // a request not complete in 250 ms: ask again for each missing block alone (4 datagrams each)
            let mut late = Vec::new();
            out.retain(|o| {
                let keep = o.1.elapsed() <= Duration::from_millis(250);
                if !keep {
                    late.push(*o);
                }
                keep
            });
            for ((s, c), _, tries) in late {
                if tries >= 12 {
                    bail!("area blocks {}..{}: no complete answer after {} tries", s, s + c, tries);
                }
                for b in (s..s + c).rev().filter(|&b| !done(&have, b)) {
                    queue.push_front((b, 1));
                    retry.insert(b, tries + 1);
                }
            }
            while out.len() < 4 {
                let Some(r) = queue.pop_front() else { break };
                self.sock.send(format!("bootlog read {} {}", r.0, r.1).as_bytes())?;
                let tries = retry.get(&r.0).copied().unwrap_or(1);
                out.push((r, Instant::now(), tries));
            }
            match self.sock.recv(&mut buf) {
                Ok(n) if n >= 16 && &buf[..4] == b"NBLD" => {
                    let (b, off, len) = (le32(&buf, 4), le32(&buf, 8) as usize, le32(&buf, 12) as usize);
                    if len == CHUNK && off % CHUNK == 0 && off < BLOCK && n == 16 + len {
                        let e = have.entry(b).or_insert_with(|| (vec![0u8; BLOCK], 0));
                        e.0[off..off + len].copy_from_slice(&buf[16..16 + len]);
                        e.1 |= 1 << (off / CHUNK);
                    }
                }
                Ok(n) => {
                    let t = String::from_utf8_lossy(&buf[..n]);
                    if t.starts_with("error") {
                        bail!("{}: {}", self.phone, t.trim());
                    }
                }
                Err(e) if matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) => {}
                Err(e) => return Err(e.into()),
            }
            if total > 64 && shown.elapsed() > Duration::from_secs(2) {
                let got = have.values().filter(|(_, m)| *m == 0xf).count();
                eprintln!("bootlog: {got}/{total} blocks ({:.0} KiB/s)", got as f64 * 4.0 / t0.elapsed().as_secs_f64());
                shown = Instant::now();
            }
        }
        Ok(have.into_iter().filter(|(b, _)| blocks.contains(b)).map(|(b, (d, _))| (b, d)).collect())
    }
}

/// LC_UUID of each out/kernel/*/kernel.* (Mach-O 64), to name the kernel build of a boot.
fn kernel_by_uuid(dir: &Path, uuid: &str) -> Option<PathBuf> {
    let want = uuid.replace('-', "").to_ascii_uppercase();
    let mut hits = Vec::new();
    for d in fs::read_dir(dir).ok()?.flatten() {
        let Ok(files) = fs::read_dir(d.path()) else { continue };
        for f in files.flatten() {
            let p = f.path();
            if !p.file_name().map_or(false, |n| n.to_string_lossy().starts_with("kernel.")) {
                continue;
            }
            let mut head = vec![0u8; 65536];
            let Ok(mut fh) = fs::File::open(&p) else { continue };
            let n = fh.read(&mut head).unwrap_or(0);
            head.truncate(n);
            if n < 32 || le32(&head, 0) != 0xfeedfacf {
                continue;
            }
            let (ncmds, mut o) = (le32(&head, 16), 32usize);
            for _ in 0..ncmds {
                if o + 8 > head.len() {
                    break;
                }
                let (cmd, size) = (le32(&head, o), le32(&head, o + 4) as usize);
                if cmd == 0x1b && o + 24 <= head.len() {
                    let u: String = head[o + 8..o + 24].iter().map(|b| format!("{b:02X}")).collect();
                    if u == want {
                        hits.push(p.clone());
                    }
                    break;
                }
                if size == 0 {
                    break;
                }
                o += size;
            }
        }
    }
    hits.sort();
    hits.pop()
}

pub struct Args {
    pub count: Option<usize>,
    pub host: String,
    pub file: Option<PathBuf>,
    pub out: PathBuf,
    pub kernels: PathBuf,
    pub mkarea: Option<PathBuf>,
}

pub fn run(a: Args) -> Result<()> {
    if let Some(p) = &a.mkarea {
        fs::write(p, superblock()).with_context(|| format!("write {}", p.display()))?;
        println!("{}: boot log superblock ({} bytes; userdata block N-{FROM_END})", p.display(), BLOCK);
        return Ok(());
    }
    let mut current: Option<(u64, u32)> = None;
    let mut src: Box<dyn Source> = if let Some(f) = &a.file {
        let fh = fs::File::open(f).with_context(|| format!("open {}", f.display()))?;
        let len = fh.metadata()?.len();
        println!("source: {} ({} bytes)", f.display(), len);
        Box::new(FileSource(fh, len))
    } else {
        let (sock, phone) = crate::ctl::socket(&a.host)?;
        let s = UdpSource { sock, phone };
        let info = s.info()?;
        println!("phone: {info}");
        let w: Vec<&str> = info.split_whitespace().collect();
        let get = |k: &str| w.iter().position(|x| *x == k).and_then(|i| w.get(i + 1)).and_then(|v| v.parse::<u64>().ok());
        if let (Some(b), Some(s)) = (get("boot"), get("slot")) {
            current = Some((b, s as u32));
        }
        Box::new(s)
    };

    // superblock + slot headers
    let mut first: BTreeSet<u32> = (0..SLOTS).map(|i| 1 + i * SLOT_BLOCKS).collect();
    first.insert(0);
    let hdrs = src.read(&first)?;
    let sb = &hdrs[&0];
    if sb[..SUPER_LEN] != superblock()[..SUPER_LEN] {
        bail!("area block 0 is not the expected NEGRBLOG superblock (wrong offset, other layout, or the area was never written)");
    }
    let mut slots: Vec<Slot> = (0..SLOTS).filter_map(|i| parse_slot(i, &hdrs[&(1 + i * SLOT_BLOCKS)])).collect();
    slots.sort_by_key(|s| s.boot);
    if slots.is_empty() {
        println!("no valid slot header yet");
        return Ok(());
    }
    let pick = a.count.unwrap_or(slots.len()).min(slots.len());
    let chosen: Vec<Slot> = slots[slots.len() - pick..].to_vec();

    // ring blocks of the chosen slots
    let mut want = BTreeSet::new();
    for s in &chosen {
        let n = if s.total >= RING { RING / BLOCK as u64 } else { s.total.div_ceil(BLOCK as u64) };
        let base = 1 + s.index * SLOT_BLOCKS + 1;
        want.extend((0..n as u32).map(|k| base + k));
    }
    let data = src.read(&want)?;
    fs::create_dir_all(&a.out).with_context(|| format!("create {}", a.out.display()))?;

    println!();
    for s in &chosen {
        let base = 1 + s.index * SLOT_BLOCKS + 1;
        let ring_len = s.total.min(RING) as usize;
        let mut ring = vec![0u8; ring_len.div_ceil(BLOCK) * BLOCK];
        for k in 0..ring.len() / BLOCK {
            if let Some(d) = data.get(&(base + k as u32)) {
                ring[k * BLOCK..(k + 1) * BLOCK].copy_from_slice(d);
            }
        }
        let text: Vec<u8> = if s.total <= RING {
            ring[..ring_len].to_vec()
        } else {
            let at = (s.total % RING) as usize;
            [&ring[at..], &ring[..at]].concat()
        };
        let next = slots.iter().find(|x| x.boot == s.boot + 1);
        let this_boot = current.map_or(false, |(b, _)| b == s.boot);
        let end = match s.state {
            2 => format!("PANIC: {}", s.end),
            3 | 4 => format!("clean {}: {}", state_name(s.state), s.end),
            1 if this_boot => "still running (this boot)".to_string(),
            1 => format!("reset without panic (no end mark; last flush at uptime {:.1} s)", s.last_up_ms as f64 / 1e3),
            _ => format!("state {}", s.state),
        };
        let kern = if s.uuid.is_empty() { None } else { kernel_by_uuid(&a.kernels, &s.uuid) };
        let path = a.out.join(format!("bootlog-{}.txt", s.boot));
        let mut head = String::new();
        head += &format!("# NEGRONI boot log: boot {} (slot {}), state {}, {} flushes\n", s.boot, s.index, state_name(s.state), s.seq);
        head += &format!("# end: {end}\n");
        head += &format!(
            "# start {} UTC (phone clock), last flush {} UTC = uptime {:.1} s; SpringBoard {}; end mark at {}\n",
            utc(s.start_cal),
            utc(s.last_cal),
            s.last_up_ms as f64 / 1e3,
            if s.flags & 1 != 0 { format!("at {:.1} s", s.sb_up_ms as f64 / 1e3) } else { "never".into() },
            if s.end_up_ms != 0 { format!("{:.1} s", s.end_up_ms as f64 / 1e3) } else { "-".into() }
        );
        head += &format!("# kernel UUID {}{}\n", s.uuid, kern.as_ref().map_or(String::new(), |p| format!(" = {}", p.display())));
        head += &format!("# kernel version {}\n", s.kversion);
        head += &format!("# boot-args {}\n", s.bootargs);
        head += &format!("# PMIC PON log at this power-on (why the boot before ended): {}\n", if s.pon.is_empty() { "-" } else { &s.pon });
        if let Some(n) = next {
            head += &format!("# PMIC PON log at the next power-on (boot {}): {}\n", n.boot, if n.pon.is_empty() { "-" } else { &n.pon });
        }
        head += &format!(
            "# console bytes {}{}\n#\n",
            s.total,
            if s.total > RING { format!(" (the first {} bytes were overwritten in the 4 MiB ring)", s.total - RING) } else { String::new() }
        );
        let mut file = head.into_bytes();
        file.extend_from_slice(&text);
        fs::write(&path, &file).with_context(|| format!("write {}", path.display()))?;

        println!(
            "boot {:>4} slot {}  {}  up {:>7.1} s  SpringBoard {:<3}  end: {}",
            s.boot,
            s.index,
            utc(s.start_cal),
            s.last_up_ms as f64 / 1e3,
            if s.flags & 1 != 0 { "yes" } else { "no" },
            end
        );
        if s.state == 1 && !this_boot {
            if let Some(n) = next {
                println!("           next power-on PMIC PON log: {}", if n.pon.is_empty() { "-" } else { &n.pon });
            }
        }
        let txt = String::from_utf8_lossy(&text);
        let lines: Vec<&str> = txt.lines().map(|l| l.trim_end()).filter(|l| !l.is_empty()).collect();
        for l in &lines[lines.len().saturating_sub(5)..] {
            let l: String = l.chars().take(160).collect();
            println!("           | {l}");
        }
        println!("           -> {}", path.display());
    }
    Ok(())
}
