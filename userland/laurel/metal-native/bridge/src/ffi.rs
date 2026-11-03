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
    pub color_outputs: u32,
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
    pub fn nmn_program_store(p: *const NmnProgram, size: *mut usize) -> *mut c_void;
    pub fn nmn_program_load(c: *mut NmnCompiler, data: *const c_void, size: usize) -> *mut NmnProgram;
    pub fn nmn_cache_id() -> *const c_char;
    pub fn nmn_program_info(p: *const NmnProgram, stage: u32, out: *mut NmnStageInfo) -> bool;
}

// ---- winsys/nw.h, pm4/nmn_pm4.h ----
#[repr(C)]
pub struct NwDevice(c_void);
#[repr(C)]
pub struct NwOps(c_void);
#[repr(C)]
pub struct NmnGpu(c_void);
#[repr(C)]
pub struct NmnImage(c_void);
#[repr(C)]
pub struct NmnBaked(c_void);
#[repr(C)]
pub struct NwBoOpaque(c_void);

#[repr(C)]
#[derive(Clone, Copy)]
pub struct NwBoHead {
    pub handle: u32,
    pub kind: u32,
    pub iova: u64,
    pub size: u64,
    pub map: *mut c_void,
    pub fence: u32,
    pub list_index: u32,
    pub list_stamp: u32,
    pub extra_refs: u32,
}
pub const NW_BO_POOL: u32 = 0;
pub const NW_BO_SCATTERED: u32 = 1;
pub const NW_BO_SURFACE: u32 = 2;
pub const NW_BO_HOST: u32 = 3;

#[repr(C)]
#[derive(Clone, Copy)]
pub struct NwSlice {
    pub bo: *mut NwBoHead,
    pub offset: u64,
    pub size: u64,
    pub iova: u64,
    pub map: *mut c_void,
    pub slab: *mut c_void,
}
impl NwSlice {
    pub fn empty() -> NwSlice {
        NwSlice { bo: std::ptr::null_mut(), offset: 0, size: 0, iova: 0, map: std::ptr::null_mut(), slab: std::ptr::null_mut() }
    }
}

#[repr(C)]
pub struct NwIb {
    pub iova: u64,
    pub dwords: u32,
    pub bo: *mut NwBoHead,
    pub offset: u32,
}
#[repr(C)]
pub struct NwCs {
    pub dev: *mut NwDevice,
    pub cur: *mut u32,
    pub end: *mut u32,
    pub start: *mut u32,
    pub bo: *mut NwBoHead,
    pub start_iova: u64,
    pub ibs: *mut NwIb,
    pub ib_count: u32,
    pub ib_cap: u32,
    pub chunks: *mut *mut NwBoHead,
    pub chunk_count: u32,
    pub chunk_cap: u32,
    pub failed: bool,
}
#[repr(C)]
pub struct NwSubmit {
    pub dev: *mut NwDevice,
    pub stamp: u32,
    pub names: *mut *mut NwBoHead,
    pub name_count: u32,
    pub name_cap: u32,
    pub streams: *mut *mut NwCs,
    pub stream_count: u32,
    pub stream_cap: u32,
}

#[repr(C)]
pub struct NwInfo {
    pub chip_id: u32,
    pub gmem_size: u32,
    pub highest_bank_bit: u32,
    pub ubwc_swizzle: u32,
    pub macrotile_mode: u32,
    pub max_freq: u64,
    pub va_start: u64,
    pub va_size: u64,
    pub max_buffer: u64,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct NmnColorTarget {
    pub image: *const NmnImage,
    pub pipe_format: u32,
    pub level: u32,
    pub layer: u32,
    pub clear: bool,
    pub clear_value: [f64; 4],
}
#[repr(C)]
pub struct NmnPass {
    pub colors: [NmnColorTarget; 8],
    pub color_count: u32,
    pub depth: *const NmnImage,
    pub clear_depth: bool,
    pub clear_stencil: bool,
    pub clear_z: f64,
    pub clear_s: u32,
    pub width: u32,
    pub height: u32,
    pub samples: u32,
}
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct NmnVertexAttr {
    pub pipe_format: u32,
    pub offset: u32,
    pub binding: u32,
    pub instanced: bool,
    pub step_rate: u32,
    pub is_float: bool,
}
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct NmnBlend {
    pub enable: bool,
    pub src_rgb: u32,
    pub dst_rgb: u32,
    pub op_rgb: u32,
    pub src_a: u32,
    pub dst_a: u32,
    pub op_a: u32,
    pub write_mask: u32,
}
#[repr(C)]
pub struct NmnFixed {
    pub blend: [NmnBlend; 8],
    pub color_count: u32,
    pub samples: u32,
    pub attrs: [NmnVertexAttr; 32],
    pub attr_count: u32,
    pub strides: [u32; 32],
    pub stride_count: u32,
    pub rasterizer_discard: bool,
}
#[repr(C)]
#[derive(Clone, Copy)]
pub struct NmnRaster {
    pub viewport: [f64; 6],
    pub scissor: [u32; 4],
    pub cull_mode: u32,
    pub winding: u32,
    pub fill_mode: u32,
    pub depth_bias: f32,
    pub slope_scale: f32,
    pub bias_clamp: f32,
    pub line_width: f32,
    pub blend_color: [f32; 4],
    pub stencil_front: u32,
    pub stencil_back: u32,
    pub depth_func: u32,
    pub depth_write: bool,
    pub depth_test: bool,
    pub reads_framebuffer: bool,
    pub pass_width: u32,
    pub pass_height: u32,
    pub stencil_enable: bool,
    pub st_func: [u32; 2],
    pub st_fail: [u32; 2],
    pub st_zpass: [u32; 2],
    pub st_zfail: [u32; 2],
    pub st_read: [u32; 2],
    pub st_write: [u32; 2],
}
#[repr(C)]
#[derive(Clone, Copy)]
pub struct NmnSamplerState {
    pub min_filter: u32,
    pub mag_filter: u32,
    pub mip_filter: u32,
    pub s_address: u32,
    pub t_address: u32,
    pub r_address: u32,
    pub border_color: u32,
    pub normalized: u32,
    pub max_anisotropy: u32,
    pub compare: u32,
    pub lod_min: f32,
    pub lod_max: f32,
}

pub const NMN_IMAGE_1D: u32 = 0;
pub const NMN_IMAGE_2D: u32 = 1;
pub const NMN_IMAGE_CUBE: u32 = 2;
pub const NMN_IMAGE_3D: u32 = 3;

pub fn nw_pkt7(opcode: u32, count: u32) -> u32 {
    let odd = |v: u32| {
        let mut x = v ^ (v >> 16);
        x ^= x >> 8;
        x ^= x >> 4;
        (!0x6996u32 >> (x & 0xf)) & 1
    };
    0x7000_0000 | count | (odd(count) << 15) | ((opcode & 0x7f) << 16) | (odd(opcode) << 23)
}

unsafe extern "C" {
    /// The platform's kernel: winsys_iokit.c on the phone, tests/fake_platform.c in a host test.
    pub fn nmn_platform_ops(ctx: *mut *mut c_void, why: *mut c_char, why_size: usize) -> *const NwOps;
    pub fn nw_device_open(ops: *const NwOps, ctx: *mut c_void, why: *mut c_char, why_size: usize) -> *mut NwDevice;
    pub fn nw_device_close(d: *mut NwDevice);
    pub fn nw_device_info(d: *const NwDevice) -> *const NwInfo;
    pub fn nw_slice_new(d: *mut NwDevice, size: u64, alignment: u64, out: *mut NwSlice) -> bool;
    pub fn nw_slice_free(d: *mut NwDevice, s: *mut NwSlice);
    pub fn nw_bo_import_surface(d: *mut NwDevice, id: u32, offset: *mut u32, row_bytes: *mut u32) -> *mut NwBoHead;
    pub fn nw_bo_import_host(d: *mut NwDevice, p: *mut c_void, size: u64, read_only: bool) -> *mut NwBoHead;
    pub fn nw_bo_free(d: *mut NwDevice, b: *mut NwBoHead);
    pub fn nw_cs_init(cs: *mut NwCs, d: *mut NwDevice);
    pub fn nw_cs_finish(cs: *mut NwCs);
    pub fn nw_cs_end_ib(cs: *mut NwCs);
    pub fn nw_reserve_copy(cs: *mut NwCs, words: *const u32, count: u32);
    pub fn nw_cs_append_ibs(cs: *mut NwCs, from: *const NwCs);
    pub fn nw_bo_of_address(d: *mut NwDevice, iova: u64, bytes: u64) -> *mut NwBoHead;
    pub fn nw_last_refusal(d: *const NwDevice) -> *const c_char;
    pub fn nw_check_stats(d: *const NwDevice, out: *mut u64);
    pub fn nw_submit_begin(s: *mut NwSubmit, d: *mut NwDevice);
    pub fn nw_submit_name(s: *mut NwSubmit, b: *mut NwBoHead);
    pub fn nw_submit_stream(s: *mut NwSubmit, cs: *mut NwCs);
    pub fn nw_submit_go(s: *mut NwSubmit, fence: *mut u32) -> i32;
    pub fn nw_submit_end(s: *mut NwSubmit);
    pub fn nw_fence_wait(d: *mut NwDevice, fence: u32, timeout_ns: u64) -> i32;
    pub fn nw_bo_cpu_prep(d: *mut NwDevice, b: *mut NwBoHead) -> i32;

    pub fn nmn_gpu_new(d: *mut NwDevice, why: *mut c_char, why_size: usize) -> *mut NmnGpu;
    pub fn nmn_gpu_free(g: *mut NmnGpu);
    pub fn nmn_format_from_metal(f: u64) -> u32;
    pub fn nmn_format_blocksize(f: u32) -> u32;
    pub fn nmn_format_is_depth_or_stencil(f: u32) -> bool;
    pub fn nmn_image_new(g: *mut NmnGpu, f: u32, t: u32, w: u32, h: u32, d: u32, levels: u32, layers: u32, samples: u32, tiled: bool, stride: u32) -> *mut NmnImage;
    pub fn nmn_image_free(i: *mut NmnImage);
    pub fn nmn_image_size(i: *const NmnImage) -> u64;
    pub fn nmn_image_pitch(i: *const NmnImage, level: u32) -> u32;
    pub fn nmn_image_layer_offset(i: *const NmnImage, level: u32, layer: u32) -> u64;
    pub fn nmn_image_extent(i: *const NmnImage, level: u32, layer: u32) -> u64;
    pub fn nmn_image_bind(i: *mut NmnImage, iova: u64);
    pub fn nmn_image_iova(im: *const NmnImage) -> u64;
    pub fn nmn_descriptor_image(i: *const NmnImage, f: u32, view: u32, base_level: u32, levels: u32, base_layer: u32, layers: u32, swizzle: *const u8, storage: bool, out: *mut u32);
    pub fn nmn_descriptor_buffer_texels(f: u32, iova: u64, bytes: u32, out: *mut u32);
    pub fn nmn_descriptor_ubo(iova: u64, bytes: u64, out: *mut u32);
    pub fn nmn_descriptor_ssbo(iova: u64, bytes: u64, out: *mut u32);
    pub fn nmn_descriptor_sampler(s: *const NmnSamplerState, border: u64, out: *mut u32);
    pub fn nmn_cmd_init(cs: *mut NwCs, g: *mut NmnGpu);
    pub fn nmn_cmd_pass_begin(cs: *mut NwCs, g: *mut NmnGpu, p: *const NmnPass);
    pub fn nmn_cmd_pass_end(cs: *mut NwCs, p: *const NmnPass);
    pub fn nmn_bake_render(g: *mut NmnGpu, vs: *const c_void, fs: *const c_void, f: *const NmnFixed, why: *mut c_char, why_size: usize) -> *mut NmnBaked;
    pub fn nmn_bake_compute(g: *mut NmnGpu, cs: *const c_void, why: *mut c_char, why_size: usize) -> *mut NmnBaked;
    pub fn nmn_baked_free(g: *mut NmnGpu, b: *mut NmnBaked);
    pub fn nmn_cmd_program(cs: *mut NwCs, b: *const NmnBaked);
    pub fn nmn_cmd_raster(cs: *mut NwCs, r: *const NmnRaster);
    pub fn nmn_cmd_descriptor_sets(cs: *mut NwCs, set: *const u64, count: u32, graphics: bool);
    pub fn nmn_cmd_push(cs: *mut NwCs, stage: u32, first_vec4: u32, data: *const c_void, vec4s: u32);
    pub fn nmn_cmd_vertex_buffers(cs: *mut NwCs, iova: *const u64, size: *const u32, stride: *const u32, count: u32);
    pub fn nmn_cmd_draw(cs: *mut NwCs, prim: u32, count: u32, instances: u32, first: u32, first_instance: u32);
    pub fn nmn_cmd_draw_indexed(cs: *mut NwCs, prim: u32, count: u32, instances: u32, index: u64, index_max: u32, wide: bool, base: i32, first_instance: u32);
    pub fn nmn_cmd_dispatch(cs: *mut NwCs, b: *const NmnBaked, groups: *const u32, local: *const u32);
    pub fn nmn_cmd_barrier(cs: *mut NwCs);
    pub fn nmn_cmd_copy_buffer(cs: *mut NwCs, src: u64, dst: u64, bytes: u64);
    pub fn nmn_cmd_fill_buffer(cs: *mut NwCs, dst: u64, bytes: u64, value: u8);
    pub fn nmn_cmd_copy_image(cs: *mut NwCs, src: *const NmnImage, sl: u32, slayer: u32, so: *const u32, dst: *const NmnImage, dl: u32, dlayer: u32, dorigin: *const u32, size: *const u32);
    pub fn nmn_cmd_buffer_to_image(cs: *mut NwCs, src: u64, pitch: u32, dst: *const NmnImage, level: u32, layer: u32, origin: *const u32, size: *const u32);
    pub fn nmn_cmd_image_to_buffer(cs: *mut NwCs, src: *const NmnImage, level: u32, layer: u32, origin: *const u32, size: *const u32, dst: u64, pitch: u32);

    pub fn nmn_cmd_mip_down(cs: *mut NwCs, i: *const NmnImage, level: u32, layer: u32);
    pub fn nmn_program_local_size(p: *const NmnProgram, out: *mut u32);
    pub fn nmn_program_variant(p: *const NmnProgram, stage: u32) -> *const c_void;
    pub fn nmn_program_push_range(p: *const NmnProgram, stage: u32, first_vec4: *mut u32, vec4s: *mut u32, lo_dwords: *mut u32) -> bool;
}
