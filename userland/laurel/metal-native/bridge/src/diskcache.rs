// SPDX-License-Identifier: MIT
//! The stack's compile cache on disk: the translator's pipeline and the ir3 code, by what they are made from. With it a start of the compositor reads files; with no cache it compiled each pipeline for 100 to 560 ms, and the first frame came 3 min after the device opened [V log 07:22:04 to 07:25:20].
//! One folder for each build of this image: a new build compiles again, and an older folder is removed. A file a reset cut or left with old blocks (a CTL reboot has no sync) fails its check and is compiled again: a code word that is wrong would hang the GPU, so nothing is trusted unchecked.
use crate::ffi::nmn_cache_id;
use std::ffi::{CStr, c_char};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};

const MAGIC: &[u8; 4] = b"NMNC";
const HEADER: usize = 4 + 4 + 8 + 8;
const LIMIT: u64 = 128 << 20;

fn fnv(seed: u64, bytes: &[u8]) -> u64 {
    let mut h = seed;
    // eight bytes a step: a pipeline's file is up to some MB, and this runs on each read at a start
    let mut chunks = bytes.chunks_exact(8);
    for c in &mut chunks {
        h = (h ^ u64::from_le_bytes(c.try_into().unwrap())).wrapping_mul(0x0000_0100_0000_01b3);
        h ^= h >> 29;
    }
    for b in chunks.remainder() {
        h = (h ^ *b as u64).wrapping_mul(0x0000_0100_0000_01b3);
    }
    h
}

pub(crate) struct DiskCache {
    dir: Option<PathBuf>,
    bytes: AtomicU64,
    pub(crate) hits: AtomicU64,
    pub(crate) misses: AtomicU64,
}

impl DiskCache {
    /// base: the frontend's cache folder of this process. One line when it cannot be used: a compile takes longer then, nothing else changes.
    pub(crate) fn open(base: *const c_char) -> DiskCache {
        let mut cache = DiskCache { dir: None, bytes: AtomicU64::new(0), hits: AtomicU64::new(0), misses: AtomicU64::new(0) };
        if base.is_null() {
            return cache;
        }
        let base = PathBuf::from(unsafe { CStr::from_ptr(base) }.to_string_lossy().into_owned());
        let id = unsafe { CStr::from_ptr(nmn_cache_id()) }.to_string_lossy().into_owned();
        let name = format!("native-{id}");
        if let Ok(list) = std::fs::read_dir(&base) {
            for e in list.flatten() {
                let n = e.file_name().to_string_lossy().into_owned();
                if n.starts_with("native-") && n != name {
                    let _ = std::fs::remove_dir_all(e.path());
                }
            }
        }
        let dir = base.join(name);
        if let Err(x) = std::fs::create_dir_all(&dir) {
            crate::draw::console_line(&format!("LAUREL METAL NATIVE CACHE: off: {}: {x}", dir.display()));
            return cache;
        }
        let used: u64 = std::fs::read_dir(&dir).map(|l| l.flatten().filter_map(|e| e.metadata().ok()).map(|m| m.len()).sum()).unwrap_or(0);
        cache.bytes = AtomicU64::new(used);
        cache.dir = Some(dir);
        cache
    }

    fn path(&self, key: &str) -> Option<PathBuf> {
        Some(self.dir.as_ref()?.join(format!("{:016x}{:016x}", fnv(0xcbf2_9ce4_8422_2325, key.as_bytes()), fnv(0x8422_2325_cbf2_9ce4, key.as_bytes()))))
    }

    pub(crate) fn get(&self, key: &str) -> Option<Vec<u8>> {
        let path = self.path(key)?;
        let data = match std::fs::read(&path) {
            Ok(d) => d,
            Err(_) => {
                self.misses.fetch_add(1, Ordering::Relaxed);
                return None;
            }
        };
        let good = (|| {
            if data.len() < HEADER || &data[..4] != MAGIC {
                return None;
            }
            let klen = u32::from_le_bytes(data[4..8].try_into().ok()?) as usize;
            let blen = u64::from_le_bytes(data[8..16].try_into().ok()?) as usize;
            let sum = u64::from_le_bytes(data[16..24].try_into().ok()?);
            if data.len() != HEADER + klen + blen || &data[HEADER..HEADER + klen] != key.as_bytes() || fnv(0xcbf2_9ce4_8422_2325, &data[HEADER..]) != sum {
                return None;
            }
            Some(HEADER + klen)
        })();
        match good {
            Some(at) => {
                self.hits.fetch_add(1, Ordering::Relaxed);
                Some(data[at..].to_vec())
            }
            None => {
                let _ = std::fs::remove_file(&path);
                self.misses.fetch_add(1, Ordering::Relaxed);
                None
            }
        }
    }

    pub(crate) fn put(&self, key: &str, body: &[u8]) {
        let Some(path) = self.path(key) else { return };
        let size = (HEADER + key.len() + body.len()) as u64;
        if self.bytes.load(Ordering::Relaxed) + size > LIMIT {
            static TOLD: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
            if !TOLD.swap(true, Ordering::Relaxed) {
                crate::draw::console_line(&format!("LAUREL METAL NATIVE CACHE: full at {} MB: later pipelines compile at each start", LIMIT >> 20));
            }
            return;
        }
        let mut out = Vec::with_capacity(size as usize);
        out.extend_from_slice(MAGIC);
        out.extend_from_slice(&(key.len() as u32).to_le_bytes());
        out.extend_from_slice(&(body.len() as u64).to_le_bytes());
        out.extend_from_slice(&[0u8; 8]);
        out.extend_from_slice(key.as_bytes());
        out.extend_from_slice(body);
        let sum = fnv(0xcbf2_9ce4_8422_2325, &out[HEADER..]);
        out[16..24].copy_from_slice(&sum.to_le_bytes());
        let tmp = path.with_extension(format!("{}.tmp", std::process::id()));
        if std::fs::write(&tmp, &out).is_ok() && std::fs::rename(&tmp, &path).is_ok() {
            self.bytes.fetch_add(size, Ordering::Relaxed);
        } else {
            let _ = std::fs::remove_file(&tmp);
        }
    }
}
