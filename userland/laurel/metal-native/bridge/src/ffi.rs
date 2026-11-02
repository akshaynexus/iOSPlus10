// SPDX-License-Identifier: MIT
//! shader/nmn_shader.h
use std::ffi::{c_char, c_void};

pub const NMN_DESC_SAMPLER: u32 = 0;
pub const NMN_DESC_COMBINED: u32 = 1;
pub const NMN_DESC_IMAGE: u32 = 2;
pub const NMN_DESC_UBO: u32 = 3;
pub const NMN_DESC_SSBO: u32 = 4;

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct NmnBinding {
    pub set: u32,
    pub binding: u32,
    pub kind: u32,
    pub offset: u32,
    pub stride: u32,
    pub count: u32,
}

#[repr(C)]
pub struct NmnLayout {
    pub bindings: *const NmnBinding,
    pub binding_count: u32,
    pub push_bytes: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct NmnSpec {
    pub id: u32,
    pub value: u32,
}

#[repr(C)]
pub struct NmnStageInput {
    pub stage: u32,
    pub spirv: *const u32,
    pub words: usize,
    pub entry: *const c_char,
    pub spec: *const NmnSpec,
    pub spec_count: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct NmnStageInfo {
    pub instructions: u32,
    pub nops: u32,
    pub movs: u32,
    pub covs: u32,
    pub sizedwords: u32,
    pub half_regs: u32,
    pub full_regs: u32,
    pub const_vec4: u32,
    pub tex_ops: u32,
    pub mem_ops: u32,
    pub sstall: u32,
    pub systall: u32,
    pub loops: u32,
    pub instrlen: u32,
    pub reads_framebuffer: bool,
    pub has_kill: bool,
    pub writes_z: bool,
    pub needs_full_quad: bool,
}

#[repr(C)]
pub struct NmnCompiler(c_void);
#[repr(C)]
pub struct NmnProgram(c_void);

unsafe extern "C" {
    pub fn nmn_compiler_new(chip_id: u32, why: *mut c_char, why_size: usize) -> *mut NmnCompiler;
    pub fn nmn_compiler_free(c: *mut NmnCompiler);
    pub fn nmn_compiler_gpu_name(c: *const NmnCompiler) -> *const c_char;
    pub fn nmn_program_render(c: *mut NmnCompiler, layout: *const NmnLayout, vertex: *const NmnStageInput, fragment: *const NmnStageInput, why: *mut c_char, why_size: usize) -> *mut NmnProgram;
    pub fn nmn_program_compute(c: *mut NmnCompiler, layout: *const NmnLayout, kernel: *const NmnStageInput, x: u32, y: u32, z: u32, why: *mut c_char, why_size: usize) -> *mut NmnProgram;
    pub fn nmn_program_free(p: *mut NmnProgram);
    pub fn nmn_program_info(p: *const NmnProgram, stage: u32, out: *mut NmnStageInfo) -> bool;
}
