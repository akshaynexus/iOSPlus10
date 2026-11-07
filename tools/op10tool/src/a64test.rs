//! `op10tool a64-selftest`: real execution check of the LSE trampolines, no Apple code involved.
//! Two static ELF programs run the same cases: one executes the LSE word itself under `qemu-aarch64 -cpu max`, one reaches
//! the same effect through `a64::lse_trampoline` (direct bl, and the x30 stub) under `qemu-aarch64 -cpu cortex-a53`, which
//! refuses anything above ARMv8.0. Every case dumps x0-x30, NZCV, the 16 words of the red zone below SP and the memory
//! cell; the two dumps must be the same byte for byte.

use crate::a64::{self, enc, Fp16Cmp, Lse, LseOp};
use anyhow::{bail, Context, Result};
use std::fs;
use std::path::Path;
use std::process::Command;

const BASE: u64 = 0x40_0000;
const OUT_SIZE: usize = 8 * 34 + 128 + 32;
const IN_SIZE: usize = 8 * 34;
const STACK_TOP_OFF: usize = 1 << 16;

#[derive(Clone, Copy)]
struct Case {
    word: u32,
    lse: Lse,
    regs: [u64; 31],
    nzcv: u64,
    cell: [u64; 2],
}

fn rng(s: &mut u64) -> u64 {
    *s ^= *s << 13;
    *s ^= *s >> 7;
    *s ^= *s << 17;
    *s
}

fn mov64(out: &mut Vec<u32>, r: u32, v: u64) {
    out.push(0xd280_0000 | ((v & 0xffff) as u32) << 5 | r);
    for i in 1..4 {
        out.push(0xf280_0000 | (i as u32) << 21 | (((v >> (16 * i)) & 0xffff) as u32) << 5 | r);
    }
}

fn elf(code: &[u32], data_off: usize, data: &[u8], memsz: u64) -> Vec<u8> {
    let mut f = vec![0u8; 0x78];
    f[0..4].copy_from_slice(b"\x7fELF");
    f[4] = 2;
    f[5] = 1;
    f[6] = 1;
    f[16] = 2; // ET_EXEC
    f[18] = 183; // EM_AARCH64
    f[20] = 1;
    f[24..32].copy_from_slice(&(BASE + 0x78).to_le_bytes());
    f[32..40].copy_from_slice(&64u64.to_le_bytes());
    f[52] = 64;
    f[54] = 56;
    f[56] = 1;
    let p = 64;
    f[p] = 1;
    f[p + 4] = 7; // RWX
    f[p + 16..p + 24].copy_from_slice(&BASE.to_le_bytes());
    f[p + 24..p + 32].copy_from_slice(&BASE.to_le_bytes());
    for w in code {
        f.extend_from_slice(&w.to_le_bytes());
    }
    assert!(f.len() <= data_off);
    f.resize(data_off, 0);
    f.extend_from_slice(data);
    let total = f.len() as u64;
    f[p + 32..p + 40].copy_from_slice(&total.to_le_bytes());
    f[p + 40..p + 48].copy_from_slice(&memsz.max(total).to_le_bytes());
    f[p + 48..p + 56].copy_from_slice(&0x1000u64.to_le_bytes());
    f
}

/// Build one program. `lowered`: use trampolines, else the word itself. x30 is zeroed in the dump when the mode is direct bl.
fn program(cases: &[Case], lowered: bool) -> Vec<u8> {
    let n = cases.len();
    // addresses: code first; 80 words per case + trampolines; data after a rounded offset
    let mut tramps: Vec<u32> = Vec::new();
    let mut body_len = 0usize;
    let per_case = 170usize;
    let code_cap = 0x78 + (n * per_case + 16 + n * 40) * 4;
    let data_off = (code_cap + 0xffff) & !0xffff;
    let data_base = BASE + data_off as u64;
    let inputs = data_base;
    let cells = inputs + (n * IN_SIZE) as u64;
    let cells = (cells + 15) & !15;
    let stack_base = cells + (n * 16) as u64;
    let stack_base = (stack_base + 15) & !15;
    let stack_top = stack_base + STACK_TOP_OFF as u64;
    let outs = stack_top + 4096;
    let total = outs + (n * OUT_SIZE) as u64;
    // data
    let mut data = vec![0u8; (outs - data_base) as usize];
    let sentinel = 0x5a5a_a5a5_1234_8765u64;
    for i in 0..16 {
        let off = (stack_top - data_base) as usize - 128 + i * 8;
        data[off..off + 8].copy_from_slice(&(sentinel ^ i as u64).to_le_bytes());
    }
    let mut code: Vec<u32> = Vec::new();
    // first pass with placeholder trampoline offsets: the sites patch below
    let mut sites: Vec<(usize, usize)> = Vec::new();
    for (i, c) in cases.iter().enumerate() {
        let off = (inputs - data_base) as usize + i * IN_SIZE;
        let mut regs = c.regs;
        regs[c.lse.rn as usize] = cells + (i as u64) * 16;
        for (j, v) in regs.iter().enumerate() {
            data[off + j * 8..off + j * 8 + 8].copy_from_slice(&v.to_le_bytes());
        }
        data[off + 31 * 8..off + 32 * 8].copy_from_slice(&c.nzcv.to_le_bytes());
        let cell = (cells - data_base) as usize + i * 16;
        data[cell..cell + 8].copy_from_slice(&c.cell[0].to_le_bytes());
        data[cell + 8..cell + 16].copy_from_slice(&c.cell[1].to_le_bytes());
        // set SP
        mov64(&mut code, 0, stack_top);
        code.push(0x9100_001f); // mov sp, x0
        mov64(&mut code, 0, inputs + (i * IN_SIZE) as u64);
        // nzcv
        code.push(0xf940_0000 | 31 << 10 | 1); // ldr x1, [x0, #248]
        code.push(enc::msr_nzcv(1));
        // x1..x30
        let mut r = 1u32;
        while r < 30 {
            code.push(0xa940_0000 | ((r / 1) * 8 / 8) << 15 | (r + 1) << 10 | r); // ldp xr, xr+1, [x0, #8r]
            r += 2;
        }
        code.push(0xf940_0000 | 30 << 10 | 30); // ldr x30, [x0, #240]
        code.push(0xf940_0000); // ldr x0, [x0]
        // the site
        let stub_mode = i % 2 == 1;
        if lowered {
            sites.push((code.len(), i));
            code.push(a64::NOP);
        } else {
            code.push(c.word);
        }
        // dump: x0 goes above SP first
        code.push(enc::str_sp(0, 0));
        mov64(&mut code, 0, outs + (i * OUT_SIZE) as u64);
        let mut r = 1u32;
        while r < 29 {
            code.push(0xa900_0000 | r << 15 | (r + 1) << 10 | r); // stp xr, xr+1, [x0, #8r]
            r += 2;
        }
        code.push(0xf900_0000 | 29 << 10 | 29); // str x29, [x0, #232]
        if !stub_mode {
            code.push(0xd280_001e); // movz x30, #0: bl mode, x30 is dead there
        }
        code.push(0xf900_0000 | 30 << 10 | 30); // str x30, [x0, #240]
        code.push(enc::ldr_sp(1, 0));
        code.push(0xf900_0000 | 1); // str x1, [x0]
        code.push(enc::mrs_nzcv(1));
        code.push(0xf900_0000 | 31 << 10 | 1); // str x1, [x0, #248]
        code.push(0x9100_03e1); // mov x1, sp
        code.push(0x9100_0000 | (264 + 8) << 10 | 0 << 5 | 2); // add x2, x0, #272
        // 16 words below SP
        for k in 0..8u32 {
            let imm = ((-128i32 + k as i32 * 16) / 8) as u32 & 0x7f;
            code.push(0xa940_0000 | imm << 15 | 4 << 10 | 1 << 5 | 3); // ldp x3, x4, [x1, #-128+16k]
            code.push(0xa900_0000 | (k * 2) << 15 | 4 << 10 | 2 << 5 | 3); // stp x3, x4, [x2, #16k]
        }
        // cell
        mov64(&mut code, 1, cells + (i as u64) * 16);
        code.push(0xa940_0000 | 4 << 10 | 1 << 5 | 3); // ldp x3, x4, [x1]
        code.push(0xa900_0000 | 16 << 15 | 4 << 10 | 2 << 5 | 3); // stp x3, x4, [x2, #128]
        body_len = code.len();
    }
    let _ = body_len;
    // end: write(1, outs, n * OUT_SIZE); exit(0)
    mov64(&mut code, 0, 1);
    mov64(&mut code, 1, outs);
    mov64(&mut code, 2, (n * OUT_SIZE) as u64);
    mov64(&mut code, 8, 64);
    code.push(0xd400_0001); // svc 0
    mov64(&mut code, 0, 0);
    mov64(&mut code, 8, 93);
    code.push(0xd400_0001);
    // trampolines, stubs, patch sites
    if lowered {
        let start = code.len();
        for (at, i) in sites {
            let c = &cases[i];
            let t = a64::lse_trampoline(&c.lse);
            let stub_mode = i % 2 == 1;
            let here = start + tramps.len();
            if stub_mode {
                let stub_at = here;
                let tramp_at = here + 4;
                let stub = a64::lse_stub(tramp_at as i32 - (stub_at as i32 + 1), (at + 1) as i32 - (stub_at as i32 + 3));
                tramps.extend_from_slice(&stub);
                tramps.extend_from_slice(&t);
                code[at] = enc::b_words(stub_at as i32 - at as i32);
            } else {
                tramps.extend_from_slice(&t);
                code[at] = enc::bl_words(here as i32 - at as i32);
            }
        }
        code.extend_from_slice(&tramps);
    }
    assert!(0x78 + code.len() * 4 <= data_off, "code {} > data_off {}", code.len() * 4, data_off);
    elf(&code, data_off, &data, total - BASE)
}

fn synth_words() -> Vec<u32> {
    let mut out = Vec::new();
    let regs: [(u32, u32, u32); 10] = [
        (0, 1, 2),
        (1, 1, 2),    // Rs = Rt
        (3, 31, 4),   // Rt = zr
        (31, 5, 6),   // Rs = zr
        (9, 10, 11),  // scratch candidates
        (16, 17, 15), // scratch candidates
        (9, 9, 16),
        (28, 29, 27),
        (8, 2, 2),    // Rt = Rn
        (2, 8, 2),    // Rs = Rn
    ];
    for size in 0..4u32 {
        for a in 0..2u32 {
            for r in 0..2u32 {
                for (rs, rt, rn) in regs {
                    // cas
                    out.push(size << 30 | 0x08a0_7c00 | a << 22 | r << 15 | rs << 16 | rn << 5 | rt);
                    // ld<op>, swp
                    for op in [0u32, 1, 2, 3, 4, 5, 6, 7, 8] {
                        out.push(size << 30 | 0x3820_0000 | a << 23 | r << 22 | rs << 16 | op << 12 | rn << 5 | rt);
                    }
                }
            }
        }
    }
    for sz in [0u32, 1] {
        for a in 0..2u32 {
            for r in 0..2u32 {
                for (rs, rt, rn) in [(0u32, 2u32, 4u32), (2, 0, 6), (8, 10, 12), (16, 14, 9), (10, 16, 17)] {
                    out.push(sz << 30 | 0x0820_7c00 | a << 22 | r << 15 | rs << 16 | rn << 5 | rt);
                }
            }
        }
    }
    out.retain(|w| a64::lse_decode(*w).is_some_and(|l| a64::lse_refuses(&l).is_none() && valid_regs(&l)));
    out.sort();
    out.dedup();
    out
}

/// Registers the architecture defines for this form (we do not test CONSTRAINED UNPREDICTABLE overlaps).
fn valid_regs(l: &Lse) -> bool {
    if l.op == LseOp::Casp {
        let (s, t, n) = (l.rs, l.rt, l.rn);
        return n != s && n != s + 1 && n != t && n != t + 1 && s != t;
    }
    true
}

/// One FP16 compare case: every V register (both halves), NZCV, FPCR, and the x30 sentinel.
#[derive(Clone, Copy)]
struct FpCase {
    word: u32,
    cmp: Fp16Cmp,
    v: [[u64; 2]; 32],
    nzcv: u64,
    fpcr: u64,
}

const FP_IN_SIZE: usize = 32 * 16 + 32;
const FP_OUT_SIZE: usize = 32 * 16 + 32 + 128;

/// Half values that matter for a compare: zeros, ones, infinities, quiet and signaling NaNs, denormals, random.
fn half(seed: &mut u64) -> u16 {
    const EDGE: [u16; 12] = [0x0000, 0x8000, 0x3c00, 0xbc00, 0x7c00, 0xfc00, 0x7e00, 0xfe00, 0x7d00, 0x0001, 0x8001, 0x03ff];
    let r = rng(seed);
    if r & 3 == 0 {
        EDGE[(r >> 8) as usize % EDGE.len()]
    } else {
        (r >> 16) as u16
    }
}

fn fp16_words() -> Vec<u32> {
    let mut out = Vec::new();
    let pairs: [(u32, u32); 12] = [(2, 0), (0, 1), (0, 0), (16, 17), (17, 16), (16, 18), (19, 16), (18, 19), (31, 30), (7, 16), (17, 3), (20, 21)];
    for signal in 0..2u32 {
        for (rn, rm) in pairs {
            out.push(0x1ee0_2000 | rm << 16 | rn << 5 | signal << 4);
        }
        for rn in [0u32, 2, 16, 17, 18, 19, 31] {
            out.push(0x1ee0_2000 | rn << 5 | 8 | signal << 4);
        }
    }
    out.retain(|w| a64::fp16cmp_decode(*w).is_some());
    out.sort();
    out.dedup();
    out
}

/// The FP16 program: the same shape as `program`, with the V registers, FPCR and FPSR in the dump.
fn program_fp16(cases: &[FpCase], lowered: bool) -> Vec<u8> {
    let n = cases.len();
    let per_case = 200usize;
    let code_cap = 0x78 + (n * per_case + 16 + n * 24) * 4;
    let data_off = (code_cap + 0xffff) & !0xffff;
    let data_base = BASE + data_off as u64;
    let inputs = data_base;
    let stack_base = (inputs + (n * FP_IN_SIZE) as u64 + 15) & !15;
    let stack_top = stack_base + STACK_TOP_OFF as u64;
    let outs = stack_top + 4096;
    let total = outs + (n * FP_OUT_SIZE) as u64;
    let mut data = vec![0u8; (outs - data_base) as usize];
    let sentinel = 0x5a5a_a5a5_1234_8765u64;
    for i in 0..16 {
        let off = (stack_top - data_base) as usize - 128 + i * 8;
        data[off..off + 8].copy_from_slice(&(sentinel ^ i as u64).to_le_bytes());
    }
    let mut code: Vec<u32> = Vec::new();
    let mut sites: Vec<(usize, usize)> = Vec::new();
    for (i, c) in cases.iter().enumerate() {
        let off = (inputs - data_base) as usize + i * FP_IN_SIZE;
        for (j, v) in c.v.iter().enumerate() {
            data[off + j * 16..off + j * 16 + 8].copy_from_slice(&v[0].to_le_bytes());
            data[off + j * 16 + 8..off + j * 16 + 16].copy_from_slice(&v[1].to_le_bytes());
        }
        data[off + 512..off + 520].copy_from_slice(&c.fpcr.to_le_bytes());
        data[off + 520..off + 528].copy_from_slice(&c.nzcv.to_le_bytes());
        mov64(&mut code, 0, stack_top);
        code.push(0x9100_001f); // mov sp, x0
        mov64(&mut code, 0, inputs + (i * FP_IN_SIZE) as u64);
        for r in 0..32u32 {
            code.push(0x3dc0_0000 | r << 10 | r); // ldr qr, [x0, #16r]
        }
        code.push(0xf940_0000 | 64 << 10 | 1); // ldr x1, [x0, #512]
        code.push(0xd51b_4401); // msr fpcr, x1
        code.push(0xd51b_443f); // msr fpsr, xzr
        code.push(0xf940_0000 | 65 << 10 | 1); // ldr x1, [x0, #520]
        code.push(enc::msr_nzcv(1));
        mov64(&mut code, 30, sentinel ^ i as u64); // x30 must survive the stub
        let stub_mode = i % 2 == 1;
        if lowered {
            sites.push((code.len(), i));
            code.push(a64::NOP);
        } else {
            code.push(c.word);
        }
        mov64(&mut code, 0, outs + (i * FP_OUT_SIZE) as u64);
        for r in 0..32u32 {
            code.push(0x3d80_0000 | r << 10 | r); // str qr, [x0, #16r]
        }
        code.push(enc::mrs_nzcv(1));
        code.push(0xf900_0000 | 64 << 10 | 1); // str x1, [x0, #512]
        code.push(0xd53b_4421); // mrs x1, fpsr
        code.push(0xf900_0000 | 65 << 10 | 1); // str x1, [x0, #520]
        if !stub_mode {
            code.push(0xd280_001e); // bl mode: x30 is dead there
        }
        code.push(0xf900_0000 | 66 << 10 | 30); // str x30, [x0, #528]
        code.push(0x9100_03e1); // mov x1, sp
        code.push(0x9100_0000 | 544 << 10 | 2); // add x2, x0, #544
        for k in 0..8u32 {
            let imm = ((-128i32 + k as i32 * 16) / 8) as u32 & 0x7f;
            code.push(0xa940_0000 | imm << 15 | 4 << 10 | 1 << 5 | 3); // ldp x3, x4, [x1, #-128+16k]
            code.push(0xa900_0000 | (k * 2) << 15 | 4 << 10 | 2 << 5 | 3); // stp x3, x4, [x2, #16k]
        }
    }
    mov64(&mut code, 0, 1);
    mov64(&mut code, 1, outs);
    mov64(&mut code, 2, (n * FP_OUT_SIZE) as u64);
    mov64(&mut code, 8, 64);
    code.push(0xd400_0001);
    mov64(&mut code, 0, 0);
    mov64(&mut code, 8, 93);
    code.push(0xd400_0001);
    if lowered {
        let start = code.len();
        let mut tramps: Vec<u32> = Vec::new();
        for (at, i) in sites {
            let t = a64::fp16cmp_trampoline(&cases[i].cmp);
            let here = start + tramps.len();
            if i % 2 == 1 {
                let stub = a64::lse_stub((here + 4) as i32 - (here as i32 + 1), (at + 1) as i32 - (here as i32 + 3));
                tramps.extend_from_slice(&stub);
                tramps.extend_from_slice(&t);
                code[at] = enc::b_words(here as i32 - at as i32);
            } else {
                tramps.extend_from_slice(&t);
                code[at] = enc::bl_words(here as i32 - at as i32);
            }
        }
        code.extend_from_slice(&tramps);
    }
    assert!(0x78 + code.len() * 4 <= data_off, "code {} > data_off {}", code.len() * 4, data_off);
    elf(&code, data_off, &data, total - BASE)
}

fn run_fp16(words: &[u32], outdir: &Path, run_one: &dyn Fn(&Path, &str) -> Result<Vec<u8>>) -> Result<(usize, usize)> {
    let mut seed = 0x1234_5678_9abc_def1u64;
    let mut cases = Vec::new();
    for &w in words {
        let cmp = a64::fp16cmp_decode(w).unwrap();
        // 8 cases a word: bl and stub mode (parity), FPCR 0 and AHP (FZ16 is RES0 on a CPU without FEAT_FP16: never set here), equal operands twice
        for variant in 0..8 {
            let mut v = [[0u64; 2]; 32];
            for r in v.iter_mut() {
                r[0] = rng(&mut seed) & !0xffff | half(&mut seed) as u64;
                r[1] = rng(&mut seed);
            }
            if variant >= 6 {
                v[cmp.rm as usize][0] = v[cmp.rn as usize][0];
            }
            let fpcr = if variant & 2 != 0 { 1 << 26 } else { 0 };
            let nzcv = ((rng(&mut seed) >> 60) & 0xf) << 28;
            cases.push(FpCase { word: w, cmp, v, nzcv, fpcr });
        }
    }
    let (np, lp) = (outdir.join("selftest-fp16-native.elf"), outdir.join("selftest-fp16-lowered.elf"));
    fs::write(&np, program_fp16(&cases, false))?;
    fs::write(&lp, program_fp16(&cases, true))?;
    for p in [&np, &lp] {
        fs::set_permissions(p, std::os::unix::fs::PermissionsExt::from_mode(0o755))?;
    }
    let a = run_one(&np, "max")?;
    let b = run_one(&lp, "cortex-a53")?;
    if a.len() != cases.len() * FP_OUT_SIZE || b.len() != a.len() {
        bail!("fp16 dump size: native {}, lowered {}, expected {}", a.len(), b.len(), cases.len() * FP_OUT_SIZE);
    }
    let mut bad = 0usize;
    for (i, (x, y)) in a.chunks(FP_OUT_SIZE).zip(b.chunks(FP_OUT_SIZE)).enumerate() {
        if x != y {
            bad += 1;
            if bad <= 8 {
                let c = &cases[i];
                let first = x.iter().zip(y).position(|(p, q)| p != q).unwrap();
                let rx = u64::from_le_bytes(x[first & !7..(first & !7) + 8].try_into().unwrap());
                let ry = u64::from_le_bytes(y[first & !7..(first & !7) + 8].try_into().unwrap());
                println!("fp16 case {i} word {:#010x} {:?} fpcr {:#x} hn {:#06x} hm {:#06x}: first diff at dump offset {first}: native {rx:#x}, lowered {ry:#x}", c.word, c.cmp, c.fpcr, c.v[c.cmp.rn as usize][0] & 0xffff, c.v[c.cmp.rm as usize][0] & 0xffff);
            }
        }
    }
    let _ = fs::remove_file(&np);
    let _ = fs::remove_file(&lp);
    Ok((cases.len(), bad))
}

pub fn run(words: Option<&Path>, outdir: &Path) -> Result<()> {
    fs::create_dir_all(outdir)?;
    let mut list = synth_words();
    let synth = list.len();
    let mut fp16 = fp16_words();
    let fp16_synth = fp16.len();
    if let Some(p) = words {
        for line in fs::read_to_string(p).with_context(|| format!("read {}", p.display()))?.lines() {
            let t = line.trim().trim_start_matches("0x");
            if t.is_empty() {
                continue;
            }
            let w = u32::from_str_radix(t, 16).with_context(|| format!("word {line}"))?;
            if a64::lse_decode(w).is_some_and(|l| a64::lse_refuses(&l).is_none() && valid_regs(&l)) {
                list.push(w);
            }
            if a64::fp16cmp_decode(w).is_some() {
                fp16.push(w);
            }
        }
    }
    list.sort();
    list.dedup();
    let mut seed = 0x9e37_79b9_7f4a_7c15u64;
    let mut cases = Vec::new();
    for &w in &list {
        let l = a64::lse_decode(w).unwrap();
        // each word: bl mode and stub mode (index parity), compare equal and not equal
        for variant in 0..4 {
            let mut regs = [0u64; 31];
            for r in regs.iter_mut() {
                *r = rng(&mut seed);
            }
            let mut cell = [rng(&mut seed), rng(&mut seed)];
            if variant >= 2 {
                // small values make min/max and equal compares real
                for r in regs.iter_mut() {
                    *r &= 0xff;
                }
                cell[0] &= 0xff;
            }
            if l.rs != 31 && variant % 2 == 1 {
                match l.op {
                    LseOp::Casp => {
                        cell = [regs[l.rs as usize], regs[l.rs as usize + 1]];
                        if l.size == 2 {
                            cell = [(regs[l.rs as usize] & 0xffff_ffff) | (regs[l.rs as usize + 1] << 32), cell[1]];
                        }
                    }
                    _ => cell[0] = regs[l.rs as usize],
                }
            }
            if l.rs == 31 && variant % 2 == 1 && l.op == LseOp::Cas {
                cell[0] = 0;
            }
            // Rs or Rt equal to Rn: the value is the cell address, so the compare runs on the address in both programs.
            let nzcv = ((rng(&mut seed) >> 60) & 0xf) << 28;
            cases.push(Case { word: w, lse: l, regs, nzcv, cell });
        }
    }
    let native = program(&cases, false);
    let lowered = program(&cases, true);
    let (np, lp) = (outdir.join("selftest-native.elf"), outdir.join("selftest-lowered.elf"));
    fs::write(&np, native)?;
    fs::write(&lp, lowered)?;
    for p in [&np, &lp] {
        fs::set_permissions(p, std::os::unix::fs::PermissionsExt::from_mode(0o755))?;
    }
    let run_one = |path: &Path, cpu: &str| -> Result<Vec<u8>> {
        let o = Command::new("qemu-aarch64").args(["-cpu", cpu]).arg(path).output().context("run qemu-aarch64")?;
        if !o.status.success() {
            bail!("{} under -cpu {cpu}: status {:?}\n{}", path.display(), o.status.code(), String::from_utf8_lossy(&o.stderr));
        }
        Ok(o.stdout)
    };
    fp16.sort();
    fp16.dedup();
    let (fp16_cases, fp16_bad) = run_fp16(&fp16, outdir, &run_one)?;
    println!("a64-selftest fp16: {} fcmp/fcmpe words ({fp16_synth} synthetic), {fp16_cases} cases, {fp16_bad} mismatches", fp16.len());
    let a = run_one(&np, "max")?;
    let b = run_one(&lp, "cortex-a53")?;
    if a.len() != cases.len() * OUT_SIZE || b.len() != a.len() {
        bail!("dump size: native {}, lowered {}, expected {}", a.len(), b.len(), cases.len() * OUT_SIZE);
    }
    let mut bad = 0usize;
    for (i, (x, y)) in a.chunks(OUT_SIZE).zip(b.chunks(OUT_SIZE)).enumerate() {
        if x != y {
            bad += 1;
            if bad <= 8 {
                let c = &cases[i];
                let first = x.iter().zip(y).position(|(p, q)| p != q).unwrap();
                let rx = u64::from_le_bytes(x[first & !7..(first & !7) + 8].try_into().unwrap());
                let ry = u64::from_le_bytes(y[first & !7..(first & !7) + 8].try_into().unwrap());
                println!("case {i} word {:#010x} {:?}: first diff at dump offset {first}: native {rx:#x}, lowered {ry:#x}", c.word, c.lse);
            }
        }
    }
    println!("a64-selftest: {} words ({synth} synthetic), {} cases, {bad} mismatches; native -cpu max, lowered -cpu cortex-a53", list.len(), cases.len());
    let _ = fs::remove_file(&np);
    let _ = fs::remove_file(&lp);
    if bad != 0 || fp16_bad != 0 {
        bail!("{bad} LSE and {fp16_bad} FP16 mismatches");
    }
    Ok(())
}
