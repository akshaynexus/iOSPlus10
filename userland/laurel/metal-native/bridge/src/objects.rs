// SPDX-License-Identifier: MIT
//! The objects behind bridge/NativeMetalObjects.h. Helpers and descriptor conversion: as NativeMetalObjects.rs (ios-flame, MIT).
use crate::compile::{Program, compute_program, render_program};
use crate::ffi::*;
use metal2vulkan::Budget;
use metal2vulkan::device::{ContainmentPolicy, Device, DeviceDescription, DevicePolicy, GuestIsolation};
use metal2vulkan::library::{Function, FunctionConstantValue, FunctionConstantValues, Library};
use metal2vulkan::metal::{BlendFactor, BlendOperation, ColorWriteMask, DataType, PixelFormat, PrimitiveTopologyClass, VertexFormat, VertexStepFunction};
use metal2vulkan::pipeline::{
    ColorAttachmentDescriptor, ComputePipelineDescriptor, FunctionDescriptor, LinkedFunction, LinkedFunctions, RenderPipelineDescriptor, StageSource, VertexAttributeDescriptor,
    VertexBufferLayoutDescriptor, VertexDescriptor,
};
use std::cell::RefCell;
use std::ffi::{CStr, CString, c_char, c_void};

thread_local! { static LAST_ERROR: RefCell<CString> = RefCell::new(CString::default()); }

pub(crate) fn set_error(why: String) {
    LAST_ERROR.with(|l| *l.borrow_mut() = CString::new(why.replace('\0', " ")).unwrap_or_default());
}

pub(crate) fn guard<T>(fallback: T, body: impl FnOnce() -> Result<T, String>) -> T {
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(body)) {
        Ok(Ok(v)) => v,
        Ok(Err(why)) => {
            set_error(why);
            fallback
        }
        Err(_) => {
            set_error("a panic in the native stack".into());
            fallback
        }
    }
}

pub(crate) fn boxed<T>(v: T) -> *mut T {
    Box::into_raw(Box::new(v))
}
pub(crate) fn get<'a, T>(h: *const T) -> Result<&'a T, String> {
    unsafe { h.as_ref() }.ok_or_else(|| "null handle".to_string())
}
pub(crate) fn release<T>(h: *mut T) {
    if !h.is_null() {
        drop(unsafe { Box::from_raw(h) });
    }
}
fn raw<T: TryFrom<u32>>(value: u64, what: &str) -> Result<T, String> {
    u32::try_from(value).ok().and_then(|v| T::try_from(v).ok()).ok_or_else(|| format!("{what}: {value}"))
}
fn e<E: std::fmt::Debug>(what: &'static str) -> impl FnOnce(E) -> String {
    move |x| format!("{what}: {x:?}")
}

#[unsafe(no_mangle)]
pub extern "C" fn nmb_last_error() -> *const c_char {
    LAST_ERROR.with(|l| l.borrow().as_ptr())
}

/// Device: the translator's device model (no Vulkan) + the ir3 compiler. The profile is the A610's (scripts/laurel/a610-profile.py), compiled in.
static PROFILE: &str = include_str!(env!("NMN_PROFILE"));
const CHIP_ID: u32 = 0x0601_0000;

pub struct NmbDevice {
    pub(crate) device: Device,
    pub(crate) compiler: *mut NmnCompiler,
    pub(crate) stats: bool,
    pub(crate) gpu: std::sync::Arc<crate::draw::Gpu>,
}
// SAFETY: ir3_compiler is read only after its creation: Turnip shares one between threads.
unsafe impl Send for NmbDevice {}
unsafe impl Sync for NmbDevice {}
impl Drop for NmbDevice {
    fn drop(&mut self) {
        unsafe { nmn_compiler_free(self.compiler) }
    }
}

/// metal2vulkan's default, as the default stack. `NMN_POLICY=unsafe`: containment and isolation off. Stage 3 measured no fewer instructions with them off on the compositor's shaders, so off is not the default.
fn policy() -> DevicePolicy {
    let mut p = DevicePolicy::default();
    if std::env::var("NMN_POLICY").as_deref() == Ok("unsafe") {
        p.containment = ContainmentPolicy::UnsafeOff;
        p.isolation = GuestIsolation::Off;
    }
    p
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn nmb_device_open(_loader: *const c_char, _cache: *const c_char) -> *mut NmbDevice {
    guard(std::ptr::null_mut(), || {
        let description = DeviceDescription::from_khronos_json(PROFILE, None).map_err(e("profile"))?;
        let device = Device::new(description, policy()).map_err(e("device"))?;
        let mut why = [0 as c_char; 256];
        let compiler = unsafe { nmn_compiler_new(CHIP_ID, why.as_mut_ptr(), why.len()) };
        if compiler.is_null() {
            return Err(unsafe { CStr::from_ptr(why.as_ptr()) }.to_string_lossy().into_owned());
        }
        let gpu = crate::draw::Gpu::open()?;
        Ok(boxed(NmbDevice { device, compiler, stats: std::env::var_os("NMN_STATS").is_some(), gpu }))
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn nmb_device_release(d: *mut NmbDevice) {
    release(d)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn nmb_device_answer(_d: *const NmbDevice, selector: *const c_char, arg: u64, out: *mut u64) -> bool {
    // The answers of the default stack on FD610 (ios26-evidence/metal-fd610-answers.txt), with memoryless kept: stage 4 gives each attachment its real use.
    guard(false, || {
        let selector = unsafe { CStr::from_ptr(selector) }.to_str().map_err(e("selector"))?;
        let v = match selector {
            "supportsFamily:" => u64::from((1001..=1003).contains(&arg)),
            "supportsRasterOrderGroups" | "supportsTileShaders" | "supportsSIMDGroup" | "supportsSIMDReduction" | "supportsSIMDShuffleAndFill" | "supportsYCBCRFormats12" | "supportsYCBCRPackedFormats12" | "supportsLossyCompression" => 0,
            "supportsNativeHardwareFP16" | "supportsMemorylessRenderTargets" => 1,
            other => return Err(format!("no answer for {other}")),
        };
        unsafe { *out = v };
        Ok(true)
    })
}

pub struct NmbLibrary(pub(crate) Library, Vec<String>);
pub struct NmbFunction(pub(crate) FunctionDescriptor, pub(crate) Option<String>);

fn air_slice(bytes: &[u8]) -> Option<&[u8]> {
    const AIR64: u32 = 0x0100_0017;
    let word = |at: usize| bytes.get(at..at + 4).map(|w| u32::from_be_bytes([w[0], w[1], w[2], w[3]]));
    if word(0)? != 0xcafe_babe {
        return Some(bytes);
    }
    let count = word(4)? as usize;
    for i in 0..count.min(16) {
        let at = 8 + 20 * i;
        if word(at)? == AIR64 {
            let (offset, size) = (word(at + 8)? as usize, word(at + 12)? as usize);
            return bytes.get(offset..offset.checked_add(size)?);
        }
    }
    None
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn nmb_library_new(_d: *mut NmbDevice, bytes: *const c_void, length: usize, air: bool) -> *mut NmbLibrary {
    guard(std::ptr::null_mut(), || {
        if bytes.is_null() || length == 0 {
            return Err("no library bytes".into());
        }
        let bytes = unsafe { std::slice::from_raw_parts(bytes as *const u8, length) };
        let library = if air { Library::from_air(bytes).map_err(e("AIR"))? } else { Library::from_metallib(air_slice(bytes).ok_or("metallib without an AIR64 slice")?).map_err(e("metallib"))? };
        let names = library.functions().map(|f| f.name.to_string()).collect();
        Ok(boxed(NmbLibrary(library, names)))
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn nmb_library_release(l: *mut NmbLibrary) {
    release(l)
}

#[unsafe(no_mangle)]
pub extern "C" fn nmb_library_function_count(l: *const NmbLibrary) -> u32 {
    guard(0, || Ok(get(l)?.1.len() as u32))
}

fn function_of(library: &Library, name: &str) -> Result<Function, String> {
    library.function(name).map_err(e("function"))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn nmb_function_new(l: *mut NmbLibrary, name: *const c_char) -> *mut NmbFunction {
    guard(std::ptr::null_mut(), || {
        let name = unsafe { CStr::from_ptr(name) }.to_str().map_err(e("function name"))?;
        Ok(boxed(NmbFunction(FunctionDescriptor::new(function_of(&get(l)?.0, name)?), None)))
    })
}

#[repr(C)]
pub struct NmbConstant {
    pub kind: u64,
    pub index: u64,
    pub name: *const c_char,
    pub bytes: *const c_void,
    pub length: u64,
}

unsafe fn constant_values(list: &[NmbConstant]) -> Result<FunctionConstantValues, String> {
    let mut values = FunctionConstantValues::defaults();
    for c in list {
        if c.bytes.is_null() {
            return Err("constant without bytes".into());
        }
        let bytes = unsafe { std::slice::from_raw_parts(c.bytes as *const u8, c.length as usize) };
        let value = FunctionConstantValue::new(raw::<DataType>(c.kind, "constant type")?, bytes.to_vec());
        if c.name.is_null() {
            values.by_index.insert(u32::try_from(c.index).map_err(e("constant index"))?, value);
        } else {
            let key = unsafe { CStr::from_ptr(c.name) }.to_str().map_err(e("constant name"))?;
            values.by_name.insert(key.to_string(), value);
        }
    }
    Ok(values)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn nmb_function_new_specialized(l: *mut NmbLibrary, name: *const c_char, constants: *const NmbConstant, count: u32) -> *mut NmbFunction {
    guard(std::ptr::null_mut(), || {
        let name = unsafe { CStr::from_ptr(name) }.to_str().map_err(e("function name"))?;
        let list = if count == 0 { &[][..] } else { unsafe { std::slice::from_raw_parts(constants, count as usize) } };
        let mut d = FunctionDescriptor::new(function_of(&get(l)?.0, name)?);
        d.constants = unsafe { constant_values(list)? };
        Ok(boxed(NmbFunction(d, None)))
    })
}

/// `newFunctionWithDescriptor:`; specialized_name = the name a stage links it under (RenderBox's custom_fn).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nmb_function_new_with_descriptor(l: *mut NmbLibrary, name: *const c_char, specialized: *const c_char, constants: *const NmbConstant, count: u32, has_constants: bool) -> *mut NmbFunction {
    guard(std::ptr::null_mut(), || {
        let name = unsafe { CStr::from_ptr(name) }.to_str().map_err(e("function name"))?;
        let mut d = FunctionDescriptor::new(function_of(&get(l)?.0, name)?);
        if has_constants {
            let list = if count == 0 { &[][..] } else { unsafe { std::slice::from_raw_parts(constants, count as usize) } };
            d.constants = unsafe { constant_values(list)? };
        }
        let link = if specialized.is_null() { None } else { Some(unsafe { CStr::from_ptr(specialized) }.to_str().map_err(e("specialized name"))?.to_owned()).filter(|s| !s.is_empty()) };
        Ok(boxed(NmbFunction(d, link)))
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn nmb_function_release(f: *mut NmbFunction) {
    release(f)
}

// ---- pipelines ----

pub struct NmbComputePipeline(pub(crate) Program, pub(crate) std::sync::Arc<metal2vulkan::pipeline::ComputePipeline>);
/// The translator's pipeline; the fixed state of its descriptor; its programs per bind shape (a plan and a specialization: the second use is a lookup).
pub struct NmbRenderPipeline {
    pub(crate) first: Program,
    pub(crate) pipeline: std::sync::Arc<metal2vulkan::pipeline::RenderPipeline>,
    pub(crate) fixed: PipelineFixed,
    pub(crate) device: *const NmbDevice,
    pub(crate) plans: std::sync::Mutex<std::collections::HashMap<Vec<u8>, std::sync::Arc<crate::draw::PlanEntry>>>,
}
pub(crate) struct ColorFixed {
    pub format: u64,
    pub blending: u64,
    pub source_rgb: u32,
    pub destination_rgb: u32,
    pub rgb_operation: u32,
    pub source_alpha: u32,
    pub destination_alpha: u32,
    pub alpha_operation: u32,
    pub write_mask: u32,
}
pub(crate) struct PipelineFixed {
    pub colors: Vec<ColorFixed>,
    pub samples: u32,
}

fn print_stage(name: &str, stage: &str, i: &NmnStageInfo) {
    println!("stat\t{name}\t{stage}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}", i.instructions, i.nops, i.movs, i.covs, i.sizedwords, i.half_regs, i.full_regs, i.const_vec4, i.tex_ops, i.mem_ops, i.sstall, i.systall, i.loops, i.reads_framebuffer as u32);
}

#[unsafe(no_mangle)]
pub extern "C" fn nmb_compute_pipeline_new(d: *mut NmbDevice, f: *mut NmbFunction) -> *mut NmbComputePipeline {
    guard(std::ptr::null_mut(), || {
        let device = get(d)?;
        let descriptor = ComputePipelineDescriptor::new(StageSource::Function(get(f)?.0.clone()));
        let pipeline = device.device.compile_compute_pipeline(&descriptor, &Budget::standard()).map_err(e("compute pipeline"))?;
        let program = compute_program(device.compiler, &pipeline)?;
        if device.stats {
            if let Some(i) = program.stage_info(0) {
                print_stage(&std::env::var("NMN_STAT_NAME").unwrap_or_default(), "compute", &i);
            }
        }
        Ok(boxed(NmbComputePipeline(program, std::sync::Arc::new(pipeline))))
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn nmb_compute_pipeline_release(p: *mut NmbComputePipeline) {
    release(p)
}

#[repr(C)]
pub struct NmbColorAttachment {
    pub format: u64,
    pub write_mask: u64,
    pub blending: u64,
    pub source_rgb: u64,
    pub destination_rgb: u64,
    pub rgb_operation: u64,
    pub source_alpha: u64,
    pub destination_alpha: u64,
    pub alpha_operation: u64,
}
#[repr(C)]
pub struct NmbVertexAttribute {
    pub format: u64,
    pub offset: u64,
    pub buffer: u64,
}
#[repr(C)]
pub struct NmbVertexLayout {
    pub stride: u64,
    pub step_function: u64,
    pub step_rate: u64,
}
#[repr(C)]
pub struct NmbLinkedFunctionGroup {
    pub name: *const c_char,
    pub functions: *const *mut NmbFunction,
    pub count: usize,
}
#[repr(C)]
pub struct NmbLinkedFunctions {
    pub functions: *const *mut NmbFunction,
    pub function_count: usize,
    pub private_functions: *const *mut NmbFunction,
    pub private_count: usize,
    pub binary_functions: *const *mut NmbFunction,
    pub binary_count: usize,
    pub groups: *const NmbLinkedFunctionGroup,
    pub group_count: usize,
}
#[repr(C)]
pub struct NmbRenderPipelineDescriptor {
    pub vertex: *mut NmbFunction,
    pub fragment: *mut NmbFunction,
    pub colors: [NmbColorAttachment; 8],
    pub depth_format: u64,
    pub stencil_format: u64,
    pub samples: u64,
    pub topology: u64,
    pub rasterization: u64,
    pub vertex_inputs: u64,
    pub attributes: [NmbVertexAttribute; 31],
    pub layouts: [NmbVertexLayout; 31],
    pub vertex_linked: NmbLinkedFunctions,
    pub fragment_linked: NmbLinkedFunctions,
}

fn linked_function(f: *mut NmbFunction) -> Result<LinkedFunction, String> {
    let n = get(f)?;
    let mut l = LinkedFunction::new(n.0.function.clone()).with_constants(n.0.constants.clone());
    if let Some(name) = &n.1 {
        l = l.with_specialized_name(name.clone());
    }
    Ok(l)
}

unsafe fn linked_array(p: *const *mut NmbFunction, n: usize) -> Result<Vec<LinkedFunction>, String> {
    if n == 0 {
        return Ok(Vec::new());
    }
    unsafe { std::slice::from_raw_parts(p, n) }.iter().map(|&f| linked_function(f)).collect()
}

unsafe fn linked_functions(d: &NmbLinkedFunctions) -> Result<LinkedFunctions, String> {
    let mut out = LinkedFunctions::new();
    out.functions = unsafe { linked_array(d.functions, d.function_count)? };
    out.private_functions = unsafe { linked_array(d.private_functions, d.private_count)? };
    out.binary_functions = unsafe { linked_array(d.binary_functions, d.binary_count)? };
    if d.group_count > 0 {
        for g in unsafe { std::slice::from_raw_parts(d.groups, d.group_count) } {
            let name = unsafe { CStr::from_ptr(g.name) }.to_str().map_err(e("linked group name"))?;
            out.groups.insert(name.to_owned(), unsafe { linked_array(g.functions, g.count)? });
        }
    }
    Ok(out)
}

fn optional_format(v: u64) -> Result<Option<PixelFormat>, String> {
    if v == 0 { Ok(None) } else { raw::<PixelFormat>(v, "pixel format").map(Some) }
}

pub(crate) fn render_descriptor(descriptor: *const NmbRenderPipelineDescriptor) -> Result<RenderPipelineDescriptor, String> {
    let d = get(descriptor)?;
    let mut vertex = get(d.vertex)?.0.clone();
    vertex.linked = unsafe { linked_functions(&d.vertex_linked)? };
    let mut out = RenderPipelineDescriptor::new(StageSource::Function(vertex));
    if !d.fragment.is_null() {
        let mut fragment = get(d.fragment)?.0.clone();
        fragment.linked = unsafe { linked_functions(&d.fragment_linked)? };
        out.fragment = Some(StageSource::Function(fragment));
    }
    for (slot, c) in out.color_attachments.iter_mut().zip(d.colors.iter()) {
        if c.format == 0 {
            continue;
        }
        let mut a = ColorAttachmentDescriptor::new(raw::<PixelFormat>(c.format, "color format")?);
        a.write_mask = raw::<ColorWriteMask>(c.write_mask, "write mask")?;
        a.blending_enabled = c.blending != 0;
        a.source_rgb_blend_factor = raw::<BlendFactor>(c.source_rgb, "blend factor")?;
        a.destination_rgb_blend_factor = raw::<BlendFactor>(c.destination_rgb, "blend factor")?;
        a.rgb_blend_operation = raw::<BlendOperation>(c.rgb_operation, "blend operation")?;
        a.source_alpha_blend_factor = raw::<BlendFactor>(c.source_alpha, "blend factor")?;
        a.destination_alpha_blend_factor = raw::<BlendFactor>(c.destination_alpha, "blend factor")?;
        a.alpha_blend_operation = raw::<BlendOperation>(c.alpha_operation, "blend operation")?;
        *slot = Some(a);
    }
    out.depth_format = optional_format(d.depth_format)?;
    out.stencil_format = optional_format(d.stencil_format)?;
    out.raster_sample_count = d.samples.max(1) as u32;
    out.input_primitive_topology = raw::<PrimitiveTopologyClass>(d.topology, "topology")?;
    out.rasterization_enabled = d.rasterization != 0;
    if d.vertex_inputs != 0 {
        let mut inputs = VertexDescriptor::new();
        for (i, a) in d.attributes.iter().enumerate() {
            if a.format == 0 {
                continue;
            }
            inputs.attributes.insert(i as u32, VertexAttributeDescriptor::new(raw::<VertexFormat>(a.format, "vertex format")?, a.offset as u32, a.buffer as u32));
            if let Some(l) = d.layouts.get(a.buffer as usize) {
                let mut layout = VertexBufferLayoutDescriptor::new(Some(l.stride as u32));
                layout.step_function = raw::<VertexStepFunction>(l.step_function, "step function")?;
                layout.step_rate = l.step_rate as u32;
                inputs.layouts.insert(a.buffer as u32, layout);
            }
        }
        out.vertex_descriptor = Some(inputs);
    }
    Ok(out)
}

#[unsafe(no_mangle)]
pub extern "C" fn nmb_render_pipeline_new(d: *mut NmbDevice, descriptor: *const NmbRenderPipelineDescriptor) -> *mut NmbRenderPipeline {
    guard(std::ptr::null_mut(), || {
        let device = get(d)?;
        let pipeline = device.device.compile_render_pipeline(&render_descriptor(descriptor)?, &Budget::standard()).map_err(e("render pipeline"))?;
        let program = render_program(device.compiler, &pipeline)?;
        let source = get(descriptor)?;
        let fixed = PipelineFixed {
            colors: source.colors.iter().map(|c| ColorFixed { format: c.format, blending: c.blending, source_rgb: c.source_rgb as u32, destination_rgb: c.destination_rgb as u32, rgb_operation: c.rgb_operation as u32, source_alpha: c.source_alpha as u32, destination_alpha: c.destination_alpha as u32, alpha_operation: c.alpha_operation as u32, write_mask: c.write_mask as u32 }).collect(),
            samples: source.samples.max(1) as u32,
        };
        if device.stats {
            let name = std::env::var("NMN_STAT_NAME").unwrap_or_default();
            for (i, stage) in ["vertex", "fragment"].iter().enumerate() {
                if let Some(info) = program.stage_info(i as u32) {
                    print_stage(&name, stage, &info);
                }
            }
        }
        Ok(boxed(NmbRenderPipeline { first: program, pipeline: std::sync::Arc::new(pipeline), fixed, device: d, plans: std::sync::Mutex::new(std::collections::HashMap::new()) }))
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn nmb_render_pipeline_release(p: *mut NmbRenderPipeline) {
    release(p)
}
