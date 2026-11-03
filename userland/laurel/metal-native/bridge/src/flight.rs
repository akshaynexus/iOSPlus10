// SPDX-License-Identifier: MIT
//! The flight recorder: text lines in a memory-mapped ring (the stack folder's flight-PROCESS), written with no system call, so they survive what kills the process at a GPU hang: the kernel does that first [V logs 06:47:15, 08:03:15]. Each draw: its program, its descriptor words, its constants; each submission: its fence, which the kernel's hang line names.
//! On only while the file stack/flight-on exists (scripts/laurel/native/compositor-round.sh): it formats text for each draw. Read: scripts/laurel/native/flight-read.py.
use std::sync::OnceLock;
use std::sync::atomic::{AtomicUsize, Ordering};

const SIZE: usize = 4 << 20;
const HEAD: usize = 64;

struct Ring {
    base: usize,
    pos: AtomicUsize,
}

fn ring() -> Option<&'static Ring> {
    static RING: OnceLock<Option<Ring>> = OnceLock::new();
    RING.get_or_init(|| {
        const DIR: &str = "/private/var/db/negronimetal/stack";
        if std::fs::metadata(format!("{DIR}/flight-on")).is_err() {
            return None;
        }
        let name = std::env::current_exe().ok()?.file_name()?.to_string_lossy().into_owned();
        // the file of the last start stays as .old: a hang outside a test round is then still readable after the next start
        let _ = std::fs::rename(format!("{DIR}/flight-{name}"), format!("{DIR}/flight-{name}.old"));
        let f = std::fs::OpenOptions::new().create(true).truncate(true).read(true).write(true).open(format!("{DIR}/flight-{name}")).ok()?;
        f.set_len(SIZE as u64).ok()?;
        use std::os::fd::AsRawFd;
        let m = unsafe { libc::mmap(std::ptr::null_mut(), SIZE, libc::PROT_READ | libc::PROT_WRITE, libc::MAP_SHARED, f.as_raw_fd(), 0) };
        if m == libc::MAP_FAILED {
            return None;
        }
        Some(Ring { base: m as usize, pos: AtomicUsize::new(0) })
    })
    .as_ref()
}

pub(crate) fn on() -> bool {
    ring().is_some()
}

pub(crate) fn line(text: &str) {
    let Some(r) = ring() else { return };
    let bytes = text.as_bytes();
    let n = bytes.len() + 1;
    let room = SIZE - HEAD;
    let at = r.pos.fetch_add(n, Ordering::Relaxed);
    unsafe {
        let base = r.base as *mut u8;
        for (i, b) in bytes.iter().chain(std::iter::once(&b'\n')).enumerate() {
            *base.add(HEAD + (at + i) % room) = *b;
        }
        // the end of the text, for the reader
        std::ptr::write_volatile(base as *mut u64, (at + n) as u64);
    }
}

/// Progress of the GPU: each draw gets an id, and the stream writes the id to one word when that draw has left the render backend (nmn_cmd_progress). A thread copies the word into the ring's head (byte 8),
/// so after a hang the file says the last finished draw: the next id in the ring is the stuck draw. None: the recorder is off, or the word is not in pool memory (a scattered buffer would have to be named in each submission).
pub(crate) fn next_mark(gpu: &std::sync::Arc<crate::draw::Gpu>) -> Option<(u64, u32)> {
    static WORD: OnceLock<Option<u64>> = OnceLock::new();
    static NEXT: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(1);
    let r = ring()?;
    let iova = WORD
        .get_or_init(|| {
            let s = crate::draw::Slice::new(gpu, 4096, 4096).ok()?;
            if s.iova < 0x8000_0000 {
                return None;
            }
            let (word, head) = (s.map, r.base);
            std::thread::spawn(move || loop {
                let v = unsafe { std::ptr::read_volatile(word as *const u32) };
                unsafe { std::ptr::write_volatile((head + 8) as *mut u32, v) };
                std::thread::sleep(std::time::Duration::from_millis(1));
            });
            let iova = s.iova;
            std::mem::forget(s); // for the process's life: the stream and the thread use it
            Some(iova)
        })
        .as_ref()?;
    Some((*iova, NEXT.fetch_add(1, Ordering::Relaxed)))
}

/// The words of a descriptor set, to the last that is not 0.
pub(crate) fn set_words(set: usize, iova: u64, words: *const u32, slots: u32) -> String {
    let mut s = format!("  set {set} at {iova:#x}, {slots} slots:");
    for slot in 0..slots.min(64) as usize {
        let w = unsafe { std::slice::from_raw_parts(words.add(slot * 16), 16) };
        if w.iter().any(|x| *x != 0) {
            s.push_str(&format!(" [{slot}]"));
            let last = w.iter().rposition(|x| *x != 0).unwrap_or(0);
            for x in &w[..=last] {
                s.push_str(&format!(" {x:08x}"));
            }
        }
    }
    s
}

pub(crate) fn hex(bytes: &[u8]) -> String {
    let mut s = String::with_capacity(bytes.len() * 2 + 8);
    for c in bytes.chunks(4) {
        for b in c.iter().rev() {
            s.push_str(&format!("{b:02x}"));
        }
        s.push(' ');
    }
    s
}
