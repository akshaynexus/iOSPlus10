//! AArch64 decode helpers for the iOS 26 userland work: exact encodings of the instruction classes we rewrite.
//! The census cross-checks each helper against llvm-mc on every unique word (census.rs).
//! Encodings: Arm Architecture Reference Manual for A-profile, C4.1 and C6.2.

pub const NOP: u32 = 0xd503_201f;
pub const RET: u32 = 0xd65f_03c0;

/// A word of the hint space (HINT #imm), with the imm.
pub fn hint_imm(w: u32) -> Option<u32> {
    (w & 0xffff_f01f == 0xd503_201f).then_some((w >> 5) & 0x7f)
}

/// Name of a hint that ARMv8.0 runs as NOP but a newer architecture gives a meaning.
pub fn newer_hint(imm: u32) -> Option<(&'static str, &'static str)> {
    Some(match imm {
        6 => ("dgh", "hint-other"),
        7 => ("xpaclri", "pac-hint"),
        8 => ("pacia1716", "pac-hint"),
        10 => ("pacib1716", "pac-hint"),
        12 => ("autia1716", "pac-hint"),
        14 => ("autib1716", "pac-hint"),
        16 => ("esb", "hint-other"),
        17 => ("psb", "hint-other"),
        18 => ("tsb", "hint-other"),
        20 => ("csdb", "hint-other"),
        22 => ("clrbhb", "hint-other"),
        24 => ("paciaz", "pac-hint"),
        25 => ("paciasp", "pac-hint"),
        26 => ("pacibz", "pac-hint"),
        27 => ("pacibsp", "pac-hint"),
        28 => ("autiaz", "pac-hint"),
        29 => ("autiasp", "pac-hint"),
        30 => ("autibz", "pac-hint"),
        31 => ("autibsp", "pac-hint"),
        32 => ("bti", "bti-hint"),
        34 => ("bti c", "bti-hint"),
        36 => ("bti j", "bti-hint"),
        38 => ("bti jc", "bti-hint"),
        40 => ("chkfeat", "hint-other"),
        _ => return None,
    })
}

/// One FEAT_LSE instruction.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Lse {
    pub op: LseOp,
    /// access size: 0 byte, 1 half, 2 word, 3 double; CASP: 2 = two words, 3 = two doubles
    pub size: u32,
    pub acquire: bool,
    pub release: bool,
    pub rs: u32,
    pub rt: u32,
    pub rn: u32,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum LseOp {
    Cas,
    Casp,
    Swp,
    Add,
    Clr,
    Eor,
    Set,
    Smax,
    Smin,
    Umax,
    Umin,
}

impl LseOp {
    pub fn name(self) -> &'static str {
        match self {
            LseOp::Cas => "cas",
            LseOp::Casp => "casp",
            LseOp::Swp => "swp",
            LseOp::Add => "ldadd",
            LseOp::Clr => "ldclr",
            LseOp::Eor => "ldeor",
            LseOp::Set => "ldset",
            LseOp::Smax => "ldsmax",
            LseOp::Smin => "ldsmin",
            LseOp::Umax => "ldumax",
            LseOp::Umin => "ldumin",
        }
    }
}

pub fn lse_decode(w: u32) -> Option<Lse> {
    let (rs, rn, rt) = ((w >> 16) & 31, (w >> 5) & 31, w & 31);
    let size = w >> 30;
    // CASB, CASH, CAS: size 0010001 A 1 Rs L 11111 Rn Rt
    if w & 0x3fa0_7c00 == 0x08a0_7c00 {
        return Some(Lse { op: LseOp::Cas, size, acquire: w & (1 << 22) != 0, release: w & (1 << 15) != 0, rs, rt, rn });
    }
    // CASP: 0 sz 0010000 A 1 Rs L 11111 Rn Rt; Rs and Rt even
    if w & 0xbfa0_7c00 == 0x0820_7c00 {
        if rs & 1 != 0 || rt & 1 != 0 {
            return None;
        }
        return Some(Lse {
            op: LseOp::Casp,
            size: if w & (1 << 30) != 0 { 3 } else { 2 },
            acquire: w & (1 << 22) != 0,
            release: w & (1 << 15) != 0,
            rs,
            rt,
            rn,
        });
    }
    // Atomic memory operations: size 111000 A R 1 Rs o3 opc 00 Rn Rt
    if w & 0x3f20_0c00 == 0x3820_0000 {
        let op = match (w >> 12) & 15 {
            0 => LseOp::Add,
            1 => LseOp::Clr,
            2 => LseOp::Eor,
            3 => LseOp::Set,
            4 => LseOp::Smax,
            5 => LseOp::Smin,
            6 => LseOp::Umax,
            7 => LseOp::Umin,
            8 => LseOp::Swp,
            _ => return None,
        };
        return Some(Lse { op, size, acquire: w & (1 << 23) != 0, release: w & (1 << 22) != 0, rs, rt, rn });
    }
    None
}

/// LDAPR family (FEAT_LRCPC): the LDAR with the same size and registers. Stronger ordering, same result.
pub fn ldapr_to_ldar(w: u32) -> Option<u32> {
    // size 111000 1 0 1 11111 1 100 00 Rn Rt
    if w & 0x3fff_fc00 == 0x38bf_c000 {
        Some((w & 0xc000_0000) | 0x08df_fc00 | (w & 0x3ff))
    } else {
        None
    }
}

/// LDAPUR/STLUR family (FEAT_LRCPC2): (name, is_load, sign-extending, imm9).
pub fn rcpc2_decode(w: u32) -> Option<(&'static str, bool, bool, i32)> {
    if w & 0x3f20_0c00 != 0x1900_0000 {
        return None;
    }
    let imm = (((w >> 12) & 0x1ff) as i32) << 23 >> 23;
    let (size, opc) = (w >> 30, (w >> 22) & 3);
    let (name, load, sign) = match (size, opc) {
        (0, 0) => ("stlurb", false, false),
        (0, 1) => ("ldapurb", true, false),
        (0, 2) | (0, 3) => ("ldapursb", true, true),
        (1, 0) => ("stlurh", false, false),
        (1, 1) => ("ldapurh", true, false),
        (1, 2) | (1, 3) => ("ldapursh", true, true),
        (2, 0) => ("stlur", false, false),
        (2, 1) => ("ldapur", true, false),
        (2, 2) => ("ldapursw", true, true),
        (3, 0) => ("stlur", false, false),
        (3, 1) => ("ldapur", true, false),
        _ => return None,
    };
    Some((name, load, sign, imm))
}

/// Non-hint FEAT_PAuth instruction: (name, ordinary word that gives the plain-pointer effect).
/// Err: a PAC encoding that has no exact one-word lowering.
/// Same rules as UniXNU-zeta scripts/zeta_userland_pauth.py (BSD-2-Clause-Patent), checked against llvm-mc in the census.
pub fn pac_lower(w: u32) -> Option<Result<(&'static str, u32), &'static str>> {
    const DP1: [&str; 18] = [
        "pacia", "pacib", "pacda", "pacdb", "autia", "autib", "autda", "autdb", "paciza", "pacizb", "pacdza",
        "pacdzb", "autiza", "autizb", "autdza", "autdzb", "xpaci", "xpacd",
    ];
    if w & 0xffff_0000 == 0xdac1_0000 {
        let (opcode, rn) = ((w >> 10) & 0x3f, (w >> 5) & 31);
        if opcode as usize >= DP1.len() {
            return None;
        }
        if opcode >= 8 && rn != 31 {
            return None; // unallocated: not a PAC instruction
        }
        return Some(Ok((DP1[opcode as usize], NOP)));
    }
    if w & 0xffe0_fc00 == 0x9ac0_3000 {
        let rd = w & 31;
        return Some(Ok(("pacga", if rd == 31 { NOP } else { 0xd280_0000 | rd })));
    }
    const BR: [(u32, u32, &str, u32); 8] = [
        (0xd61f_081f, 0xffff_fc1f, "braaz", 0xd61f_0000),
        (0xd61f_0c1f, 0xffff_fc1f, "brabz", 0xd61f_0000),
        (0xd63f_081f, 0xffff_fc1f, "blraaz", 0xd63f_0000),
        (0xd63f_0c1f, 0xffff_fc1f, "blrabz", 0xd63f_0000),
        (0xd71f_0800, 0xffff_fc00, "braa", 0xd61f_0000),
        (0xd71f_0c00, 0xffff_fc00, "brab", 0xd61f_0000),
        (0xd73f_0800, 0xffff_fc00, "blraa", 0xd63f_0000),
        (0xd73f_0c00, 0xffff_fc00, "blrab", 0xd63f_0000),
    ];
    for (value, mask, name, base) in BR {
        if w & mask == value {
            let rn = (w >> 5) & 31;
            if rn == 31 {
                return Some(Err("authenticated branch to register 31"));
            }
            return Some(Ok((name, base | rn << 5)));
        }
    }
    if w == 0xd65f_0bff {
        return Some(Ok(("retaa", RET)));
    }
    if w == 0xd65f_0fff {
        return Some(Ok(("retab", RET)));
    }
    if w == 0xd69f_0bff || w == 0xd69f_0fff {
        return Some(Err("ERETAA/ERETAB cannot run at EL0"));
    }
    if w & 0xff20_0400 == 0xf820_0400 {
        let name = if w & 0x0080_0000 != 0 { "ldrab" } else { "ldraa" };
        let offset = ((w >> 22) & 1) << 9 | ((w >> 12) & 0x1ff);
        let offset = (if offset & 0x200 != 0 { offset as i32 - 1024 } else { offset as i32 }) * 8;
        let (writeback, regs) = ((w >> 11) & 1 != 0, w & 0x3ff);
        if writeback && (-256..=255).contains(&offset) {
            return Some(Ok((name, 0xf840_0c00 | ((offset as u32) & 0x1ff) << 12 | regs)));
        }
        if !writeback && offset >= 0 {
            return Some(Ok((name, 0xf940_0000 | ((offset / 8) as u32) << 10 | regs)));
        }
        if !writeback && offset >= -256 {
            return Some(Ok((name, 0xf840_0000 | ((offset as u32) & 0x1ff) << 12 | regs)));
        }
        return Some(Err("LDRA offset fits no ordinary load"));
    }
    None
}

/// Branch shape for the code walk. `next`: control goes on to the next word. `target`: a static target.
pub fn flow(w: u32, pc: u64) -> (bool, Option<u64>) {
    let imm = |bits: u32, shift: u32| -> i64 { (((w >> shift) as i64) << (64 - bits)) >> (64 - bits) };
    if w & 0xfc00_0000 == 0x1400_0000 {
        return (false, Some(pc.wrapping_add((imm(26, 0) * 4) as u64))); // b
    }
    if w & 0xfc00_0000 == 0x9400_0000 {
        return (true, None); // bl: the callee is another root
    }
    if w & 0xff00_0000 == 0x5400_0000 {
        let target = pc.wrapping_add((imm(19, 5) * 4) as u64);
        return ((w & 15) < 14, Some(target)); // b.cond; b.al / b.nv go only to the target
    }
    if w & 0x7e00_0000 == 0x3400_0000 {
        return (true, Some(pc.wrapping_add((imm(19, 5) * 4) as u64))); // cbz, cbnz
    }
    if w & 0x7e00_0000 == 0x3600_0000 {
        return (true, Some(pc.wrapping_add((imm(14, 5) * 4) as u64))); // tbz, tbnz
    }
    let terminal = w & 0xffff_fc1f == 0xd61f_0000  // br
        || w & 0xffff_fc1f == 0xd65f_0000          // ret
        || w == 0xd65f_0bff || w == 0xd65f_0fff    // retaa, retab
        || w & 0xffff_f800 == 0xd61f_0800          // braa(z), brab(z)
        || w & 0xffff_f800 == 0xd71f_0800
        || w & 0xffe0_001f == 0xd420_0000          // brk
        || w & 0xffe0_001f == 0xd440_0000          // hlt
        || w & 0xffff_0000 == 0;                   // udf
    (!terminal, None)
}

/// Encoders for the few instructions the trampolines use.
pub mod enc {
    pub fn ldxr(size: u32, acq: bool, rt: u32, rn: u32) -> u32 {
        size << 30 | 0x085f_7c00 | (acq as u32) << 15 | rn << 5 | rt
    }
    pub fn stxr(size: u32, rel: bool, rs: u32, rt: u32, rn: u32) -> u32 {
        size << 30 | 0x0800_7c00 | rs << 16 | (rel as u32) << 15 | rn << 5 | rt
    }
    /// sz = 3: x registers, sz = 2: w registers
    pub fn ldxp(sz: u32, acq: bool, rt: u32, rt2: u32, rn: u32) -> u32 {
        0x887f_0000 | (sz & 1) << 30 | (acq as u32) << 15 | rt2 << 10 | rn << 5 | rt
    }
    pub fn stxp(sz: u32, rel: bool, rs: u32, rt: u32, rt2: u32, rn: u32) -> u32 {
        0x8820_0000 | (sz & 1) << 30 | rs << 16 | (rel as u32) << 15 | rt2 << 10 | rn << 5 | rt
    }
    pub const CLREX: u32 = 0xd503_3f5f;
    pub const RET: u32 = 0xd65f_03c0;
    pub fn sub_sp(imm: u32) -> u32 {
        0xd100_03ff | imm << 10
    }
    pub fn add_sp(imm: u32) -> u32 {
        0x9100_03ff | imm << 10
    }
    pub fn stp_sp(a: u32, b: u32, off: u32) -> u32 {
        0xa900_03e0 | (off / 8) << 15 | b << 10 | a
    }
    pub fn ldp_sp(a: u32, b: u32, off: u32) -> u32 {
        0xa940_03e0 | (off / 8) << 15 | b << 10 | a
    }
    pub fn str_sp(a: u32, off: u32) -> u32 {
        0xf900_03e0 | (off / 8) << 10 | a
    }
    pub fn ldr_sp(a: u32, off: u32) -> u32 {
        0xf940_03e0 | (off / 8) << 10 | a
    }
    /// orr Rd, zr, Rm
    pub fn mov(x: bool, d: u32, m: u32) -> u32 {
        (x as u32) << 31 | 0x2a00_03e0 | m << 16 | d
    }
    /// logical / add shifted register, no flags. base: 0x0b000000 add, 0x0a200000 bic, 0x4a000000 eor, 0x2a000000 orr
    pub fn reg3(base: u32, x: bool, d: u32, n: u32, m: u32) -> u32 {
        (x as u32) << 31 | base | m << 16 | n << 5 | d
    }
    pub fn cbnz_w(rt: u32, words: i32) -> u32 {
        0x3500_0000 | ((words as u32) & 0x7ffff) << 5 | rt
    }
    pub fn cbnz(x: bool, rt: u32, words: i32) -> u32 {
        (x as u32) << 31 | 0x3500_0000 | ((words as u32) & 0x7ffff) << 5 | rt
    }
    pub fn b_words(words: i32) -> u32 {
        0x1400_0000 | ((words as u32) & 0x3ff_ffff)
    }
    pub fn bl_words(words: i32) -> u32 {
        0x9400_0000 | ((words as u32) & 0x3ff_ffff)
    }
    /// and Wd, Wn, #0xff / #0xffff: bits = 8 or 16
    pub fn and_low(d: u32, n: u32, bits: u32) -> u32 {
        0x1200_0000 | (bits - 1) << 10 | n << 5 | d
    }
    pub fn mrs_nzcv(t: u32) -> u32 {
        0xd53b_4200 | t
    }
    pub fn msr_nzcv(t: u32) -> u32 {
        0xd51b_4200 | t
    }
    /// subs zr, Rn, Rm
    pub fn cmp(x: bool, n: u32, m: u32) -> u32 {
        (x as u32) << 31 | 0x6b00_001f | m << 16 | n << 5
    }
    /// csel Rd, Rn, Rm, cond
    pub fn csel(x: bool, d: u32, n: u32, m: u32, cond: u32) -> u32 {
        (x as u32) << 31 | 0x1a80_0000 | m << 16 | cond << 12 | n << 5 | d
    }
    /// stp Qa, Qb, [sp, #off] / ldp (SIMD&FP, 128-bit, signed offset in units of 16)
    pub fn stp_q_sp(a: u32, b: u32, off: u32) -> u32 {
        0xad00_03e0 | (off / 16) << 15 | b << 10 | a
    }
    pub fn ldp_q_sp(a: u32, b: u32, off: u32) -> u32 {
        0xad40_03e0 | (off / 16) << 15 | b << 10 | a
    }
    /// stp x16, x17, [sp, #32] / ldp: the integer scratch of the FP16 trampoline, in the frame's third 16 bytes
    pub fn stp_x16_x17() -> u32 {
        0xa902_47f0
    }
    pub fn ldp_x16_x17() -> u32 {
        0xa942_47f0
    }
    pub fn mrs_fpcr(t: u32) -> u32 {
        0xd53b_4400 | t
    }
    pub fn msr_fpcr(t: u32) -> u32 {
        0xd51b_4400 | t
    }
    /// tbz Wt, #bit, +words (bit < 32)
    pub fn tbz_w(t: u32, bit: u32, words: i32) -> u32 {
        0x3600_0000 | bit << 19 | ((words as u32) & 0x3fff) << 5 | t
    }
    /// movz Wd, #imm16
    pub fn movz_w(d: u32, imm16: u32) -> u32 {
        0x5280_0000 | imm16 << 5 | d
    }
    /// fmov Sd, Wn
    pub fn fmov_s_w(d: u32, n: u32) -> u32 {
        0x1e27_0000 | n << 5 | d
    }
    /// and x16, x17, #0xfffffffffbffffff: FPCR without AHP
    pub const AND_X16_X17_NO_AHP: u32 = 0x9265_fa30;
    /// fcvt Sd, Hn (half to single)
    pub fn fcvt_s_h(d: u32, n: u32) -> u32 {
        0x1ee2_4000 | n << 5 | d
    }
    /// fcmp / fcmpe Sn, Sm or Sn, #0.0
    pub fn fcmp_s(n: u32, m: u32, zero: bool, signal: bool) -> u32 {
        0x1e20_2000 | m << 16 | n << 5 | (zero as u32) << 3 | (signal as u32) << 4
    }
    pub fn sxt(x: bool, d: u32, n: u32, bits: u32) -> u32 {
        // sbfm Rd, Rn, #0, #bits-1
        (x as u32) << 31 | (x as u32) << 22 | 0x1300_0000 | (bits - 1) << 10 | n << 5 | d
    }
}

/// The word a site gets when x30 is not dead there and the x30 stub after it.
pub const TRAMP_FRAME: u32 = 176; // 128-byte Darwin red zone + 48 bytes of spill slots, 16-byte aligned

/// Why an LSE word stays for the kernel: registers the trampoline scheme cannot serve.
pub fn lse_refuses(l: &Lse) -> Option<&'static str> {
    if l.rn == 31 {
        return Some("base register is SP");
    }
    let pair = l.op == LseOp::Casp;
    let regs = [l.rs, l.rt, l.rn];
    if regs.iter().any(|&r| r == 30) || (pair && (l.rs + 1 == 30 || l.rt + 1 == 30)) {
        return Some("uses x30");
    }
    None
}

/// Code of one trampoline. Entered with `bl`, returns with `ret`. Keeps every register except x30 and the results the
/// instruction defines, keeps NZCV and SP. Position independent: the only branches are inside it.
/// Atomic against other CPUs: an LL/SC loop on the same address, so it mixes with any other LL/SC code.
/// Ordering: acquire -> LDAXR, release -> STLXR, same as the instruction's A and L bits.
pub fn lse_trampoline(l: &Lse) -> Vec<u32> {
    use enc::*;
    let pair = l.op == LseOp::Casp;
    let mut busy = vec![l.rs, l.rt, l.rn];
    if pair {
        busy.push(l.rs + 1);
        busy.push(l.rt + 1);
    }
    let mut free = (9..=17).filter(|r| !busy.contains(r));
    let (s0, s1, s2, s3) = (free.next().unwrap(), free.next().unwrap(), free.next().unwrap(), free.next().unwrap());
    let x = l.size == 3;
    let (a, r, n) = (l.acquire, l.release, l.rn);
    let sized = l.size; // load/store size field
    let minmax = matches!(l.op, LseOp::Smax | LseOp::Smin | LseOp::Umax | LseOp::Umin);
    let mut c = vec![sub_sp(TRAMP_FRAME), stp_sp(s0, s1, 0), stp_sp(s2, s3, 16)];
    if minmax {
        c.push(mrs_nzcv(s3));
    }
    match l.op {
        LseOp::Cas => {
            // L: ldxr s0; eor s1; (and); cbnz s1,F; stxr s1; cbnz s1,L; b D; F: clrex; D:
            let mask = l.size < 2;
            c.push(ldxr(sized, a, s0, n));
            c.push(reg3(0x4a00_0000, x, s1, s0, l.rs));
            if mask {
                c.push(and_low(s1, s1, 8 << l.size));
            }
            c.push(cbnz(x, s1, 4));
            c.push(stxr(sized, r, s1, l.rt, n));
            c.push(cbnz_w(s1, if mask { -5 } else { -4 }));
            c.push(b_words(2));
            c.push(CLREX);
            if l.rs != 31 {
                c.push(mov(x, l.rs, s0));
            }
        }
        LseOp::Casp => {
            // L: ldxp; eor; cbnz F; eor; cbnz F; stxp; cbnz L; b D; F: stxp s2,s0,s1 (write back: pair is atomic only then); cbnz L; D:
            let dx = l.size == 3;
            c.push(ldxp(l.size, a, s0, s1, n));
            c.push(reg3(0x4a00_0000, dx, s2, s0, l.rs));
            c.push(cbnz(dx, s2, 6));
            c.push(reg3(0x4a00_0000, dx, s2, s1, l.rs + 1));
            c.push(cbnz(dx, s2, 4));
            c.push(stxp(l.size, r, s2, l.rt, l.rt + 1, n));
            c.push(cbnz_w(s2, -6));
            c.push(b_words(3));
            c.push(stxp(l.size, false, s2, s0, s1, n));
            c.push(cbnz_w(s2, -9));
            c.push(mov(dx, l.rs, s0));
            c.push(mov(dx, l.rs + 1, s1));
        }
        LseOp::Swp => {
            c.push(ldxr(sized, a, s0, n));
            c.push(stxr(sized, r, s1, l.rs, n));
            c.push(cbnz_w(s1, -2));
            if l.rt != 31 {
                c.push(mov(x, l.rt, s0));
            }
        }
        LseOp::Add | LseOp::Clr | LseOp::Eor | LseOp::Set => {
            let base = match l.op {
                LseOp::Add => 0x0b00_0000,
                LseOp::Clr => 0x0a20_0000,
                LseOp::Eor => 0x4a00_0000,
                _ => 0x2a00_0000,
            };
            c.push(ldxr(sized, a, s0, n));
            c.push(reg3(base, x, s2, s0, l.rs));
            c.push(stxr(sized, r, s1, s2, n));
            c.push(cbnz_w(s1, -3));
            if l.rt != 31 {
                c.push(mov(x, l.rt, s0));
            }
        }
        LseOp::Smax | LseOp::Smin | LseOp::Umax | LseOp::Umin => {
            // Compare at the access size. Byte and half compare sign- or zero-extended copies; flags restored after.
            let signed = matches!(l.op, LseOp::Smax | LseOp::Smin);
            // ge/lt for signed, hs/lo for unsigned; keep memory when the condition holds
            let keep_mem = match l.op {
                LseOp::Smax => 10, // ge
                LseOp::Smin => 11, // lt
                LseOp::Umax => 2,  // hs
                _ => 3,            // lo
            };
            // s4 for the extended Rs: push and pop around the loop in the frame
            let s4 = (9..=17).filter(|r| !busy.contains(r)).nth(4).unwrap();
            c.push(str_sp(s4, 32));
            if l.size < 2 {
                let b = 8u32 << l.size;
                c.push(if signed { sxt(false, s4, l.rs, b) } else { and_low(s4, l.rs, b) });
            } else {
                c.push(mov(x, s4, l.rs));
            }
            let start = c.len();
            c.push(ldxr(sized, a, s0, n));
            if l.size < 2 && signed {
                let b = 8u32 << l.size;
                // compare the sign-extended value, keep s0 zero-extended for the result
                c.push(sxt(false, s2, s0, b));
                c.push(cmp(false, s2, s4));
                c.push(csel(false, s2, s0, s4, keep_mem));
            } else {
                c.push(cmp(x, s0, s4));
                c.push(csel(x, s2, s0, s4, keep_mem));
            }
            c.push(stxr(sized, r, s1, s2, n));
            let back = start as i32 - c.len() as i32;
            c.push(cbnz_w(s1, back));
            if l.rt != 31 {
                c.push(mov(x, l.rt, s0));
            }
            c.push(msr_nzcv(s3));
            c.push(ldr_sp(s4, 32));
        }
    }
    c.push(ldp_sp(s2, s3, 16));
    c.push(ldp_sp(s0, s1, 0));
    c.push(add_sp(TRAMP_FRAME));
    c.push(RET);
    c
}

/// One FEAT_FP16 scalar compare: `fcmp`/`fcmpe Hn, Hm` or `Hn, #0.0`. The hottest emulated words of the Mi A3 (laurel 3070, 2026-11-07:
/// 503,357 + 122,403 traps a minute in one CoreGraphics half-float blend loop, 17 M in the minute that rebuilds the icon cache).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Fp16Cmp {
    /// fcmpe: a quiet NaN also signals
    pub signal: bool,
    /// compare with +0.0 (Rm field is 0)
    pub zero: bool,
    pub rn: u32,
    pub rm: u32,
}

/// Encoding (C7.2.70): 0 0 0 11110 ptype=11 1 Rm op=00 1000 Rn opcode2; opcode2: 00000 fcmp, 01000 fcmp #0.0, 10000 fcmpe, 11000 fcmpe #0.0.
pub fn fp16cmp_decode(w: u32) -> Option<Fp16Cmp> {
    if w & 0xffe0_fc07 != 0x1ee0_2000 {
        return None;
    }
    let (opc, rm, rn) = (w & 0x1f, (w >> 16) & 31, (w >> 5) & 31);
    let zero = opc & 8 != 0;
    if zero && rm != 0 {
        return None;
    }
    Some(Fp16Cmp { signal: opc & 16 != 0, zero, rn, rm })
}

/// The half compare as a single compare: `fcvt s, h` is exact (every half value is a single value; a signaling NaN gives Invalid and a
/// quiet NaN, as the half compare itself would), so NZCV and the cumulative FPSR flags come out the same. FPCR bits: FZ16 is RES0 on a
/// CPU without FEAT_FP16 (the Kryo 260, cortex-a53), so no program here ever runs with it; AHP (bit 26) changes how a conversion reads
/// a half (no infinity or NaN in the alternative format) but not the compare, so when it is set the trampoline clears it around the
/// conversions and puts it back (the qemu self-test runs both). Two Q and two X registers are spilled in the trampoline frame; NZCV is
/// the result. Entered with `bl`, returns with `ret`: same frame, same stub as the LSE trampolines (TRAMP_FRAME, lse_stub).
pub fn fp16cmp_trampoline(c: &Fp16Cmp) -> Vec<u32> {
    use enc::*;
    let mut free = (16..=19u32).filter(|&r| r != c.rn && r != c.rm);
    let (s0, s1) = (free.next().unwrap(), free.next().unwrap());
    let mut v = vec![sub_sp(TRAMP_FRAME), stp_q_sp(s0, s1, 0), stp_x16_x17(), mrs_fpcr(17), tbz_w(17, 26, 3), AND_X16_X17_NO_AHP, msr_fpcr(16), fcvt_s_h(s0, c.rn)];
    if c.zero {
        v.push(fcmp_s(s0, 0, true, c.signal));
    } else {
        v.push(fcvt_s_h(s1, c.rm));
        v.push(fcmp_s(s0, s1, false, c.signal));
    }
    v.push(tbz_w(17, 26, 2));
    v.push(msr_fpcr(17));
    v.push(ldp_x16_x17());
    v.push(ldp_q_sp(s0, s1, 0));
    v.push(add_sp(TRAMP_FRAME));
    v.push(RET);
    v
}

/// `fmov Hd, #imm8` (C7.2.141, type 11): the second FP16 site of the Mi A3 after the compares (QuartzCore+0x4daa4, `fmov h1, #1.0`,
/// 25,000-66,000 a minute in backboardd's frame path, 2026-11-07 19:08). The half value is VFPExpandImm(imm8, 16).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Fp16Mov {
    pub rd: u32,
    pub half: u16,
}

pub fn fp16mov_decode(w: u32) -> Option<Fp16Mov> {
    if w & 0xffe0_1fe0 != 0x1ee0_1000 {
        return None;
    }
    let imm8 = (w >> 13) & 0xff;
    let (sign, b6, b54, frac) = (imm8 >> 7, (imm8 >> 6) & 1, (imm8 >> 4) & 3, imm8 & 15);
    let exp = (b6 ^ 1) << 4 | b6 << 3 | b6 << 2 | b54;
    Some(Fp16Mov { rd: w & 31, half: (sign << 15 | exp << 10 | frac << 6) as u16 })
}

/// `movz w16, #half; fmov Sd, w16`: FMOV (scalar, immediate) clears the other bits of the vector register, FMOV Sd, Wn does the same
/// (the half sits in bits 15:0, bits 31:16 are zero). No flag changes. x16 is spilled in the trampoline frame.
pub fn fp16mov_trampoline(m: &Fp16Mov) -> Vec<u32> {
    use enc::*;
    vec![sub_sp(TRAMP_FRAME), str_sp(16, 0), movz_w(16, m.half as u32), fmov_s_w(m.rd, 16), ldr_sp(16, 0), add_sp(TRAMP_FRAME), RET]
}

/// An FP16 word the lowering serves: a compare or an immediate move.
pub fn fp16_lowerable(w: u32) -> bool {
    fp16cmp_decode(w).is_some() || fp16mov_decode(w).is_some()
}

/// The trampoline of one word the lowering serves through a trampoline: an LSE word, an FP16 compare or an FP16 immediate move.
pub fn trampoline_for(w: u32) -> Option<Vec<u32>> {
    if let Some(l) = lse_decode(w) {
        return Some(lse_trampoline(&l));
    }
    if let Some(c) = fp16cmp_decode(w) {
        return Some(fp16cmp_trampoline(&c));
    }
    fp16mov_decode(w).map(|m| fp16mov_trampoline(&m))
}

/// Per-site stub when x30 is live: save x30 below the red zone, call the shared trampoline, restore, go back.
/// `tramp_words`: distance from this stub's second word to the trampoline; `back_words`: from the stub's last word to the
/// word after the site.
pub fn lse_stub(tramp_words: i32, back_words: i32) -> [u32; 4] {
    [
        0xf817_0ffe, // str x30, [sp, #-144]! (below the red zone)
        enc::bl_words(tramp_words),
        0xf849_07fe, // ldr x30, [sp], #144
        enc::b_words(back_words),
    ]
}

/// One-word rewrites that need no trampoline. Err: this word stays for the kernel, with the reason.
pub fn one_word(w: u32, rules: &Rules) -> Option<Result<(&'static str, u32), &'static str>> {
    if rules.pac {
        if let Some(r) = pac_lower(w) {
            return Some(r);
        }
    }
    if rules.rcpc {
        if let Some(n) = ldapr_to_ldar(w) {
            return Some(Ok(("ldapr", n)));
        }
        if let Some((name, load, sign, imm)) = rcpc2_decode(w) {
            if imm == 0 && !sign {
                let (rn, rt) = ((w >> 5) & 31, w & 31);
                let new = (w & 0xc000_0000) | if load { 0x08df_fc00 } else { 0x089f_fc00 } | rn << 5 | rt;
                return Some(Ok((name, new)));
            }
            return Some(Err("LDAPUR/STLUR with offset or sign extension"));
        }
    }
    if rules.sysreg {
        // msr DIT, #imm: 0xd503415f / 0xd503405f. No DIT on v8.0: data timing does not depend on data here [I], NOP.
        if w == 0xd503_415f || w == 0xd503_405f {
            return Some(Ok(("msr-dit-imm", NOP)));
        }
        // mrs xN, DIT reads 0.
        if w & 0xffff_ffe0 == 0xd53b_42a0 {
            return Some(Ok(("mrs-dit", 0xd280_0000 | (w & 31))));
        }
        // msr DIT, xN: ignore
        if w & 0xffff_ffe0 == 0xd51b_42a0 {
            return Some(Ok(("msr-dit-reg", NOP)));
        }
        // sb -> isb: a stronger speculation stop on these CPUs [I]
        if w == 0xd503_30ff {
            return Some(Ok(("sb", 0xd503_3fdf)));
        }
    }
    None
}

/// objc_msgSend hit path of 23F84: `b.ne next; eor x10,x10,x1; eor x10,x10,x16; brab x17,x10` (or `autib x17,x10`).
pub const OBJC_EOR_SEL: u32 = 0xca01_014a;
pub const OBJC_EOR_CLS: u32 = 0xca10_014a;

/// The method cache of libobjc: `cache_t::insert` writes a free bucket with `stp imp, sel` and objc_msgSend reads it with `ldp imp, sel`, no lock.
/// Apple relies on LDP/STP being one atomic access; ARMv8.0 gives that only per 64-bit word. So on this CPU a reader can see the new sel with imp 0: `br x17` to 0.
/// The two `eor` only make the PAC modifier of `brab`/`autib`, and PAC is gone here: they become `cbz x17, miss; nop`, where miss is the target of the `cbz x9` of the
/// next probe. Same address, inside the restartable range, no new memory access. `words[i]` must be the first eor. Returns the new first word.
pub fn objc_bucket_race(words: &[u32], i: usize) -> Option<u32> {
    if i == 0 || words.get(i).copied()? != OBJC_EOR_SEL || words.get(i + 1).copied()? != OBJC_EOR_CLS {
        return None;
    }
    let imm19 = |w: u32| (((w >> 5) & 0x7_ffff) as i32) << 13 >> 13;
    let bne = words[i - 1];
    if bne & 0xff00_001f != 0x5400_0001 {
        return None; // not b.ne
    }
    let next = (i - 1) as i64 + imm19(bne) as i64;
    let cbz = *words.get(usize::try_from(next).ok()?)?;
    if cbz & 0xff00_001f != 0xb400_0009 {
        return None; // not cbz x9
    }
    let off = next + imm19(cbz) as i64 - i as i64;
    if !(-(1 << 18)..(1 << 18)).contains(&off) {
        return None;
    }
    Some(0xb400_0000 | (((off as u32) & 0x7_ffff) << 5) | 17)
}

/// Rule set of `a64-lower`.
#[derive(Clone, Copy, Debug)]
pub struct Rules {
    pub pac: bool,
    pub rcpc: bool,
    pub lse: bool,
    pub sysreg: bool,
    pub slide: bool,
    /// FP16 `fcmp`/`fcmpe` through a trampoline (kill switch of the root build: A64_FP16=0 in scripts/ios26/lower-userland.sh)
    pub fp16: bool,
}
impl Rules {
    pub fn parse(s: &str) -> Result<Rules, String> {
        let mut r = Rules { pac: false, rcpc: false, lse: false, sysreg: false, slide: false, fp16: false };
        for t in s.split(',') {
            match t {
                "all" => r = Rules { pac: true, rcpc: true, lse: true, sysreg: true, slide: true, fp16: true },
                "pac" => r.pac = true,
                "rcpc" => r.rcpc = true,
                "lse" => r.lse = true,
                "sysreg" => r.sysreg = true,
                "slide" => r.slide = true,
                "fp16" => r.fp16 = true,
                o => return Err(format!("unknown rule {o} (all, pac, rcpc, lse, sysreg, slide, fp16)")),
            }
        }
        Ok(r)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lse_forms() {
        // casal w0, w1, [x2]: llvm-mc -show-encoding
        let c = lse_decode(0x88e0_fc41).unwrap();
        assert_eq!((c.op, c.size, c.acquire, c.release, c.rs, c.rt, c.rn), (LseOp::Cas, 2, true, true, 0, 1, 2));
        // ldaddal x0, x1, [x2]
        let c = lse_decode(0xf8e0_0041).unwrap();
        assert_eq!((c.op, c.size, c.acquire, c.release), (LseOp::Add, 3, true, true));
        // swpb w0, w1, [x2]
        let c = lse_decode(0x3820_8041).unwrap();
        assert_eq!((c.op, c.size), (LseOp::Swp, 0));
        // casp x0, x1, x2, x3, [x4]
        let c = lse_decode(0x4820_7c82).unwrap();
        assert_eq!((c.op, c.size, c.rs, c.rt, c.rn), (LseOp::Casp, 3, 0, 2, 4));
        // ldapr w0, [x1] is not LSE
        assert!(lse_decode(0xb8bf_c020).is_none());
        // ldxr, stxr, ldar are not LSE
        for w in [0xc85f_7c20u32, 0xc800_7c20, 0x88df_fc20, 0xc8df_fc20] {
            assert!(lse_decode(w).is_none(), "{w:#x}");
        }
    }

    #[test]
    fn fp16cmp_forms() {
        // the Mi A3 sites: fcmp h2, h0 / fcmp h2, #0.0 (CoreGraphics), fcmp h0, h1 (QuartzCore)
        assert_eq!(fp16cmp_decode(0x1ee0_2040), Some(Fp16Cmp { signal: false, zero: false, rn: 2, rm: 0 }));
        assert_eq!(fp16cmp_decode(0x1ee0_2048), Some(Fp16Cmp { signal: false, zero: true, rn: 2, rm: 0 }));
        assert_eq!(fp16cmp_decode(0x1ee1_2000), Some(Fp16Cmp { signal: false, zero: false, rn: 0, rm: 1 }));
        assert_eq!(fp16cmp_decode(0x1ee1_2010), Some(Fp16Cmp { signal: true, zero: false, rn: 0, rm: 1 })); // fcmpe h0, h1
        assert_eq!(fp16cmp_decode(0x1ee0_2018), Some(Fp16Cmp { signal: true, zero: true, rn: 0, rm: 0 })); // fcmpe h0, #0.0
        assert!(fp16cmp_decode(0x1ee1_2008).is_none()); // #0.0 form with Rm != 0: not an encoding
        assert!(fp16cmp_decode(0x1e20_2040).is_none()); // fcmp s2, s0 is ARMv8.0
        assert!(fp16cmp_decode(0x1e60_2040).is_none()); // fcmp d2, d0
        assert!(fp16cmp_decode(0x1ee0_2041).is_none()); // opcode2 bit 0 set: no such form
        // trampoline: scratch registers avoid the operands
        let t = fp16cmp_trampoline(&fp16cmp_decode(0x1ef1_2200).unwrap()); // fcmp h16, h17 (llvm-mc: 0x1ef12200)
        assert_eq!(&t[..4], &[enc::sub_sp(TRAMP_FRAME), enc::stp_q_sp(18, 19, 0), enc::stp_x16_x17(), enc::mrs_fpcr(17)]);
        assert_eq!(&t[7..10], &[enc::fcvt_s_h(18, 16), enc::fcvt_s_h(19, 17), enc::fcmp_s(18, 19, false, false)]);
        assert_eq!(&t[12..], &[enc::ldp_x16_x17(), enc::ldp_q_sp(18, 19, 0), enc::add_sp(TRAMP_FRAME), RET]);
        assert_eq!(fp16cmp_trampoline(&fp16cmp_decode(0x1ee0_2048).unwrap()).len(), 15); // the #0.0 form converts one operand
        // llvm-mc: tbz w17, #26, #16 = 0x36d00091; and x16, x17, #0xfffffffffbffffff = 0x927ff630; msr fpcr, x16 = 0xd51b4410
        assert_eq!(enc::tbz_w(17, 26, 4), 0x36d0_0091);
        assert_eq!(enc::msr_fpcr(16), 0xd51b_4410);
        // llvm-mc encodings: stp q16, q17, [sp] = 0xad0047f0; fcvt s16, h2 = 0x1ee24050; fcmp s16, s17 = 0x1e312200; fcmpe s16, #0.0 = 0x1e202218
        assert_eq!(enc::stp_q_sp(16, 17, 0), 0xad00_47f0);
        assert_eq!(enc::ldp_q_sp(16, 17, 0), 0xad40_47f0);
        assert_eq!(enc::fcvt_s_h(16, 2), 0x1ee2_4050);
        assert_eq!(enc::fcmp_s(16, 17, false, false), 0x1e31_2200);
        assert_eq!(enc::fcmp_s(16, 0, true, true), 0x1e20_2218);
        assert!(trampoline_for(0x1ee0_2040).is_some() && trampoline_for(0x88e0_fc41).is_some() && trampoline_for(NOP).is_none());
    }

    #[test]
    fn fp16mov_forms() {
        // llvm-mc: fmov h1, #1.0 = 0x1eee1001; fmov h0, #0.5 = 0x1eec1000; fmov h31, #-2.0 = 0x1ef0101f
        assert_eq!(fp16mov_decode(0x1eee_1001), Some(Fp16Mov { rd: 1, half: 0x3c00 }));
        assert_eq!(fp16mov_decode(0x1eec_1000), Some(Fp16Mov { rd: 0, half: 0x3800 }));
        assert_eq!(fp16mov_decode(0x1ef0_101f), Some(Fp16Mov { rd: 31, half: 0xc000 }));
        assert!(fp16mov_decode(0x1e2e_1001).is_none()); // fmov s1, #1.0 is ARMv8.0
        assert!(fp16mov_decode(0x1eee_1021).is_none()); // bits 9:5 must be zero
        // llvm-mc: movz w16, #0x3c00 = 0x52878010; fmov s1, w16 = 0x1e270201; str x16, [sp] = 0xf90003f0
        assert_eq!(fp16mov_trampoline(&Fp16Mov { rd: 1, half: 0x3c00 }), vec![enc::sub_sp(TRAMP_FRAME), 0xf900_03f0, 0x5287_8010, 0x1e27_0201, 0xf940_03f0, enc::add_sp(TRAMP_FRAME), RET]);
        assert!(fp16_lowerable(0x1eee_1001) && fp16_lowerable(0x1ee0_2040) && !fp16_lowerable(NOP));
    }

    #[test]
    fn ldapr() {
        assert_eq!(ldapr_to_ldar(0xb8bf_c020), Some(0x88df_fc20)); // ldapr w0,[x1] -> ldar w0,[x1]
        assert_eq!(ldapr_to_ldar(0xf8bf_c020), Some(0xc8df_fc20)); // ldapr x0,[x1] -> ldar x0,[x1]
        assert_eq!(ldapr_to_ldar(0x38bf_c020), Some(0x08df_fc20)); // ldaprb
        assert_eq!(ldapr_to_ldar(0x88df_fc20), None);
    }

    #[test]
    fn pac() {
        assert_eq!(pac_lower(0xd65f_0fff).unwrap().unwrap(), ("retab", RET));
        assert_eq!(pac_lower(0xd71f_0a11).unwrap().unwrap(), ("braa", 0xd61f_0200)); // braa x16, x17 -> br x16
        assert_eq!(pac_lower(0xd63f_0a1f).unwrap().unwrap(), ("blraaz", 0xd63f_0200)); // blraaz x16 -> blr x16
        assert_eq!(pac_lower(0xdac1_0c11).unwrap().unwrap().1, NOP); // pacdb x17, x0
        assert_eq!(pac_lower(0xdac1_47f1).unwrap().unwrap().1, NOP); // xpacd x17
        assert_eq!(pac_lower(0x9ac0_3020).unwrap().unwrap().1, 0xd280_0000); // pacga x0, x1, x0 -> movz x0,#0
        assert_eq!(pac_lower(0xf820_0401).unwrap().unwrap().1, 0xf940_0001); // ldraa x1,[x0] -> ldr x1,[x0]
        assert!(pac_lower(0xaa00_03e0).is_none());
    }

    #[test]
    fn hints() {
        assert_eq!(hint_imm(0xd503_237f), Some(27));
        assert_eq!(newer_hint(27).unwrap().0, "pacibsp");
        assert_eq!(hint_imm(NOP), Some(0));
        assert!(newer_hint(0).is_none());
    }

    #[test]
    fn objc_race() {
        // 23F84 objc_msgSend at 0x18009b440: b.ne +16; eor; eor; brab x17, x10; cbz x9, 0x18009b8a0
        let w = [0x5400_0081, OBJC_EOR_SEL, OBJC_EOR_CLS, 0xd71f_0e2a, 0xb400_2289];
        let new = objc_bucket_race(&w, 1).unwrap();
        // cbz x17, 0x18009b8a0 from 0x18009b444: +0x45c
        assert_eq!(new, 0xb400_0000 | ((0x45c / 4) << 5) | 17);
        assert!(objc_bucket_race(&w, 0).is_none());
        let other = [0x5400_0081, OBJC_EOR_SEL, 0xca10_014b, 0xd71f_0e2a, 0xb400_2289];
        assert!(objc_bucket_race(&other, 1).is_none());
        let not_cbz = [0x5400_0081, OBJC_EOR_SEL, OBJC_EOR_CLS, 0xd71f_0e2a, 0xb400_2288];
        assert!(objc_bucket_race(&not_cbz, 1).is_none());
    }

    #[test]
    fn walk_shapes() {
        assert_eq!(flow(0x1400_0002, 0x1000), (false, Some(0x1008))); // b .+8
        assert_eq!(flow(0x9400_0002, 0x1000), (true, None)); // bl
        assert_eq!(flow(0x5400_0040, 0x1000), (true, Some(0x1008))); // b.eq .+8
        assert_eq!(flow(RET, 0x1000), (false, None));
        assert_eq!(flow(0xd503_201f, 0x1000), (true, None));
        assert_eq!(flow(0xb400_0040, 0x1000), (true, Some(0x1008))); // cbz x0, .+8
        assert_eq!(flow(0x3607_ffe0, 0x1000), (true, Some(0x0ffc))); // tbz w0, #0, .-4
    }
}
